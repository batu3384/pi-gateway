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
- EVIDENCE: ✅ PASSED — DNS, adversarial, and home-ops contracts all completed

## Gate 5: Compose configuration
- CHECK: `docker-compose -f compose/docker-compose.yml --env-file .env config -q`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — standalone Compose `config -q` exit code 0

## Gate 6: Live DNS coverage
- CHECK: `make diagnose-dns && make audit-dns`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — `COVERAGE_OK`; live DNS diagnose and audit exit code 0

## Gate 7: Live health and smoke
- CHECK: `make test-remote`
- EXPECT: `exit_code: 0`
- EVIDENCE: ✅ PASSED — live health exit code 0; smoke `63/63 passed`
