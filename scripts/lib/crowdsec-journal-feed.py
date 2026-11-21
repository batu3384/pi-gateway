#!/usr/bin/env python3
"""Stream host ssh/kernel journal entries to tmpfs syslog file for CrowdSec."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

LOG_PATH = Path(
    os.environ.get("CROWDSEC_JOURNAL_LOG", "/run/pi-gateway/crowdsec-logs/host-syslog.log")
)
MAX_BYTES = int(os.environ.get("CROWDSEC_JOURNAL_MAX_BYTES", str(2 * 1024 * 1024)))
TAIL_LINES = os.environ.get("CROWDSEC_JOURNAL_TAIL_LINES", "200")


def ensure_log_file(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o755)
    if not path.exists():
        fd = os.open(str(path), os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o644)
        os.close(fd)
    os.chmod(path, 0o644)


def rotate_if_needed(path: Path, fh, max_bytes: int):
    try:
        if fh.tell() < max_bytes:
            return fh
    except OSError:
        return fh
    fh.flush()
    fh.close()
    backup = path.with_name(path.name + ".1")
    try:
        os.replace(path, backup)
    except OSError:
        pass
    ensure_log_file(path)
    return path.open("a", encoding="utf-8", errors="replace")


def build_journalctl_cmd(tail_lines: str) -> list[str]:
    # journalctl'da -u ile -k birlikte AND (kesisim) yapar -> 0 satir!
    # '+' operatoru OR (birlesim) saglar: ssh.service VEYA sshd.service VEYA kernel (UFW).
    # '-o short' + LC_ALL=C: standart Ingilizce syslog zaman damgasi (CrowdSec parser uyumlu).
    return [
        "journalctl",
        "-f",
        "-n",
        str(tail_lines),
        "--no-pager",
        "-o",
        "short",
        "_SYSTEMD_UNIT=ssh.service",
        "+",
        "_SYSTEMD_UNIT=sshd.service",
        "+",
        "_TRANSPORT=kernel",
    ]


def self_check() -> int:
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "crowdsec-logs" / "host-syslog.log"
        ensure_log_file(p)
        assert p.exists() and (p.stat().st_mode & 0o777) == 0o644
        fh = p.open("a", encoding="utf-8")
        fh.write("Nov 21 12:00:00 pi sshd[1]: test line\n" * 5)
        fh.flush()
        fh = rotate_if_needed(p, fh, max_bytes=32)
        fh.write("Nov 21 12:00:01 pi sshd[1]: post-rotate\n")
        fh.flush()
        fh.close()
        assert (p.with_name(p.name + ".1")).exists()
        assert "post-rotate" in p.read_text(encoding="utf-8")
        cmd = build_journalctl_cmd("50")
        assert "_SYSTEMD_UNIT=ssh.service" in cmd and "+" in cmd and "_TRANSPORT=kernel" in cmd
    print("[crowdsec-journal-feed] self-check OK")
    return 0


def main() -> int:
    if "--self-check" in sys.argv[1:]:
        return self_check()

    stop = False
    proc: subprocess.Popen[str] | None = None

    def _handle_signal(_signum, _frame):
        nonlocal stop
        stop = True
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    ensure_log_file(LOG_PATH)
    cmd = build_journalctl_cmd(TAIL_LINES)
    first_run = True

    while not stop:
        run_cmd = cmd if first_run else build_journalctl_cmd("0")
        first_run = False
        try:
            env = dict(os.environ)
            env["LC_ALL"] = "C"
            proc = subprocess.Popen(
                run_cmd,
                stdout=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                env=env,
            )
        except OSError as exc:
            print(f"[crowdsec-journal-feed] journalctl baslatilamadi: {exc}", file=sys.stderr)
            time.sleep(5)
            continue

        assert proc.stdout is not None
        ensure_log_file(LOG_PATH)
        fh = LOG_PATH.open("a", encoding="utf-8", errors="replace")
        try:
            for line in proc.stdout:
                if stop:
                    break
                if not line.strip() or line.startswith("-- "):
                    continue
                fh.write(line)
                fh.flush()
                fh = rotate_if_needed(LOG_PATH, fh, MAX_BYTES)
        finally:
            try:
                fh.close()
            except OSError:
                pass
            if proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    try:
                        proc.kill()
                    except OSError:
                        pass
            proc = None

        if not stop:
            time.sleep(2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
