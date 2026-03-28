# Temporal Coupling Diagram

Generated from `planning/coupling-data.json` — 91 commits, 4 excluded (>15 files).
Strong and moderate pairs only (score ≥ 0.40). Weak pairs omitted for clarity.

Edge weight legend:
- `===` thick solid — strong (≥ 0.75), early/sparse confidence
- `-->` solid — moderate (0.40–0.74), early confidence (≥ 4 co-changes)
- `-.->` dashed — moderate (0.40–0.74), sparse confidence (2–3 co-changes)

Score shown on each edge. Confidence shown as `(e)` = early, `(s)` = sparse.

---

```mermaid
graph LR
    subgraph SRC["📦 Source / Dependencies"]
        mcp_df["mcp_server/Dockerfile"]
        mcp_lk["mcp_server/\nrequirements.lock.txt"]
        wkr_lk["worker/\nrequirements.lock.txt"]
        mcp_py["mcp_server/main.py"]
        wkr_py["worker/main.py"]
        wkr_df["worker/Dockerfile"]
    end

    subgraph HELM["⚙️ Helm / Config"]
        mcp_vl["mcp-server/\nvalues.local.yaml"]
        wkr_vl["presidio-worker/\nvalues.local.yaml"]
        wkr_v["presidio-worker/\nvalues.yaml"]
        mcp_np["mcp-server/\nnetworkpolicy.yaml"]
        wkr_np["presidio-worker/\nnetworkpolicy.yaml"]
    end

    subgraph SCR["🔧 Scripts"]
        rebuild["rebuild.sh"]
        setup["setup-local.sh"]
        status["status.sh"]
        validate["validate-\nnetworkpolicy.sh"]
        demo["demo.sh"]
        kc["keycloak-admin.sh"]
        readme["README.md"]
        branch["branch-test.sh"]
        test["test.sh"]
    end

    %% ── STRONG (≥0.75) ──────────────────────────────────────────
    mcp_lk      === wkr_lk
    mcp_vl      === wkr_vl
    wkr_vl      === wkr_v
    kc          ==>|"1.00 (e)"| rebuild
    rebuild     ==>|"0.80 (e)"| validate
    demo        ==>|"0.80 (e)"| validate

    %% ── MODERATE, EARLY (≥4 co-changes) ─────────────────────────
    readme      -->|"0.63 (e)"| rebuild
    rebuild     -->|"0.67 (e)"| setup
    rebuild     -->|"0.57 (e)"| status
    setup       -->|"0.67 (e)"| status
    setup       -->|"0.60 (e)"| validate
    setup       -->|"0.67 (e)"| test
    demo        -->|"0.50 (e)"| rebuild
    demo        -->|"0.50 (e)"| setup
    branch      -->|"0.50 (e)"| rebuild
    mcp_vl      -->|"0.50 (e)"| rebuild
    mcp_vl      -->|"0.50 (e)"| setup
    mcp_vl      -->|"0.50 (e)"| status
    status      -->|"0.40 (e)"| validate

    %% ── MODERATE, SPARSE (2–3 co-changes) ───────────────────────
    mcp_df      -.->|"0.67 (s)"| mcp_lk
    mcp_df      -.->|"0.67 (s)"| wkr_lk
    mcp_np      -.->|"0.67 (s)"| wkr_np
    mcp_np      -.->|"0.67 (s)"| mcp_vl
    wkr_v       -.->|"0.67 (s)"| wkr_df
    wkr_v       -.->|"0.67 (s)"| wkr_py
    wkr_vl      -.->|"0.50 (s)"| wkr_df
    wkr_vl      -.->|"0.50 (s)"| wkr_py
    wkr_df      -.->|"0.50 (s)"| wkr_py
    mcp_py      -.->|"0.50 (s)"| wkr_py
    mcp_vl      -.->|"0.67 (s)"| wkr_v

    %% ── STYLES ──────────────────────────────────────────────────
    classDef src      fill:#1a3a5c,stroke:#4a8abf,color:#cde,rx:4
    classDef helm     fill:#3a1a5c,stroke:#9a5abf,color:#dce,rx:4
    classDef scripts  fill:#1a3a1a,stroke:#4abf4a,color:#cec,rx:4

    class mcp_df,mcp_lk,wkr_lk,mcp_py,wkr_py,wkr_df src
    class mcp_vl,wkr_vl,wkr_v,mcp_np,wkr_np helm
    class rebuild,setup,status,validate,demo,kc,readme,branch,test scripts

    linkStyle 0,1,2,3,4,5 stroke:#e88,stroke-width:3px
    linkStyle 6,7,8,9,10,11,12,13,14,15,16,17,18 stroke:#8ae,stroke-width:2px
    linkStyle 19,20,21,22,23,24,25,26,27,28,29 stroke:#888,stroke-width:1px,stroke-dasharray:4
```

---

## Reading the graph

| Element | Meaning |
|---------|---------|
| Red thick edges | Strong coupling — these files have moved together in ≥75% of commits touching either |
| Blue solid edges | Moderate, early confidence — statistically building (≥4 co-changes observed) |
| Grey dashed edges | Moderate, sparse — real signal but only 2–3 observations; watch for confirmation |
| `(e)` on edge | Early confidence — enough history to be directional, not yet stable |
| `(s)` on edge | Sparse confidence — treat as a hypothesis, not a rule |

## Key observations

**`rebuild.sh` is the hub.** Highest edge degree in the scripts cluster. Touches
keycloak-admin (1.0), validate-networkpolicy (0.80), README (0.63), setup-local (0.67),
status (0.57), demo (0.50), branch-test (0.50). Any branch touching rebuild.sh should
treat all of these as review candidates.

**Both lock files are one logical unit.** 1.0 bidirectional — never touched independently.
`mcp_server/Dockerfile` is an upstream trigger (dashed edges into both lock files).

**`validate-networkpolicy.sh` is a pure sink.** High in-degree from rebuild, demo, setup,
status — nothing points away from it. Changes there don't ripple; changes everywhere else
require re-checking it.

**Worker Helm → source (sparse dashed).** `values.yaml → worker/Dockerfile` and
`values.yaml → worker/main.py` suggest env var additions propagate from Helm config
into application code simultaneously. Watch for confirmation.
