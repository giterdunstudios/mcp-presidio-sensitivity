#!/usr/bin/env bash
# coupling-analysis.sh — Temporal coupling analysis for parallelization planning
#
# Mines git commit history to compute co-change frequency between solution
# artifacts. Outputs a conditional probability matrix to planning/coupling-data.json.
#
# Usage:
#   ./scripts/coupling-analysis.sh                          # JSON output (default)
#   ./scripts/coupling-analysis.sh --format table           # human-readable table
#   ./scripts/coupling-analysis.sh --format table | grep -E "strong|moderate"
#   ./scripts/devtools-run.sh ./scripts/coupling-analysis.sh
#
# Flags:
#   --since REF                git ref to limit history (e.g. pre-wave-work)
#   --exclude-paths GLOBS      colon-separated glob patterns to exclude
#                              default: planning/**:deliverables/**:.claude/**
#   --max-files-per-commit N   skip commits touching more than N files (outlier filter)
#                              default: 15
#   --min-observations N       omit pairs where anchor file has fewer than N commits
#                              default: 3
#   --output FILE              output path (default: planning/coupling-data.json)
#   --format json|table        output format (default: json)
#
# Run on main only — feature branch history produces misleading pair counts.
# Regenerate after every merge to main, before wave planning sessions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required." >&2
    echo "Run via: ./scripts/devtools-run.sh ./scripts/coupling-analysis.sh" >&2
    exit 1
fi

_TMPFILE=$(mktemp /tmp/coupling-analysis.XXXXXX.py)
trap 'rm -f "$_TMPFILE"' EXIT

cat > "$_TMPFILE" <<'PYTHON'
#!/usr/bin/env python3
"""Temporal coupling analysis — see coupling-analysis.sh for usage."""

import sys
import subprocess
import json
import fnmatch
import os
import re
import argparse
from collections import defaultdict
from datetime import datetime, timezone
from itertools import combinations

COMMIT_RE = re.compile(r'^COMMIT:([0-9a-f]{40})$')


def matches_any_exclusion(path, patterns):
    """Return True if path matches any exclusion glob pattern."""
    for pat in patterns:
        # Direct match
        if fnmatch.fnmatch(path, pat):
            return True
        # Match against path with leading segment stripped progressively
        # so "planning/**" matches "planning/foo/bar.md"
        parts = path.split('/')
        for i in range(len(parts)):
            if fnmatch.fnmatch('/'.join(parts[i:]), pat):
                return True
    return False


def get_commits(since_ref=None):
    """Return list of (hash, [files]) tuples from git log."""
    cmd = [
        'git', 'log',
        '--no-merges',
        '--name-only',
        '--diff-filter=ACDMR',
        '--pretty=format:COMMIT:%H',
    ]
    if since_ref:
        cmd.append(f'{since_ref}..HEAD')

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)

    commits = []
    current_hash = None
    current_files = []

    for line in result.stdout.splitlines():
        line = line.strip()
        m = COMMIT_RE.match(line)
        if m:
            if current_hash is not None:
                commits.append((current_hash, current_files))
            current_hash = m.group(1)
            current_files = []
        elif line:
            current_files.append(line)

    if current_hash is not None:
        commits.append((current_hash, current_files))

    return commits


def coupling_tier(score):
    if score >= 0.70:
        return 'strong'
    elif score >= 0.40:
        return 'moderate'
    elif score >= 0.15:
        return 'weak'
    else:
        return 'negligible'


def confidence_tier(observations):
    if observations >= 50:
        return 'mature'
    elif observations >= 20:
        return 'established'
    elif observations >= 5:
        return 'early'
    else:
        return 'sparse'


def main():
    parser = argparse.ArgumentParser(description='Temporal coupling analysis')
    parser.add_argument('--since', default=None, metavar='REF',
                        help='Limit history to commits after this git ref')
    parser.add_argument('--exclude-paths', default='planning/**:deliverables/**:.claude/**',
                        metavar='GLOBS', help='Colon-separated exclusion glob patterns')
    parser.add_argument('--max-files-per-commit', type=int, default=15, metavar='N',
                        help='Skip commits touching more than N files (outlier filter)')
    parser.add_argument('--min-observations', type=int, default=3, metavar='N',
                        help='Omit pairs where anchor file has fewer than N commits')
    parser.add_argument('--output', default='planning/coupling-data.json', metavar='FILE',
                        help='Output path for JSON')
    parser.add_argument('--format', choices=['json', 'table'], default='json',
                        help='Output format')
    args = parser.parse_args()

    exclude_patterns = [p.strip() for p in args.exclude_paths.split(':') if p.strip()]

    all_commits = get_commits(args.since)

    co_change = defaultdict(int)       # (file_a, file_b) -> count  (sorted tuple as key)
    total_changes = defaultdict(int)   # file -> commit count
    excluded_commit_count = 0
    processed_commit_count = 0
    excluded_hashes = []

    for commit_hash, files in all_commits:
        # Apply exclusion filter
        filtered = [f for f in files if not matches_any_exclusion(f, exclude_patterns)]

        # Apply outlier filter
        if len(filtered) > args.max_files_per_commit:
            excluded_commit_count += 1
            excluded_hashes.append(commit_hash[:8])
            continue

        processed_commit_count += 1

        for f in filtered:
            total_changes[f] += 1

        for a, b in combinations(sorted(filtered), 2):
            co_change[(a, b)] += 1

    # Build pairs list
    pairs = []
    for (file_a, file_b), count in co_change.items():
        obs_a = total_changes[file_a]
        obs_b = total_changes[file_b]

        if min(obs_a, obs_b) < args.min_observations:
            continue

        p_b_given_a = round(count / obs_a, 3) if obs_a else 0.0
        p_a_given_b = round(count / obs_b, 3) if obs_b else 0.0
        score = round(max(p_b_given_a, p_a_given_b), 3)

        pairs.append({
            'file_a': file_a,
            'file_b': file_b,
            'co_change_count': count,
            'p_b_given_a': p_b_given_a,
            'p_a_given_b': p_a_given_b,
            'coupling_score': score,
            'coupling_tier': coupling_tier(score),
            'history_confidence': confidence_tier(max(obs_a, obs_b)),
            'observations_a': obs_a,
            'observations_b': obs_b,
        })

    pairs.sort(key=lambda x: x['coupling_score'], reverse=True)

    output = {
        '_meta': {
            'generated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'commit_count': processed_commit_count,
            'excluded_commit_count': excluded_commit_count,
            'excluded_commit_hashes': excluded_hashes,
            'file_count': len(total_changes),
            'excluded_paths': exclude_patterns,
            'max_files_per_commit': args.max_files_per_commit,
            'min_observations': args.min_observations,
            'note': 'INTERNAL ONLY — do not publish in public repositories without security review',
        },
        'pairs': pairs,
    }

    if args.format == 'json':
        out_dir = os.path.dirname(args.output)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.output, 'w') as fh:
            json.dump(output, fh, indent=2)
            fh.write('\n')
        meta = output['_meta']
        print(f"Written: {args.output}")
        print(f"  Commits processed : {meta['commit_count']}")
        print(f"  Commits excluded  : {meta['excluded_commit_count']} (>{args.max_files_per_commit} files)")
        if excluded_hashes:
            print(f"  Excluded hashes   : {', '.join(excluded_hashes)}")
        print(f"  Files tracked     : {meta['file_count']}")
        print(f"  Pairs above min   : {len(pairs)}")
        strong   = sum(1 for p in pairs if p['coupling_tier'] == 'strong')
        moderate = sum(1 for p in pairs if p['coupling_tier'] == 'moderate')
        weak     = sum(1 for p in pairs if p['coupling_tier'] == 'weak')
        print(f"  Tier breakdown    : {strong} strong  {moderate} moderate  {weak} weak")
    else:
        meta = output['_meta']
        print(f"\nTemporal Coupling Analysis — {meta['generated'][:10]}")
        print(f"Commits: {meta['commit_count']} processed, "
              f"{meta['excluded_commit_count']} excluded (>{args.max_files_per_commit} files)")
        print(f"Files tracked: {meta['file_count']}    "
              f"Pairs above min_observations={args.min_observations}: {len(pairs)}\n")

        if not pairs:
            print("No pairs above threshold.")
            return

        col_score = 6
        col_tier  = 10
        col_conf  = 13
        col_co    = 4
        print(f"{'SCORE':>{col_score}}  {'TIER':>{col_tier}}  {'CONFIDENCE':>{col_conf}}  "
              f"{'CO':>{col_co}}  FILE A  →  FILE B")
        print("─" * 110)

        for p in pairs:
            print(f"{p['coupling_score']:>{col_score}.3f}  "
                  f"{p['coupling_tier']:>{col_tier}}  "
                  f"{p['history_confidence']:>{col_conf}}  "
                  f"{p['co_change_count']:>{col_co}}  "
                  f"{p['file_a']}  →  {p['file_b']}")


if __name__ == '__main__':
    main()
PYTHON

python3 "$_TMPFILE" "$@"
