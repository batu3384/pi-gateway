# English docs + INSTALL + doctor — Implementation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox syntax.

**Goal:** English-first public docs, remove `docs/superpowers/`, add `INSTALL.md` + `make doctor`.

**Architecture:** Docs-only translation plus one Mac script (`doctor.sh`) wired through Makefile. No stack runtime changes. Plan path is `docs/plans/` because `docs/superpowers/` is deleted in Task 1.

**Tech Stack:** Bash, Make, Markdown

## Global Constraints

- All tracked `.md` prose in English
- No interactive `.env` wizard
- Doctor: fail on missing tools / `.env` / `CHANGE_ME*` required passwords; warn if `PI_STATIC_IP` empty
- Keep `docs/FAZ*.md` filenames; English bodies
- Script log strings may stay Turkish (out of scope)
- After Task 1, never recreate `docs/superpowers/`

---

### Task 1: Delete superpowers

**Files:**
- Delete: `docs/superpowers/**`

- [ ] **Step 1:** `git rm -r docs/superpowers`
- [ ] **Step 2:** Confirm no remaining references in tracked files (fix links if any)
- [ ] **Step 3:** Commit `chore: remove docs/superpowers archive`

---

### Task 2: `make doctor`

**Files:**
- Create: `scripts/mac/doctor.sh`
- Modify: `Makefile` — add `doctor` phony + target
- Test: run script with missing `.env` / placeholder password

**Produces:**
- `doctor.sh` exit 0 only when hard checks pass
- `make doctor` invokes it

- [ ] **Step 1:** Write `scripts/mac/doctor.sh`:
  - source `scripts/lib/common.sh`, `load_env` if `.env` exists
  - require `docker`, `ssh`, `python3` (fail)
  - require `.env` exists (fail)
  - fail if `AGH_ADMIN_PASSWORD` empty or matches `CHANGE_ME*|Degistir*|changeme*|password|admin`
  - if `ENABLE_DOZZLE=true`, same for `DOZZLE_ADMIN_PASSWORD`
  - if `ENABLE_FORGEJO=true`, same for `FORGEJO_ADMIN_PASSWORD`
  - if `ENABLE_SYNCTHING=true`, same for `SYNCTHING_GUI_PASSWORD`
  - if `ENABLE_RESTIC=true`, same for `RESTIC_PASSWORD`
  - if `ENABLE_N8N=true`, require `N8N_ENCRYPTION_KEY` length ≥ 32 and not empty
  - warn if `PI_STATIC_IP` empty
  - warn if `shellcheck` missing
  - print OK/FAIL summary; exit 1 if any fail
- [ ] **Step 2:** Add to Makefile:
  ```make
  doctor:
  	@chmod +x scripts/mac/doctor.sh 2>/dev/null || true
  	@./scripts/mac/doctor.sh
  ```
- [ ] **Step 3:** Verify: `./scripts/mac/doctor.sh` exits 0 on current Mac `.env` (or documents fails)
- [ ] **Step 4:** Commit `feat(mac): add make doctor prerequisite checks`

---

### Task 3: README + INSTALL.md

**Files:**
- Rewrite: `README.md` (English sections per design)
- Create: `INSTALL.md` (English from `KURULUM.md`)
- Delete: `KURULUM.md`
- Modify: any links to `KURULUM.md` → `INSTALL.md`

- [ ] **Step 1:** Write English `README.md` (What / Stack / Requirements / Quick start with `make doctor` / Docs index / Security / License)
- [ ] **Step 2:** Write English `INSTALL.md`; delete `KURULUM.md`
- [ ] **Step 3:** Commit `docs: English README + INSTALL.md`

---

### Task 4: Translate remaining markdown

**Files:**
- Modify: `AGENTS.md`, `CLAUDE.md`, `.github/SECURITY.md`, `docs/*.md` (all except design/plan if still Turkish), including `docs/README-INSTALL-DOCTOR-design.md` can stay English
- Rename optional: `docs/SSD-KURULUM.md` → `docs/SSD-INSTALL.md` and fix links

- [ ] **Step 1:** Translate each `docs/*.md` body to English
- [ ] **Step 2:** Translate `AGENTS.md`, `CLAUDE.md`, `.github/SECURITY.md`
- [ ] **Step 3:** Rename `SSD-KURULUM.md` → `SSD-INSTALL.md`; fix links
- [ ] **Step 4:** Grep for Turkish chars / `KURULUM` / `superpowers` leftovers; fix
- [ ] **Step 5:** Commit `docs: translate remaining markdown to English`

---

### Task 5: Validate + push readiness

- [ ] **Step 1:** `make validate` (or at least `validate-public-repo` + `doctor`)
- [ ] **Step 2:** Confirm `docs/superpowers` gone; no Turkish UI prose in `.md` (spot-check)
- [ ] **Step 3:** Final status clean or list uncommitted leftovers

---

## Spec coverage

| Spec item | Task |
|-----------|------|
| Delete superpowers | 1 |
| English README | 3 |
| INSTALL.md | 3 |
| Translate docs | 4 |
| make doctor | 2 |
| Success criteria / validate | 5 |
