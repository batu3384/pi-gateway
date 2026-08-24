# Wiki source (not published)

Markdown in this folder is the **source of truth** for the GitHub Wiki. Only files synced by `scripts/sync-wiki.sh` appear on GitHub; this README stays local.

## First-time setup

1. Enable Wiki on the GitHub repo (Settings → Features → Wikis).
2. On GitHub, open **Wiki → Create the first page** and save **Home** once (empty OK). This initializes the `.wiki.git` repo.
3. Ensure `gh` is authenticated: `gh auth login`

## Sync

From repo root:

```bash
chmod +x scripts/sync-wiki.sh
./scripts/sync-wiki.sh
```

Optional env:

| Variable | Default | Purpose |
|----------|---------|---------|
| `GITHUB_REPOSITORY` | `batu3384/pi-gateway` | `owner/repo` for wiki remote |
| `GH_TOKEN` | (from `gh auth`) | Push to `.wiki.git` |

## What gets synced

Wiki page links use the `.md` suffix (`[FAQ](FAQ.md)`) so in-repo checkers and Gollum both resolve.

- All `wiki/*.md` except `README.md`
- `_Sidebar.md` → GitHub sidebar
- `--delete` removes wiki pages removed from source

## Edit workflow

1. Edit markdown under `wiki/`
2. Run `./scripts/sync-wiki.sh`
3. Verify: `https://github.com/batu3384/pi-gateway/wiki`

Do not edit the GitHub Wiki UI directly — changes will be overwritten on the next sync.
