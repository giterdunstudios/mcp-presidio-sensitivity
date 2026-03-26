# Phase 1 Pipeline

## Track A — Critical Path

Structured logging is the foundation. Each step gates the next. Gate 1 (audit trail
sign-off) is required for Phase 1 exit regardless of Track B status.

```mermaid
flowchart TB
    G0{{"Gate 0\nAll 4 specs reviewed\nSecurity/Privacy Lead\n✅ CLEARED"}}

    A1["A1 · Structured Logging\nMCP Server + Worker\nOTel-aligned JSON schema\nenvironment field · log level policy\nStatus: ✅ COMPLETE"]

    A2["A2 · Audit Trail\naudit/trail.py\nctx var wired into classify\nappend-only · no payload\nStatus: ✅ COMPLETE"]

    G1{{"Gate 1\nAudit Trail Sign-off\nSecurity/Privacy Lead\n✅ CLEARED"}}

    A3["A3 · OTel + Jaeger\ntracing.py × 2 services\njaeger.yaml · Helm deploy\nW3C traceparent propagation\nStatus: ✅ COMPLETE"]

    A4S["A4 · Prometheus/Grafana Spec\nMetrics schema · dashboard plan\nScope confirmation required\nStatus: ✅ COMPLETE"]

    G3{{"Gate 3\nPrometheus spec scope\nProduct Lead confirm\n✅ CLEARED"}}

    A4I["A4 · Prometheus/Grafana Impl\n/metrics endpoint · Grafana dashboard\nJaeger data source wired\nStatus: ⬜ NEXT"]

    EXIT(["Phase 1 Exit\nSec Lead + Product Lead sign-off"])

    G0 --> A1
    A1 --> A2
    A2 --> G1
    G1 -->|approved| A3
    A3 --> A4S
    A4S --> G3
    G3 -->|confirmed| A4I
    A4I --> EXIT
    G1 --> EXIT

    classDef gate fill:#e8a000,stroke:#b07800,color:#000,font-weight:bold
    classDef done fill:#1a7a3a,stroke:#0f5228,color:#fff
    classDef work fill:#1168bd,stroke:#0a4d8c,color:#fff
    classDef terminal fill:#1a1a2e,stroke:#555,color:#fff

    class G0,G1,G3 gate
    class A1,A2,A3,A4S done
    class A4I work
    class EXIT terminal
```

---

## Track B — Parallel Hardening

Runs concurrently with Track A. Gate 2 (NetworkPolicy) is required for Phase 1 exit.
Rate limiting (B4) has a soft dependency on A1 log format being stable.

```mermaid
flowchart TB
    G0{{"Gate 0\nAll 4 specs reviewed\n✅ CLEARED"}}

    B1["B1 · Scan Timeout\nSCAN_TIMEOUT error code\n10s default\nHelm values.yaml wired\nStatus: ✅ COMPLETE"]

    B2a["B2a · NetworkPolicy\nWorker ingress\nAllow MCP server label only\nStatus: ✅ COMPLETE"]

    B2b["B2b · NetworkPolicy\nMCP server egress\nAllow worker + Keycloak + DNS\nStatus: ✅ COMPLETE"]

    G2{{"Gate 2\nNetworkPolicy Sign-off\nSecurity/Privacy Lead\n✅ CLEARED"}}

    B3["B3 · SlowAPI Spike\nDeferred to Phase 2\nRate limiting → Istio/Envoy\nSee DEC-003\nStatus: ➡️ DEFERRED"]

    B4["B4 · Rate Limiting\nDeferred to Phase 2\nRate limiting → Istio/Envoy\nChecklist in DEC-003\nStatus: ➡️ DEFERRED"]

    EXIT(["Phase 1 Exit\nSec Lead + Product Lead sign-off"])

    G0 --> B1
    G0 --> B2a
    G0 --> B2b
    G0 --> B3
    B2a --> G2
    B2b --> G2
    B1 --> EXIT
    G2 --> EXIT
    B3 --> EXIT
    B4 --> EXIT

    classDef gate fill:#e8a000,stroke:#b07800,color:#000,font-weight:bold
    classDef done fill:#1a7a3a,stroke:#0f5228,color:#fff
    classDef deferred fill:#555,stroke:#333,color:#ccc
    classDef work fill:#1168bd,stroke:#0a4d8c,color:#fff
    classDef terminal fill:#1a1a2e,stroke:#555,color:#fff

    class G0,G2 gate
    class B1,B2a,B2b done
    class B3,B4 deferred
    class EXIT terminal
```

---

## Pre-Phase 2 Gate — k3d Migration (DEC-004)

Must complete before Phase 2 (Istio/Cilium) work begins. No Phase 1 deliverable is
blocked. See `planning/decision-log.md` DEC-004 for full rationale and work breakdown.

```mermaid
flowchart LR
    P1EXIT(["Phase 1 Exit"])

    GK{{"Pre-Phase 2 Gate\nk3d migration complete\nAll validation scripts pass\n⬜ PENDING"}}

    KA["A · Cluster + Registry\nk3d-config.yaml\nsetup-local.sh updated\nRegistry on port 5000\nStatus: ⬜"]

    KB["B · Image Workflow\nrebuild.sh: kind load → docker push\nvalues.local.yaml: pullPolicy + registry\nStatus: ⬜"]

    KC["C · Supporting Scripts\nstatus.sh · README · remove kind-config\nStatus: ⬜"]

    KD["D · Full Regression\nsetup · status · test · auth\nnetworkpolicy · demo a\nStatus: ⬜"]

    KE["E · Cilium CNI (optional)\nDisable Flannel · install Cilium\nRe-validate NetworkPolicy\nStatus: ⬜ Phase 2 only"]

    P2START(["Phase 2 Start\nIstio · Cilium · cert-manager"])

    P1EXIT --> GK
    GK --> KA
    KA --> KB
    KB --> KC
    KC --> KD
    KD --> P2START
    KD --> KE
    KE --> P2START

    classDef gate fill:#e8a000,stroke:#b07800,color:#000,font-weight:bold
    classDef work fill:#1168bd,stroke:#0a4d8c,color:#fff
    classDef optional fill:#555,stroke:#333,color:#ccc
    classDef terminal fill:#1a1a2e,stroke:#555,color:#fff

    class GK gate
    class KA,KB,KC,KD work
    class KE optional
    class P1EXIT,P2START terminal
```
