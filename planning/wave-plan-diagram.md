# Tech Debt Wave Plan

Waves 1 and 2 can both start immediately — different files, no contention.
Wave 3 has hard sequencing within it. Wave 4 is lower priority with two gates.

```mermaid
flowchart TD
    subgraph W1["Wave 1 — Start now (fully parallel)"]
        w1a["#3 Worker restart investigation\nTech Lead → Eng Practices"]
        w1b["#4 SBOM refresh post-Phase 2\nSecurity Lead → Tech Lead"]
        w1c["#8 DR runbook\nEng Practices → Product"]
        w1d["#9 Teardown + re-run verify\nTech Lead → Eng Practices"]
        w1e["#11 Dev/prod parity delta\nEng Practices → Product"]
        w1f["#18+#19 Planning tasks\nProduct → Eng Practices"]
    end

    subgraph W2["Wave 2 — Start now (different files, no W1 dependency)"]
        w2a["#1+#2+#31 Registry GC script + README + accuracy\nEng Practices → Tech Lead"]
        w2b["#6 Credential gate script\nSecurity Lead → Eng Practices"]
        w2c["#7 RFC 9728 integration test\nTech Lead → Security Lead"]
        w2d["#10 k3d version floor check\nEng Practices → Tech Lead"]
        w2e["#13 Helm versioning policy doc\nEng Practices → Tech Lead"]
    end

    subgraph W3["Wave 3 — Sequential (rebuild.sh + helm contention)"]
        w3a["#5 requirements.lock.txt sync check\nTech Lead → Eng Practices"]
        w3b["#14 Helm test hooks\nTech Lead → Eng Practices"]
        w3c["#20 Image vuln scanning\nSecurity Lead → Tech Lead\nwarn HIGH · block CRITICAL"]
    end

    subgraph W4["Wave 4 — Lower priority"]
        w4a["#21 Registry auth gap doc\nEng Practices → Security Lead"]
        w4b["#22 SBOM cdxgen automation\nTech Lead → Security Lead"]
        w4c["#26 Prometheus → Worker scraping\nTech Lead → Security Lead"]
        w4d["#28 Image signing (Cosign)\nSecurity Lead → Tech Lead"]
        w4e["#13b Coordinated Helm 0.1.0→0.2.0 bump\nEng Practices → Tech Lead"]
    end

    GATE_SEC["🔑 Security Lead commits\nBP-001 → approved-for-implementation"]
    GATE_W2["Wave 2 merges"]
    GATE_HELM["#13 merged"]
    GATE_14_26["#14 + #26 merged"]

    GATE_W2 --> w3a
    GATE_HELM --> w3b
    w3a --> w3c
    GATE_SEC --> w4b
    GATE_14_26 --> w4e

    w2e -.->|unblocks| GATE_HELM
    w3b -.->|contributes to| GATE_14_26
    w4c -.->|contributes to| GATE_14_26

    classDef wave1 fill:#1a7a3a,stroke:#0f5228,color:#fff
    classDef wave2 fill:#1168bd,stroke:#0a4d8c,color:#fff
    classDef wave3 fill:#8b4513,stroke:#5a2d0c,color:#fff
    classDef wave4 fill:#555,stroke:#333,color:#ccc
    classDef gate fill:#e8a000,stroke:#b07800,color:#000,font-weight:bold

    class w1a,w1b,w1c,w1d,w1e,w1f wave1
    class w2a,w2b,w2c,w2d,w2e wave2
    class w3a,w3b,w3c wave3
    class w4a,w4b,w4c,w4d,w4e wave4
    class GATE_SEC,GATE_W2,GATE_HELM,GATE_14_26 gate
```

## Branch name reference

| Wave | Branch | Items |
|------|--------|-------|
| 1 | `3-worker-restart-investigation` | #3 |
| 1 | `4-sbom-refresh` | #4 |
| 1 | `8-dr-runbook` | #8 |
| 1 | `9-teardown-verification` | #9 |
| 1 | `11-parity-delta` | #11 |
| 1 | `18-19-planning` | #18, #19 |
| 2 | `1-2-31-registry-gc` | #1, #2, #31 |
| 2 | `6-credential-gate` | #6 |
| 2 | `7-rfc9728-integration-test` | #7 |
| 2 | `10-k3d-version-check` | #10 |
| 2 | `13-helm-version-policy` | #13 |
| 3 | `5-lockfile-sync-check` | #5 |
| 3 | `14-helm-test-hooks` | #14 |
| 3 | `20-image-vuln-scanning` | #20 |
| 4 | `21-registry-auth-gap` | #21 |
| 4 | `22-sbom-cdxgen` | #22 (gate: Security Lead BP-001 sign-off) |
| 4 | `26-prometheus-worker-scraping` | #26 |
| 4 | `28-image-signing` | #28 |
| 4 | `13b-helm-version-bump` | #13b (gate: #14 + #26 merged) |
