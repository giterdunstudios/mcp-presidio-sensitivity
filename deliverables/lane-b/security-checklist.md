# Security Checklist — Lane B: Presidio Worker

**Phase:** 0
**Date:** 2026-03-24
**Author:** Lane B agent (Claude Sonnet 4.6)
**Spec reference:** §4.6

This checklist covers the security controls that apply to the Presidio worker
specifically.  Controls that belong to the MCP server layer (authn/authz, TLS,
OAuth) are out of scope for this component and are addressed in Lane A.

---

## Spec §4.6 checklist items

### Authn/authz implemented

**Scope for this component:** The worker runs on the private cluster network
only.  It does not authenticate callers directly — authentication and
authorisation are enforced by the MCP server / orchestrator before the worker
is invoked.  The worker must not be reachable from untrusted network paths.

**Status:** Partially addressed
**Evidence:**
- Worker binds on `0.0.0.0:8080` with no auth middleware (by design — private
  network only)
- Helm values set `service.type: ClusterIP` — not exposed outside the cluster
- `automountServiceAccountToken: false` — worker pod has no K8s API credentials
- Network policy manifest is scaffolded in values.yaml; enforcement requires
  cluster-level NetworkPolicy support

**Remaining:** Network policy manifest needs to be deployed in environments
where NetworkPolicy is supported to formally restrict inbound access to the
MCP server only.

---

### TLS enforced

**Scope for this component:** Internal cluster communication between MCP server
and worker.

**Status:** Deferred to cluster mesh / ingress layer
**Evidence:**
- Worker serves plain HTTP on port 8080
- TLS termination should be handled by a service mesh (e.g., Istio mTLS) or
  at the cluster ingress layer
- No plaintext transport crosses external network boundaries because the worker
  service type is ClusterIP

**Remaining:** Service mesh mTLS or equivalent should be confirmed before
production deployment.

---

### Payload logging disabled and tested

**Status:** Implemented
**Evidence:**
- `main.py` — all `logger.*` calls reference only `scan_id`, `decision`,
  `max_severity_band`, `findings_count`, `policy_profile`, `detector_version`,
  `content_type`, `size_bytes`.  The `content` field is never referenced in
  any log statement.
- `analyzer.py` — exception handler logs `"Presidio analysis raised an
  exception (text content suppressed)"` — the `text` argument is never
  included.
- `minimizer.py` — receives only stripped findings `[{entity_type, score}]`;
  no payload data enters this module.
- Error responses (`ErrorResponse`) contain only `error_code` and `message`.

**Remaining:** Manual verification with a test payload containing known PII
should confirm that no payload content appears in the log stream.  This is a
Definition of Done item.

---

### Max size and timeout controls tested

**Status:** Implemented (size); partially addressed (timeout)
**Evidence:**
- Size: `main.py` reads `body_bytes = await request.body()` then checks
  `len(body_bytes) > config.MAX_PAYLOAD_BYTES` before any parsing.  Default
  limit is 1 MiB (`MAX_PAYLOAD_BYTES = 1_048_576`).  Rejects with
  `PAYLOAD_TOO_LARGE` (HTTP 413).
- Timeout: uvicorn worker timeout applies to the full request lifecycle.
  An explicit per-scan timeout (spec §4.4) is not yet implemented.

**Remaining:** Explicit scan timeout middleware should be added in Phase 1.
Current mitigation: uvicorn's default worker timeout prevents indefinite hangs.

---

### Worker isolation verified

**Status:** Implemented
**Evidence:**
- `podSecurityContext`: `runAsNonRoot: true`, `runAsUser: 1000`,
  `runAsGroup: 1000`
- `containerSecurityContext`: `allowPrivilegeEscalation: false`,
  `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`
- `automountServiceAccountToken: false`
- Dockerfile: non-root user `worker` (uid 1000), `nologin` shell
- No bash in image (`python:3.11-slim` base; bash is not installed by default)
- `/tmp` mounted as memory-backed `emptyDir` to satisfy read-only root FS
  requirement while allowing uvicorn/spaCy temporary writes
- CPU and memory limits defined in `values.yaml`:
  `limits.memory: 512Mi`, `limits.cpu: 500m`

---

### Audit schema reviewed

**Status:** Implemented (worker output)
**Evidence:**
- `ScanResponse` contains: `scan_id`, `status`, `sensitivity_detected`,
  `max_severity_band`, `matched_categories`, `entity_summary` (counts only),
  `decision`, `confidence_summary` (`highest_score`, `findings_count`),
  `policy_profile`, `detector_version`, `timestamp`
- No matched substrings, offsets, or payload excerpts in any response field
- `entity_summary` values are integer counts

**Remaining:** Audit store integration (writing scan metadata to an external
audit log) is a Phase 1 concern.  The worker currently returns the bounded
result only; persistent audit storage is the MCP server's responsibility.

---

### Recognizer bundle versioning implemented

**Status:** Partially addressed
**Evidence:**
- `detector_version` field in `ScanResponse` reports the installed
  `presidio-analyzer` package version at runtime
- `APPROVED_ENTITY_TYPES` in `analyzer.py` acts as the recognizer allowlist;
  any Presidio built-in not on the list is suppressed

**Remaining:**
- Pinned dependency versions in `requirements.txt` are currently version ranges;
  exact pins should be locked after integration testing
- Custom recognizer change control process is not yet defined (no custom
  recognizers exist at MVP)
- Image tag should be pinned in `values.yaml` for production deployments

---

### Dependency scan clean or risk-accepted

**Status:** Complete — one finding risk-accepted
**Evidence:**
- `pip-audit` run against `requirements.lock.txt` for both images (2026-03-24)
- Lock files generated via `pip-compile` from `requirements.txt` constraints
- MCP server image: **zero vulnerabilities**
- Worker image: **one finding** — CVE-2026-4539 in `pygments==2.19.2`

**CVE-2026-4539 (pygments 2.19.2) — risk accepted**
- Transitive dependency: `pygments` ← `rich` ← `spacy` / `presidio-analyzer`
- No upstream fix available as of 2026-03-24 (2.19.2 is the latest release)
- `pygments` is not invoked in the worker's production request path; it is used only by CLI tooling in the `rich` / `spacy` packages that are not executed at runtime
- Documented in `src/worker/.pip-audit-ignore`
- Action: re-evaluate when a fixed pygments release is published; update lock file and remove ignore entry

---

### Failure paths do not leak payload data

**Status:** Implemented
**Evidence:**
- `PAYLOAD_TOO_LARGE` — checked before body parsing; response contains only
  `error_code` and `message`
- `UNSUPPORTED_CONTENT_TYPE` — checked before body parsing (header check) and
  after parsing (body field check); response contains only `error_code` and
  `message`
- `INVALID_REQUEST_SCHEMA` — ValidationError caught without referencing body
  content; `body_bytes` deleted in `finally` block
- `SCAN_FAILED` — analysis exception caught; exception message is generic;
  `scan_request` deleted in `finally` block
- No FastAPI default exception handler receives a reference to payload content

**Remaining:** End-to-end failure path testing with a synthetic payload that
contains known PII should confirm no leakage in logs or responses.

---

## Additional controls not in §4.6 checklist

### Non-root runtime

**Status:** Implemented
**Evidence:** Dockerfile `USER worker` (uid 1000); Helm `runAsUser: 1000`,
`runAsNonRoot: true`.

### Restricted content types

**Status:** Implemented
**Evidence:** Content-type header is checked against `SUPPORTED_CONTENT_TYPES`
before the request body is read.  Unsupported types return HTTP 415 immediately.

### No payload persistence

**Status:** Implemented
**Evidence:** No disk writes in any code path.  `/tmp` is memory-backed
(`emptyDir.medium: Memory`).  No database or external store is accessed by the
worker.

### Secrets handling

**Status:** Not applicable to this component at MVP
**Evidence:** The worker has no secrets.  All configuration is non-sensitive
and injected via ConfigMap.  If future recognizer API keys or credentials are
required, they must be injected as Kubernetes Secrets and never baked into the
image.

---

## Summary

| Control | Status |
|---------|--------|
| Payload logging disabled | Implemented |
| Payload not in error responses | Implemented |
| Payload not in response output | Implemented |
| Max payload size enforced | Implemented |
| Non-root runtime | Implemented |
| Read-only root filesystem | Implemented |
| CPU/memory limits | Implemented |
| Restricted content-type allowlist | Implemented |
| No disk writes / no payload persistence | Implemented |
| No K8s service account token | Implemented |
| Recognizer allowlist | Implemented |
| Detector version in audit output | Implemented |
| Worker not exposed outside cluster | Implemented (ClusterIP) |
| Scan timeout enforcement | Partial — uvicorn default only |
| TLS / service mesh | Deferred to platform layer |
| Network policy enforcement | Deferred (scaffolded in values) |
| Dependency scan | Complete — CVE-2026-4539 risk-accepted (no upstream fix) |
| Exact dependency pinning | Pending |
| Audit store integration | Phase 1 |
| Custom recognizer change control | Phase 1 |

**Ready for Security/Privacy Lead review.**
Blocking items before production: dependency scan, exact dependency pinning,
network policy enforcement, scan timeout middleware.
