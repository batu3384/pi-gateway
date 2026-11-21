---
name: culture-file
description: "5 kademeli disiplinler arası kültür/bilim monografı hazırlayıp WeasyPrint ile A4 PDF üretir. Ultron rutinlerinde kullan."
---

# Editoryal Monograf ve PDF (Ultron)

Tek bir konuyu 5 kademeli disiplinler arası zincirle işle: **Coğrafya → Tarih → Teknoloji → Bilim → Psikoloji & Felsefe**. Jenerik klişe, kitap adı veya alıntı uydurma; doğrulanmayan bilgiye «doğrulanmadı» yaz. Haber bülteni yazma.

1. Temiz, offline (harici URL/CDN font olmadan, gerekirse inline SVG diyagramlı) HTML içeriğini `output/<YYYY-MM-DD>-<slug>/monograf.html` olarak kaydet.
2. A4 editoryal PDF üret:
```bash
bash __REMOTE_DIR__/scripts/pi/render-ultron-pdf.sh output/<YYYY-MM-DD>-<slug>/monograf.html output/<YYYY-MM-DD>-<slug>/monograf.pdf "<Monograf Başlığı>"
```
3. `shared/culture_library.md` dosyasına tarih, konu, 2 cümlelik ana tez ve üretilen PDF yolunu ekle.
4. Sohbette uzun makale basma: 2–3 cümle keskin tez özeti + PDF dosyasını ilet.
