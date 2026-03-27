# Tech Debt & Operational Debt Backlog

Produced by council audit (2026-03-26). Covers all known tech debt, operational
debt, and governance gaps identified across all personas.

**Last updated:** 2026-03-27 (wave assignments + cross-persona flag resolutions added)

**Summary:**
- 21 items are self-contained and can be picked up independently
- 10 items are blocked — 4 on Phase 3 planning (#15, #16, #17, #25), 3 on Integration/API Lead activation (#29, #30, #31), 2 on other items in this list (#12 on #11, #23 on #22), 1 on scope definition (#17)
- 3 burst/future personas need activation before their items can start: Platform/Cluster Infrastructure Lead (#15, #25, #27), Detection/Data Researcher (#24), Integration/API Lead (#29, #30, #31)

**Cross-persona flag resolutions (2026-03-27):**
- CVE failure policy (#20): warn on HIGH (exit 0), block on CRITICAL (exit 1)
- Credential gate (#6): standalone `scripts/check-credentials.sh`; rebuild.sh calls it in one line; default = dry-run, `--strict` available; backlog item added to review and tighten after 1 month operational data
- Helm version bump (#13): split — Part A = policy doc now (planning/helm-versioning-policy.md); Part B = coordinated 0.1.0→0.2.0 bump after #14+#26 merge
- SBOM cdxgen gate (#22): Security Lead commits BP-001 status → `approved-for-implementation`; concerns → council review
- #31 folded into #1+#2 batch: branch `1-2-31-registry-gc` covers all three items

**Wave assignments:**
- Wave 1 (fully parallel): #3, #4, #8, #9, #11, #18, #19
- Wave 2 (minor contention): #1+#2+#31, #6, #7, #10, #13
- Wave 3 (sequential, rebuild.sh): #5 → #14 → #20
- Wave 4 (lower priority): #21, #22 (gate on Security sign-off), #26, #28

**Independent column:** ✅ Yes = self-contained branch, no blocker | ⛔ No = explicitly blocked (reason noted)

---

| # | Item | Why needed | Priority | Independent? | Wave / Branch | Implementation Owner | Validation Owner |
|---|------|-----------|----------|-------------|--------------|---------------------|-----------------|
| 1 | **Registry GC script** (`scripts/registry-gc.sh`) | Unreferenced image layers accumulate on every rebuild — silent disk growth | High | ✅ Yes | Wave 2 / `1-2-31-registry-gc` | Engineering Practices Lead | Technical Implementation Lead |
| 2 | **Registry process documentation** in `scripts/README.md` | No documented policy for when/how to run GC | High | ✅ Yes | Wave 2 / `1-2-31-registry-gc` | Engineering Practices Lead | Product / Scope Lead |
| 3 | **Worker pod restart root cause** investigation | 9 restarts in status.sh — unknown instability going into Phase 3 | High | ✅ Yes | Wave 1 / `3-worker-restart-investigation` | Technical Implementation Lead | Engineering Practices Lead |
| 4 | **SBOM (`bom.json`) refresh post-Phase 2** | auth/ deleted, Istio/Envoy CRDs added — current SBOM doesn't reflect running system | High | ✅ Yes | Wave 1 / `4-sbom-refresh` | Security / Privacy Lead | Technical Implementation Lead |
| 5 | **requirements.lock.txt sync check** in rebuild.sh | Nothing verifies lock file matches requirements.txt — could ship wrong deps silently | High | ✅ Yes | Wave 3 / `5-lockfile-sync-check` (after Wave 2) | Technical Implementation Lead | Engineering Practices Lead |
| 6 | **Hardcoded credential pre-prod gate** | CLIENT_SECRET / ADMIN_PASSWORD have change-in-prod values with no enforcement gate | High | ✅ Yes | Wave 2 / `6-credential-gate` | Security / Privacy Lead | Engineering Practices Lead |
| 7 | **BP-007** Integration test for RFC 9728 discovery chain | auth-test.sh covers enforcement; no test for the full discovery chain a client follows | Medium | ✅ Yes | Wave 2 / `7-rfc9728-integration-test` | Technical Implementation Lead | Security / Privacy Lead |
| 8 | **BP-010** Disaster recovery runbook | No documented recovery path — what breaks, what to run, how long it takes | Medium | ✅ Yes | Wave 1 / `8-dr-runbook` | Engineering Practices Lead | Product / Scope Lead |
| 9 | **BP-011** Verify `setup-local.sh --teardown` leaves no orphaned resources | Teardown/re-run path not validated — orphaned registry volumes possible | Medium | ✅ Yes | Wave 1 / `9-teardown-verification` | Technical Implementation Lead | Engineering Practices Lead |
| 10 | **BP-012** k3d version floor check in `setup-local.sh` | Script checks presence only — silent behaviour changes from k3d version mismatch | Medium | ✅ Yes | Wave 2 / `10-k3d-version-check` | Engineering Practices Lead | Technical Implementation Lead |
| 11 | **BP-013** Document dev/prod parity delta | No formal baseline of what's simplified locally vs. production target | Medium | ✅ Yes | Wave 1 / `11-parity-delta` | Engineering Practices Lead | Product / Scope Lead |
| 12 | **BP-014** Define acceptable parity threshold | No rule for "if X absent locally, you cannot test Y" | Medium | ⛔ No — depends on #11 | Wave 2 (after #11) / `12-parity-threshold` | Engineering Practices Lead | Product / Scope Lead |
| 13 | **Helm chart version bump policy** (Part A: policy doc) | Both charts frozen at 0.1.0 — can't correlate running pod to chart version in audit trail | Medium | ✅ Yes | Wave 2 / `13-helm-version-policy` | Engineering Practices Lead | Technical Implementation Lead |
| 13b | **Helm chart version bump** (Part B: 0.1.0→0.2.0) | Reflect Phase 2 changes in chart version | Medium | ⛔ No — wait for #14+#26 to merge | Coordinated PR after Wave 3+4 | Engineering Practices Lead | Technical Implementation Lead |
| 14 | **Helm test hooks** | No post-deploy smoke test; Helm native support unused | Medium | ✅ Yes | Wave 3 / `14-helm-test-hooks` (after #13) | Technical Implementation Lead | Engineering Practices Lead |
| 15 | **Istio IngressGateway** | Port-level PERMISSIVE on port 8000 is a workaround — IngressGateway is the correct solution | Medium | ⛔ No — Phase 3 scope definition required first | Phase 3 | Platform / Cluster Infrastructure Lead (reactivate burst) | Security / Privacy Lead + Technical Implementation Lead |
| 16 | **Per-identity rate limiting** (DEC-003 cases 25+29) | Per-pod shared counter — one caller exhausts limit for all | Medium | ⛔ No — requires Redis + global rate limit service | Phase 3 | Technical Implementation Lead | Security / Privacy Lead |
| 17 | **EnvoyFilter replacement** (DEC-005) | Bypasses Istio stable API — breaks silently on any minor Istio upgrade | Medium | ⛔ No — depends on #15 (WWW-Auth) and #16 (rate limit) | Phase 3 | Technical Implementation Lead | Security / Privacy Lead |
| 18 | **Vertical templates — schedule a phase** | Research complete since 2026-03-26; no implementation phase assigned | Medium | ✅ Yes (planning task only) | Wave 1 / `18-19-planning` | Product / Scope Lead | Engineering Practices Lead |
| 19 | **SLO definition** | No p99 latency or error rate targets — Phase 3 observability has no pass/fail criteria | Medium | ✅ Yes (planning task only) | Wave 1 / `18-19-planning` | Product / Scope Lead | Engineering Practices Lead |
| 20 | **Image vulnerability scanning** (Trivy/Grype in rebuild.sh) | No CVE check for images handling PII data. Warn on HIGH, block on CRITICAL. | Medium | ✅ Yes | Wave 3 / `20-image-vuln-scanning` (after #5) | Security / Privacy Lead | Technical Implementation Lead |
| 21 | **Registry authentication gap** — document as known gap | Unauthenticated pushes accepted — undocumented, not a deliberate decision | Medium | ✅ Yes | Wave 4 / `21-registry-auth-gap` | Engineering Practices Lead | Security / Privacy Lead |
| 22 | **BP-001** SBOM auto-regen via cdxgen in rebuild.sh | Manual SBOM goes stale on every rebuild | Low | ✅ Yes (gated: Security Lead commits BP-001 → `approved-for-implementation`) | Wave 4 / `22-sbom-cdxgen` | Technical Implementation Lead | Security / Privacy Lead |
| 23 | **BP-003** bom.json serialNumber generation | Static UUID means two different SBOMs are indistinguishable | Low | ⛔ No — depends on #22 (cdxgen generates this) | Wave 4 (after #22) | Security / Privacy Lead | Technical Implementation Lead |
| 24 | **BP-008** Synthetic test corpus coverage gate | No quality gate for test corpus when new entity types are added | Low | ✅ Yes (surge role required) | Activate Detection/Data Researcher | Detection / Data Researcher (activate surge) | Engineering Practices Lead |
| 25 | **Cilium CNI** (DEC-004 Phase E) | Flannel enforces NetworkPolicy but not L7 identity — Cilium is Phase 3 target | Low | ⛔ No — Phase 3 scope + cluster disruption; plan required | Phase 3 | Platform / Cluster Infrastructure Lead (reactivate burst) | Security / Privacy Lead |
| 26 | **Prometheus → Worker direct scraping** | kubectl exec workaround — needs NetworkPolicy exemption rule | Low | ✅ Yes | Wave 4 / `26-prometheus-worker-scraping` | Technical Implementation Lead | Security / Privacy Lead |
| 27 | **Loki + Promtail** centralized log aggregation | Container logs not aggregated — kubectl logs only; Grafana already supports Loki | Low | ✅ Yes (additive, no breaking changes) | Activate Platform Lead burst | Platform / Cluster Infrastructure Lead (reactivate burst) | Engineering Practices Lead |
| 28 | **Image signing** (Cosign) | Images are unsigned — no integrity guarantee | Low | ✅ Yes | Wave 4 / `28-image-signing` | Security / Privacy Lead | Technical Implementation Lead |
| 29 | **Token revocation** (RFC 7009) | Compromised tokens valid for full TTL — no revocation endpoint | Low | ⛔ No — auth flow changes, Keycloak config, client impact | Future (Integration/API Lead) | Integration / API Lead (future — not yet active) | Security / Privacy Lead |
| 30 | **Dynamic Client Registration** (RFC 7591) | Clients must be pre-configured out of band — not discoverable | Low | ⛔ No — Keycloak + client registration endpoint work | Future (Integration/API Lead) | Integration / API Lead (future — not yet active) | Security / Privacy Lead |
| 31 | **Auth Code + PKCE** (interactive user path) | Only M2M supported — no interactive user auth flow | Low | ⛔ No — major feature, depends on #30 | Future (Integration/API Lead) | Integration / API Lead (future — not yet active) | Security / Privacy Lead |
| 32 | **Credential gate `--strict` review** | Tighten `check-credentials.sh` from warn-only to `--strict` after operational baseline confirmed | Low | ✅ Yes | Review after 1 month operational data | Security / Privacy Lead | Engineering Practices Lead |

---

## Completed since audit

| Item | Completed |
|------|-----------|
| branch-test.sh failures fixed (rebuild.sh worker health + validate-networkpolicy.sh timing) | 2026-03-27 |
| mTLS MCP→Worker via PeerAuthentication STRICT (DEC-001 resolved) | 2026-03-26 |
| Branch isolation: SHA-based image tags in rebuild.sh | 2026-03-26 |
| Agent workflow: branch-test.sh + flock + devtools integration | 2026-03-26 |
| DEC-005 logged in decision-log.md | 2026-03-26 |

---

## How to work an item

1. Pick an `✅ Yes` item
2. Create a branch: `git checkout -b <item-number>-short-description`
3. Implement and commit with clear messages
4. Run: `./scripts/devtools-run.sh ./scripts/branch-test.sh`
5. All 5 steps must pass before opening a PR
6. Tag the implementation owner and validation owner in the PR description
