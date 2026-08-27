#!/usr/bin/env bash
# Hermes bülten/cron regression
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-hermes-bulletins] HATA: $*" >&2; exit 1; }
ok() { echo "[test-hermes-bulletins] OK: $*"; }

tmpl="$ROOT/config/hermes/cron-jobs.template.json"
patch="$ROOT/scripts/lib/hermes-cron-patch.py"
cfg="$ROOT/scripts/pi/patch-hermes-config-pi.sh"
unit="$ROOT/host/systemd/hermes-gateway.service"
watchdog="$ROOT/scripts/pi/watchdog.sh"
netalert="$ROOT/scripts/lib/netalert-devices.py"
fx="$ROOT/scripts/pi/fx-quote.sh"
merge="$ROOT/scripts/lib/hermes-cron-merge.py"
archive="$ROOT/scripts/lib/archive-bulletin.sh"
slo="$ROOT/scripts/lib/bulletin-slo.py"
health="$ROOT/scripts/pi/health-check.sh"
scripts_setup="$ROOT/scripts/pi/setup-hermes-cron-scripts.sh"

[[ -f "$tmpl" ]] || die "cron template yok"
python3 -m json.tool "$tmpl" >/dev/null || die "cron template JSON bozuk"
! grep -q 'aján' "$tmpl" || die "prompt typo aján duruyor"
grep -q 'Pi Gateway · Bülten' "$tmpl" || die "bülten iskeleti yok"
grep -q 'Son 24 saatte' "$tmpl" || die "gece 24s pencere yok"
grep -q 'pi-fx-quote.sh' "$tmpl" || die "piyasa pi-fx-quote.sh yok"
grep -q 'TEKRAR DENEME' "$tmpl" || die "extract 400/403 fallback yok"
grep -q 'Boş mesaj YASAK' "$tmpl" || die "boş mesaj yasağı yok"
grep -q 'TELEGRAM: düz metin' "$tmpl" || die "parse-mode kilit yok"
grep -q 'Piyasa Özeti (18:55)' "$tmpl" || die "18:55 piyasa job yok"
! grep -q '__REMOTE_DIR__' "$tmpl" || die "akşam hâlâ __REMOTE_DIR__"
python3 - <<PY || die "akşam/piyasa job sözleşmesi bozuk"
import json
from pathlib import Path
jobs = json.loads(Path(r"$tmpl").read_text())["jobs"]
eve = next(j for j in jobs if j["name"].startswith("Akşam 7"))
assert eve["enabled_toolsets"] == ["web"], eve["enabled_toolsets"]
assert "terminal" not in eve["enabled_toolsets"]
assert "fx-quote.sh" not in (eve.get("prompt") or "")
assert "18:55" in eve["prompt"]
fxj = next(j for j in jobs if j["name"].startswith("Piyasa"))
assert fxj["no_agent"] is True
assert fxj["script"] == "pi-fx-quote.sh"
assert fxj["schedule"]["expr"] == "55 18 * * *"
morn = next(j for j in jobs if "07:00" in j["name"])
assert "terminal" not in morn["enabled_toolsets"]
assert "web" in morn["enabled_toolsets"]
assert "vcgencmd" not in (morn.get("prompt") or "")
assert "docker ps" not in (morn.get("prompt") or "")
assert "Sunucu" not in (morn.get("prompt") or "")
eve = next(j for j in jobs if j["name"].startswith("Akşam 7"))
assert eve["reasoning_effort"] == "medium"
assert "6 web_search" in eve["prompt"]
assert "__BULLETIN_RECENT_TITLES__" in eve["prompt"]
night = next(j for j in jobs if j["name"].startswith("Gece 23"))
assert night["reasoning_effort"] == "medium"
assert night["enabled_toolsets"] == ["web"]
assert "6 web_search" in night["prompt"]
PY
ok "cron template format/prompt"

grep -q 'cron failure v7' "$patch" || die "hermes-cron-patch v7 yok"
grep -q 'if not job.get("no_agent")' "$patch" || die "v7 no_agent timeout kapısı yok"
grep -q 'Piyasa özeti 18:55' "$patch" || die "v7 piyasa fallback yok"
grep -q 'http 400' "$patch" || die "v7 HTTP 400 yok"
grep -q 'bulletin post helper' "$patch" || die "hermes-cron-patch bulletin post yok"
! grep -q 'Firecrawl 403\|patch-hermes-config-pi\|Ağ Gözcüsü' "$patch" \
  || die "v7 jargon/betik adi kalmis"
ok "cron patch v7"

post="$ROOT/scripts/lib/bulletin-post.py"
python3 "$post" --self-check || die "bulletin-post self-check"
ok "bulletin-post"

grep -q 'HERMES_API_CALL_STALE_TIMEOUT=300' "$unit" || die "systemd stale timeout yok"
ok "gateway stale env"

grep -q 'web.search_backend' "$cfg" || die "search_backend set yok"
grep -q 'ddgs>=9.0,<10' "$cfg" || die "ddgs pin yok"
grep -q 'HERMES_MODEL_TIMEOUT:-300' "$cfg" || die "model.timeout 300 degil"
grep -q 'HERMES_TELEGRAM_STREAMING:-false' "$cfg" || die "telegram streaming default false degil"
grep -q 'HERMES_TELEGRAM_TOOL_PROGRESS:-off' "$cfg" || die "telegram tool_progress default off degil"
grep -q 'case "${_tp}"' "$cfg" || die "tool_progress off→false map yok"
grep -q 'providers.zai.stale_timeout_seconds' "$cfg" || die "stale timeout provider-level degil"
! grep -q 'models.glm-5.3.stale_timeout' "$cfg" || die "glm-5.3 stale config set hala var"
grep -q 'HERMES_MAX_WEB_SEARCHES:-6' "$cfg" || die "max_web_searches default 6 degil"
grep -q 'HERMES_MAX_WEB_EXTRACTS:-8' "$cfg" || die "max_web_extracts yok"
grep -q 'HERMES_COMPRESS_TOKEN_CAP:-96000' "$cfg" || die "compress token cap 96000 degil"
grep -q 'HERMES_SESSION_RESET_MODE:-both' "$cfg" || die "session_reset both yok"
grep -q 'session_reset.bg_process_max_age_hours' "$cfg" || die "bg_process_max_age yok"
grep -q 'yaml_same' "$cfg" || die "config skip-if-same yok"
grep -q 'config degisti' "$cfg" || die "gateway restart yalniz config degisince degil"
ok "hermes config ddgs+timeout"

[[ ! -f "$ROOT/scripts/pi/setup-morning-timer.sh" ]] || die "setup-morning-timer.sh silinmeli"
[[ ! -f "$ROOT/host/systemd/pi-gateway-morning.service" ]] || die "morning service silinmeli"
[[ ! -f "$ROOT/host/systemd/pi-gateway-morning.timer" ]] || die "morning timer silinmeli"
! grep -q 'setup-morning-timer.sh' "$ROOT/scripts/pi/setup-hermes-cron.sh" \
  || die "hermes-cron hala setup-morning-timer cagiriyor"
! grep -q 'setup-morning-timer.sh' "$ROOT/scripts/pi/post-deploy.sh" \
  || die "post-deploy hala setup-morning-timer cagiriyor"
ok "morning timer kaldirildi"

grep -q 'ddgs_ok' "$cfg" || die "ddgs import-gate yok"
ok "ddgs import-gate"

[[ ! -f "$watchdog" ]] || die "watchdog.sh silinmeli (saatlik gozcu kalkti)"
! grep -qE 'pi-watchdog|pi-netalert-newdev|pi-netalert-offline|Sistem Gözcüsü|Ağ Gözcüsü' "$tmpl" \
  || die "cron template hala ag/saatlik gozcu job iceriyor"
ok "ag + saatlik hermes gozcu kaldirildi"

grep -q 'MAC: `' "$netalert" || die "netalert MAC backtick yok"
python3 "$netalert" --self-check || die "netalert self-check"
ok "netalert MAC + self-check"

[[ -f "$fx" ]] || die "fx-quote.sh yok"
chmod +x "$fx" "$archive" 2>/dev/null || true
grep -q 'TIMEOUT = 3' "$fx" || die "fx timeout 3s degil"
grep -q 'latest/USD' "$fx" || die "fx tek USD endpoint yok"
grep -q 'Pi Gateway · Bülten' "$fx" || die "fx bülten çerçevesi yok"
grep -q 'delta_s' "$fx" || die "fx dünkü fark yok"
! grep -q 'latest/EUR' "$fx" || die "fx hâlâ ayrı EUR isteği"
bash "$fx" --self-check || die "fx-quote self-check"
ok "fx-quote script"

grep -q 'pi-fx-quote.sh' "$scripts_setup" || die "wrapper pi-fx-quote yok"
ok "fx wrapper"

[[ -f "$archive" ]] || die "archive-bulletin.sh yok"
tmpd="$(mktemp -d)"
tmp="$(mktemp)"
tmp4="$(mktemp)"
trap 'rm -rf "$tmpd" "$tmp" "$tmp4"' EXIT
out="$(printf 'hello-archive\n' | BULLETIN_ARCHIVE_DIR="$tmpd" bash "$archive" fx)"
[[ "$out" == "hello-archive" ]] || die "archive stdout kaybetti: $out"
ls "$tmpd"/*-fx.md >/dev/null || die "archive dosya yazmadi"
ok "bülten arşiv"

python3 "$slo" --self-check || die "bulletin-slo self-check"
grep -q 'bulletin-slo.py' "$health" || die "health-check bulletin SLO yok"
grep -q 'bulletin-\*' "$health" || die "health-check bulletin soft-exit yok"
token_slo="$ROOT/scripts/lib/hermes-token-slo.py"
hygiene="$ROOT/scripts/lib/hermes-session-hygiene.py"
tpatch="$ROOT/scripts/lib/hermes-token-patch.py"
python3 "$token_slo" --self-check || die "hermes-token-slo self-check"
python3 "$hygiene" --self-check || die "hermes-session-hygiene self-check"
python3 "$tpatch" --self-check || die "hermes-token-patch self-check"
grep -q 'hermes-token-slo.py' "$health" || die "health-check token SLO yok"
grep -q 'hermes-session-hygiene.py' "$health" || die "health-check session hygiene yok"
grep -q 'hermes-session-\*' "$health" || die "health-check hermes-session soft-exit yok"
grep -q 'hermes-session-hygiene.py' "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  || die "privileged hygiene yok"
grep -q 'bulletin-slo.py' "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  || die "privileged bulletin-slo yok"
grep -q 'hermes-token-slo.py' "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  || die "privileged token-slo yok"
grep -q 'zai 1308 no retry' "$tpatch" || die "1308 patch marker yok"
grep -q 'should_fallback=False' "$tpatch" || die "1308 should_fallback False yok"
grep -q '_FALLBACK_TRUE' "$tpatch" || die "1308 v1→v2 upgrade yok"
grep -q 'TOKEN_PY' "$ROOT/scripts/pi/patch-hermes-cron-pi.sh" || die "cron patch 1308 cagirmiyor"
grep -q 'hermes-gateway restart (patch)' "$ROOT/scripts/pi/patch-hermes-cron-pi.sh" \
  || die "1308/gateway patch sonrasi restart yok"
grep -q '_run_hermes_py hermes-session-hygiene' "$health" || die "hygiene health-check yok"
grep -q 'WARN ${kind} fail' "$health" || die "hygiene/slo hata yutma duruyor"
grep -q '_run_hermes_py' "$health" || die "health-check python fail helper yok"
! grep -q 'hermes-session-hygiene.py".*2>/dev/null' "$health" || die "hygiene 2>/dev/null kaldi"
grep -q 'reap-dead-docker-scopes.sh' "$health" || die "health-check docker scope reap yok"
grep -q 'reap-dead-docker-scopes.sh' "$ROOT/scripts/pi/install-privileged-scripts.sh" \
  || die "privileged reap-dead-docker-scopes yok"
grep -q '_reap_netalert_binds' "$ROOT/scripts/pi/setup-netalertx.sh" \
  || die "setup-netalertx bind reap yok"
grep -q 'sudo", "cat"' "$ROOT/scripts/pi/setup-netalertx.sh" \
  || die "setup-netalertx app.conf sudo cat yok"
ok "bulletin SLO"

python3 "$merge" --self-check || die "hermes-cron-merge self-check"
ok "cron merge"

cat >"$tmp" <<'STUB'
    # pi-gateway: cron failure v3
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"
    if wrap_response:
        pass
    return (
        f"\nThis job has failed {streak} runs in a row — worth a review. "
        f"Fix its prompt/config, or pause it with `hermes cron pause {job_ref}` "
        "(resume/remove also available) to stop the noise."
    )
STUB
python3 "$patch" "$tmp" >/dev/null
grep -q 'cron failure v7' "$tmp" || die "v3->v7 patch uygulanmadi"
grep -q 'no_agent skip wrap' "$tmp" || die "wrap patch yok"
grep -q 'failure nudge tr' "$tmp" || die "nudge patch yok"
ok "v3->v7 patch"

cat >"$tmp4" <<'STUB4'
    # pi-gateway: cron failure v4
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"
    # pi-gateway: no_agent skip wrap
    if wrap_response and not job.get("no_agent"):
        pass
    # pi-gateway: failure nudge tr
    return (
        f"\n\n—\n"
        f"⚠️ Bu görev üst üste {streak} kez başarısız oldu. "
        f"Durdurmak için: hermes cron pause \"{job_ref}\""
    )
STUB4
python3 "$patch" "$tmp4" >/dev/null
grep -q 'cron failure v7' "$tmp4" || die "v4->v7 patch uygulanmadi"
! grep -q 'cron failure v4' "$tmp4" || die "v4 marker kaldi"
ok "v4->v7 patch"

tmp5="$(mktemp)"
trap 'rm -rf "$tmpd" "$tmp" "$tmp4" "$tmp5"' EXIT
cat >"$tmp5" <<'STUB5'
    # pi-gateway: cron failure v5
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"
    # pi-gateway: no_agent skip wrap
    if wrap_response and not job.get("no_agent"):
        pass
    # pi-gateway: failure nudge tr
    return "nudge"
STUB5
python3 "$patch" "$tmp5" >/dev/null
grep -q 'cron failure v7' "$tmp5" || die "v5->v7 patch uygulanmadi"
grep -q 'if not job.get("no_agent")' "$tmp5" || die "v7 no_agent kapısı yazilmadi"
! grep -q 'cron failure v5' "$tmp5" || die "v5 marker kaldi"
ok "v5->v7 patch"

tmp6="$(mktemp)"
trap 'rm -rf "$tmpd" "$tmp" "$tmp4" "$tmp5" "$tmp6"' EXIT
cat >"$tmp6" <<'STUB6'
    # pi-gateway: cron failure v6
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"
    # pi-gateway: no_agent skip wrap
    if wrap_response and not job.get("no_agent"):
        pass
    # pi-gateway: failure nudge tr
    return "nudge"
STUB6
python3 "$patch" "$tmp6" >/dev/null
grep -q 'cron failure v7' "$tmp6" || die "v6->v7 patch uygulanmadi"
! grep -q 'cron failure v6' "$tmp6" || die "v6 marker kaldi"
ok "v6->v7 patch"

tmpb="$(mktemp)"
trap 'rm -rf "$tmpd" "$tmp" "$tmp4" "$tmp5" "$tmp6" "$tmpb"' EXIT
cat >"$tmpb" <<'STUBB'
    # pi-gateway: cron failure v7
    return f"⚠️ Cron '{job_name}' failed: {cleaned}"
    # pi-gateway: no_agent skip wrap
    if wrap_response and not job.get("no_agent"):
        pass
    # pi-gateway: failure nudge tr
    return "nudge"
def _deliver_result(job: dict, content: str) -> None:
    wrap_response = False
    if wrap_response and not job.get("no_agent"):
        delivery_content = "x"
    else:
        delivery_content = content
    # Run the async send in a fresh event loop (safe from any thread)
    coro = _send_to_platform(platform, pconfig, chat_id, delivery_content, thread_id=thread_id)
STUBB
python3 "$patch" "$tmpb" >/dev/null
grep -q 'bulletin post helper' "$tmpb" || die "bulletin helper yazilmadi"
grep -q '_pi_gw_bulletin_prepare' "$tmpb" || die "bulletin prepare cagri yok"
ok "bulletin post patch"

echo "[test-hermes-bulletins] Tum kontroller gecti"
