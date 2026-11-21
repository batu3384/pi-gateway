#!/usr/bin/env bash
# Ultron editoryal monograf HTML -> A4 PDF üretici (WeasyPrint, offline-safe, Türkçe UTF-8).
set -euo pipefail

usage() {
  echo "Kullanım: $0 [--self-check] <input.html> <output.pdf> [başlık]" >&2
  exit 2
}

if [[ "${1:-}" == "--self-check" ]]; then
  python3 - <<'PY'
def build_doc(body_html: str, title: str) -> str:
    if "<html" in body_html.lower():
        return body_html
    return f"<!doctype html><html lang='tr'><head><meta charset='utf-8'><title>{title}</title></head><body>{body_html}</body></html>"

doc = build_doc("<h1>İstanbul</h1><p>Test</p>", "Örnek")
assert "<!doctype html>" in doc and "İstanbul" in doc
print("[render-ultron-pdf] self-check OK")
PY
  exit 0
fi

[[ $# -ge 2 ]] || usage
IN_HTML="$1"
OUT_PDF="$2"
DOC_TITLE="${3:-Ultron Monograf}"

[[ -f "$IN_HTML" ]] || { echo "[render-ultron-pdf] HATA: giriş dosyası yok: $IN_HTML" >&2; exit 1; }
mkdir -p "$(dirname "$OUT_PDF")"

IN_HTML="$IN_HTML" OUT_PDF="$OUT_PDF" DOC_TITLE="$DOC_TITLE" python3 - <<'PY'
import html
import os
import sys
from pathlib import Path

try:
    import weasyprint
except ImportError as exc:
    print(f"[render-ultron-pdf] HATA: weasyprint kurulu değil: {exc}", file=sys.stderr)
    sys.exit(1)

in_path = Path(os.environ["IN_HTML"]).resolve()
out_path = Path(os.environ["OUT_PDF"]).resolve()
title = os.environ.get("DOC_TITLE", "Ultron Monograf").strip() or "Ultron Monograf"
raw = in_path.read_text(encoding="utf-8")

EDITORIAL_CSS = f"""
@page {{
  size: A4;
  margin: 20mm 18mm 20mm 18mm;
  @top-left {{
    content: "{title.replace('"', "'")}";
    font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
    font-size: 8.5pt;
    color: #5c6470;
    letter-spacing: 0.04em;
  }}
  @bottom-right {{
    content: counter(page) " / " counter(pages);
    font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
    font-size: 8.5pt;
    color: #5c6470;
  }}
}}
@page :first {{
  @top-left {{ content: none; }}
}}
body {{
  font-family: "Liberation Serif", "DejaVu Serif", serif;
  font-size: 10.6pt;
  line-height: 1.56;
  color: #1c222b;
  margin: 0;
}}
h1, h2, h3, h4 {{
  font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
  color: #121826;
  break-after: avoid;
}}
h1 {{
  font-size: 21pt;
  line-height: 1.2;
  margin: 0 0 8pt 0;
  padding-bottom: 8pt;
  border-bottom: 2px solid #2b4c7e;
}}
h2 {{
  font-size: 13.5pt;
  margin: 18pt 0 6pt 0;
  color: #2b4c7e;
  border-left: 3.5px solid #2b4c7e;
  padding-left: 8pt;
}}
h3 {{
  font-size: 11pt;
  margin: 12pt 0 4pt 0;
}}
p {{ margin: 0 0 8pt 0; text-align: justify; }}
.subtitle {{
  font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
  font-size: 10pt;
  color: #4b5563;
  margin-bottom: 14pt;
}}
.callout, blockquote {{
  background: #f4f7fb;
  border-left: 3.5px solid #2b4c7e;
  padding: 9pt 12pt;
  margin: 10pt 0;
  border-radius: 3pt;
  break-inside: avoid;
}}
table {{
  width: 100%;
  border-collapse: collapse;
  margin: 10pt 0;
  font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
  font-size: 9pt;
  break-inside: avoid;
}}
th, td {{
  border: 1px solid #d5dce6;
  padding: 5pt 7pt;
  text-align: left;
  vertical-align: top;
}}
th {{
  background: #eef3f9;
  color: #121826;
  font-weight: 700;
}}
code, pre {{
  font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
  font-size: 8.8pt;
}}
pre {{
  background: #f6f8fa;
  padding: 8pt;
  border-radius: 3pt;
  white-space: pre-wrap;
  break-inside: avoid;
}}
svg, figure {{
  max-width: 100%;
  height: auto;
  display: block;
  margin: 10pt auto;
  break-inside: avoid;
}}
figcaption {{
  font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
  font-size: 8.5pt;
  color: #5c6470;
  text-align: center;
  margin-top: 4pt;
}}
"""

if "<html" in raw.lower():
    doc_html = raw
    extra_css = [] if "<style" in raw.lower() else [weasyprint.CSS(string=EDITORIAL_CSS)]
else:
    doc_html = (
        "<!doctype html>\n"
        "<html lang='tr'>\n<head>\n<meta charset='utf-8'>\n"
        f"<title>{html.escape(title)}</title>\n"
        f"<style>{EDITORIAL_CSS}</style>\n</head>\n<body>\n{raw}\n</body>\n</html>\n"
    )
    extra_css = []


def offline_url_fetcher(url: str, *args, **kwargs):
    if url.startswith(("http://", "https://")):
        raise ValueError(f"Harici URL engellendi (offline PDF): {url}")
    return weasyprint.default_url_fetcher(url, *args, **kwargs)


weasyprint.HTML(
    string=doc_html,
    base_url=str(in_path.parent),
    url_fetcher=offline_url_fetcher,
).write_pdf(str(out_path), stylesheets=extra_css)

size = out_path.stat().st_size if out_path.is_file() else 0
if size < 1024:
    print(f"[render-ultron-pdf] HATA: geçersiz PDF boyutu ({size} byte)", file=sys.stderr)
    sys.exit(1)
print(f"[render-ultron-pdf] OK {out_path} ({size} bytes)")
PY
