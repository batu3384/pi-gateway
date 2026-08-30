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
- Command: `VIDEO_TEST_IP=192.168.1.113 make diagnose-video`
- Evidence: ✅ DETECTED — `192.168.1.113` client `%70` packet loss, `25.954 ms` jitter, gateway/WAN `%0`, Pi HTTPS `204` in `0.103 s`; `VIDEO_PROBE_STATUS=WARN` and exit `10`. `192.168.1.109` and `.111` both returned `VIDEO_PROBE_STATUS=OK` with `%0` loss, fresh video DNS evidence, and Pi HTTPS `204`. This isolates degradation to `.113`, not Pi/WAN congestion. No fresh video query was present for `.113` in the `300s` evidence window, so its client CDN transport remains unproven. Forced invalid HTTPS probe returned `VIDEO_PROBE_STATUS=FAIL` and exit `1`.
