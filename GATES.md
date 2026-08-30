# Pi Gateway Verification Gates

## Gate 1: Local validation
- CHECK: `./scripts/mac/validate.sh`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — validate-stack, all repository validation suites, compose validation, and `Validation passed`

## Gate 2: Shell lint
- CHECK: `shellcheck -S warning scripts/pi/*.sh scripts/mac/*.sh scripts/lib/*.sh`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — exit code 0; no ShellCheck findings

## Gate 3: Python syntax
- CHECK: `python3 -m py_compile scripts/lib/*.py`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — exit code 0 for all `scripts/lib/*.py`

## Gate 4: Regression contracts
- CHECK: `./scripts/mac/test-dns-blocking-contract.sh && ./scripts/mac/test-adversarial-fixes.sh && ./scripts/mac/test-home-ops-phase1.sh`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — DNS (coverage state), adversarial, and home-ops contracts all completed

## Gate 5: Compose configuration
- CHECK: `docker-compose -f compose/docker-compose.yml --env-file .env config -q`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — standalone Compose `config -q` exit code 0

## Gate 6: Live DNS coverage
- CHECK: `make diagnose-dns && make audit-dns`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — live audit `3/3 (%100)` and `COVERAGE_OK` (stale querylog cihazları aktif kanıta katılmadı); evidence status `WARN` because AdGuard API exposes `api-unknown` protocol, with `protocol_unknown=1`; IPv6 RDNSS, DoH, DNSSEC and WAN drop checks passed

## Gate 7: Live health and smoke
- CHECK: `make test-remote`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — live health exit code 0; smoke `63/63 passed`; coverage status `2` (WARN), protocol unknown `1`, RDNSS `1`; offsite backup age `0d`, last successful drill age `0d`, current drill failure `0`; Pi/Mac Restic full checks clean

Backup integrity note: Eski bozuk repo’lar `/mnt/ssd/pi-gateway-recovery/` ve Mac’te `restic-before-recovery-*` altında korunuyor. Aktif repo temiz snapshot ile yeniden oluşturuldu; Pi ve Mac’te `%100` veri check, normal backup ve restore drill geçti.

## Video path evidence
- Command: `VIDEO_TEST_IP=<client-ip> make diagnose-video`
- Evidence: ✅ DETECTED — one WLAN client showed high packet loss/jitter while gateway/WAN/Pi HTTPS stayed clean; other clients returned `VIDEO_PROBE_STATUS=OK`. Isolates degradation to client radio path, not Pi/WAN. Forced invalid HTTPS probe returns `VIDEO_PROBE_STATUS=FAIL` and exit `1`.
