# Video Path Diagnostics Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make video-path diagnostics fail-closed on measurable network faults and clearly separate device LAN evidence from Pi/WAN evidence.

**Architecture:** Keep existing read-only Bash/Python diagnostic. Validate the target IP before probing, classify LAN/gateway/WAN measurements with explicit thresholds, and print machine-readable summary lines. Do not claim that Pi-side HTTPS proves client video transport; document that Layer-2 ZTE topology prevents passive inspection of another client’s encrypted stream.

**Tech Stack:** Bash, Python standard library, `ping`, `curl`, existing AdGuard Home and modem inventory APIs.

**Spec:** `docs/DNS-BLOCKING.md` and adversarial video-path findings from 2026-08-30.

## Global Constraints

- No new hardware, proxy, MITM, or TLS decryption.
- Diagnostic remains read-only.
- `VIDEO_TEST_IP` accepts only a literal IPv4 or IPv6 address.
- Default client loss warning threshold is 20%; gateway/WAN loss is failure.
- Unknown or unavailable evidence must never be reported as healthy.
- Run project validation and live checks before claiming completion.

---

### Task 1: Fail-closed target and probe classification

**Files:**
- Modify: `scripts/pi/diagnose-video-path.sh`
- Test: `scripts/mac/test-dns-blocking-contract.sh`

**Interfaces:**
- Consumes: `VIDEO_TEST_IP`, `VIDEO_QUERY_RECENCY_SEC`, optional `VIDEO_CLIENT_MAX_LOSS_PERCENT`.
- Produces: `VIDEO_PROBE_STATUS`, `VIDEO_CLIENT_PACKET_LOSS`, `VIDEO_GATEWAY_PACKET_LOSS`, `VIDEO_WAN_PACKET_LOSS`.

- [x] Validate `VIDEO_TEST_IP` with Python `ipaddress.ip_address` before any ping.
- [x] Parse packet-loss and RTT summaries instead of swallowing all ping failures.
- [x] Return `WARN` for client loss above threshold and `FAIL` for gateway/WAN loss or missing summaries.
- [x] Keep ICMP limitations explicit; do not infer video health from a successful ping.
- [x] Add contract checks for validation, thresholds, and non-zero failure paths.

### Task 2: Add honest WAN HTTPS evidence

**Files:**
- Modify: `scripts/pi/diagnose-video-path.sh`
- Modify: `docs/DNS-BLOCKING.md`
- Modify: `docs/ENV.md`
- Modify: `.env.example`

**Interfaces:**
- Consumes: `VIDEO_HTTP_PROBE_URL`, `VIDEO_HTTP_PROBE_TIMEOUT_SEC`.
- Produces: `VIDEO_HTTP_STATUS`, `VIDEO_HTTP_TIME`, `VIDEO_HTTP_PROBE`.

- [x] Probe a configurable HTTPS endpoint from Pi using `curl`, defaulting to YouTube’s lightweight endpoint.
- [x] Classify timeout/HTTP failure as `FAIL` for WAN evidence.
- [x] Label this as Pi-originated WAN evidence, not client-stream evidence.
- [x] Document limitations of encrypted video and ZTE Layer-2 visibility.

### Task 3: Regression and live verification

**Files:**
- Modify: `GATES.md`

- [x] Run shell lint, syntax, contract, Compose, DNS, health, and smoke gates.
- [x] Run diagnostic against all currently known video-capable device IPs.
- [x] Verify bad target and forced probe failure return non-zero.
- [x] Record measured evidence and remaining limitations in `GATES.md`.
