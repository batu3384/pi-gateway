# Design: English docs + INSTALL + doctor

**Date:** 2026-07-25  
**Status:** Approved (user)  
**Note:** Spec lives under `docs/` because `docs/superpowers/` is removed in this work.

## Goal

Make the public GitHub repo English-first and easier to install: professional README, English markdown, install guide, and a non-interactive `make doctor` prerequisite check.

## Out of scope

- Interactive `.env` wizard / `make bootstrap`
- MkDocs or docs site generator
- Translating shell script log messages (Turkish OK in scripts for now)
- Changing runtime behavior of the Pi stack beyond docs + doctor

## Changes

### 1. Delete `docs/superpowers/`

Remove the entire tree from git (plans/specs archive). No replacement archive in-repo.

### 2. README.md (English)

Sections:

1. What it is (one short paragraph)
2. Stack (compact table or bullet list)
3. Requirements (Mac + Pi)
4. Quick start (`cp .env.example .env` → edit → `make doctor` → `make install`)
5. Documentation index (links)
6. Security (link `.github/SECURITY.md` + `docs/SECURITY.md`)
7. License (MIT)

### 3. Install guide

- Rename/replace `KURULUM.md` → `INSTALL.md` (English)
- Content: requirements, hybrid storage note, router DNS one-time step, `make` commands, basic troubleshooting
- Update any links that pointed at `KURULUM.md`

### 4. Translate remaining markdown

English bodies for:

- Root: `AGENTS.md`, `CLAUDE.md` (if kept), any other root `.md`
- `docs/*.md` including FAZ2/3/4 (keep filenames or rename to PHASE*.md — prefer keep filenames to minimize link churn, English headings/body)

Do **not** recreate superpowers content.

### 5. `make doctor` / `scripts/mac/doctor.sh`

Non-interactive checks:

| Check | Severity |
|-------|----------|
| `docker` available | fail |
| `ssh` available | fail |
| `python3` available | fail |
| `.env` exists | fail |
| Required passwords not `CHANGE_ME*` / empty (AGH, and enabled services) | fail |
| `PI_STATIC_IP` set | warn if empty (discover later OK) |
| Optional: `shellcheck` present | warn |

Exit non-zero on any fail. Wire `make doctor`. Mention in README quick start before `make install`.

## Success criteria

- No `docs/superpowers/` in the repo
- No Turkish prose in tracked `.md` files (code identifiers / IPs / hostnames unchanged)
- `make doctor` fails closed on missing `.env` / placeholder passwords
- `make validate` still passes
- README alone is enough for a stranger to start install via INSTALL.md

## Implementation order

1. Delete superpowers
2. Add `doctor.sh` + Makefile target
3. Write README + INSTALL.md
4. Translate remaining docs + fix links
5. Validate + commit
