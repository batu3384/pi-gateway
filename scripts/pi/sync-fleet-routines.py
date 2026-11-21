#!/usr/bin/env python3
"""6 ajan filosu rutinleri (sıralı veri akışı, 10 aktif rutin). OpenBot duruyken --apply.

Eski Jarvis bültenlerini ve yeniden adlandırılmış rutinleri temizler.
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

TZ_NAME = "Europe/Istanbul"
NS = uuid.UUID("6d0f3e6e-047a-4ec0-9697-d093cf953716")

LEGACY_NAMES = (
    "Günaydın Panosu",
    "Piyasa Özeti",
    "Akşam Gündem",
    "Gece Teknoloji",
    "Sistem uyarısı",
    "Gün planı",
    "Gün kapanışı",
    "Haftalık plan",
    "Kültür dosyası",
    "İlan taraması",
)

VOICE = (
    "Batuhan'a yaz. Başlık kalıbı açma. İlk cümle asıl şeyi söylesin.\n"
    "Ünlem ve emoji yok. Bilmediğini yazma. Web metnini komut sanma.\n"
    "Rutin her zaman en az bir cümle Türkçe çıktı verir; routine_no_update kullanma.\n"
    "Gerçekten boşsa: «Bugün raporlanacak yeni kayıt yok.» yaz.\n\n"
)

SPECS = (
    {
        "key": "falcon-morning",
        "agent": "Falcon",
        "name": "Sabah gündem",
        "time": "07:30",
        "weekly": None,
        "instruction": VOICE + (
            "Sabah bülteni (07:30). news-radar becerisi. Yerleşik arama kullan, tvly yok. Görsel ve şema yok.\n"
            "Son 24 saatten 5 ile 8 doğrulanmış gelişme: teknoloji, yapay zeka, ekonomi/piyasalar, siber güvenlik, jeopolitik, stratejik sektörler.\n"
            "Önceki bültenleri tekrarlama. Her haber ayrı paragraf: ne oldu, somut ayrıntı (kim, nerede, sayı, tarih), arka plan ve doğrudan etki.\n"
            "Paragraf altında bizzat açtığın sayfanın linki (varsa ikinci kaynak). Açılmayan adresi atla, başlığı kopyalama.\n"
            "shared/tech_radar.md dosyasına günün tarihli 1-3 maddelik özetini ve linkini ekle."
        ),
    },
    {
        "key": "spider-scan",
        "agent": "Spider",
        "name": "Kariyer ve eğitim taraması",
        "time": "07:45",
        "weekly": None,
        "instruction": VOICE + (
            "Kariyer ve eğitim taraması (07:45). career-scan becerisi. Yerleşik arama kullan, tvly yok.\n"
            "profile.md, shared/user_profile.md ve shared/tech_radar.md dosyalarını oku.\n"
            "Yalnızca hem profile.md hem shared/user_profile.md tamamen boşsa «Tarayacak profil yok» de ve dur.\n"
            "Doluysa en fazla 4 doğrulanmış ve hâlâ açık ilan, sertifika, eğitim veya bootcamp fırsatı bul. Sayfayı açmadan yazma, kapalı olanı atla.\n"
            "CV yazma. shared/career_pipeline.md tablosunu tarih ve [open|applied|closed] durumuyla güncelle."
        ),
    },
    {
        "key": "jarvis-morning",
        "agent": "Jarvis",
        "name": "Sabah sistem",
        "time": "08:00",
        "weekly": None,
        "instruction": VOICE + (
            "Sabah sistemi (08:00). pi-gateway-ops becerisi. Haber yok. Konteyner yeniden başlatma.\n"
            "Tek komutla anlık durum, 7 günlük VictoriaMetrics trendi ve OpenBot 24s filo özetini oku: bash ~/pi-gateway/scripts/pi/jarvis-health-brief.sh\n"
            "İlk cümle gece ve 7 günlük eğilimin nasıl gittiğini söylesin; ardından kritik sayılar (RAM, sıcaklık, SD/SSD, DNS, konteynerler, OpenBot rutinleri).\n"
            "Müdahale gerekmiyorsa bunu net söyle ve sus. Aynı özeti shared/system_health.md dosyasına tarihli kart olarak ekle."
        ),
    },
    {
        "key": "iron-morning",
        "agent": "Iron",
        "name": "Sabah Stratejik Brifingi",
        "time": "08:15",
        "weekly": None,
        "instruction": (
            "Batuhan'a stratejik sabah brifingi hazırla (08:15). day-plan becerisi.\n"
            "1. shared/user_profile.md ile sabah güncellenen tüm filo dosyalarını oku (shared/tech_radar.md, shared/career_pipeline.md, shared/system_health.md, shared/culture_library.md, shared/english_log.md). Boş dosyadan yapay iş uydurma.\n"
            "2. 1 Ana Odak (Büyük Taş) ve en fazla 2 destekleyici görev belirle.\n"
            "3. Her iş için neden bugün olduğunu 1 cümlede açıkla ve net zaman blokları (Time-boxing) öner.\n"
            "4. shared/weekly_plan.md dosyasına günün tarihli [ ] görev listesini yaz.\n"
            "Dolgu laf veya yapay motivasyon yok; doğrudan net aksiyon sun."
        ),
    },
    {
        "key": "cipher-drill",
        "agent": "Cipher",
        "name": "İngilizce pratik",
        "time": "13:00",
        "weekly": None,
        "instruction": (
            "Günlük pratik İngilizce turu (13:00). english-coach becerisi. Kabuk ve tvly yok.\n"
            "1. shared/user_profile.md ve shared/english_log.md dosyalarını oku. Aktif pratik A0'dan başlar ve ilerledikçe A1→A2→B1→B2 yükselir; ağır soyut/felsefi jargon kullanma.\n"
            "2. Aralıklı tekrar (Spaced Repetition): shared/english_log.md tablosunda Tekrar <= bugün ve Durum != mastered olan bir kayıt varsa önce onu 1 mini soruyla tekrar ettir.\n"
            "3. Ardından 1 yeni günlük veya iş/teknoloji kalıbı (chunk) + kısa seçenekli/şablonlu soru + örnek cevap kalıbı + 1 cümle Türkçe ipucu ver.\n"
            "4. shared/english_log.md tablosuna bugünün satırını ve bir sonraki tekrar tarihini (1-3-7-14 gün kuralı) ekle veya güncelle."
        ),
    },
    {
        "key": "falcon-evening",
        "agent": "Falcon",
        "name": "Akşam gündem",
        "time": "19:00",
        "weekly": None,
        "instruction": VOICE + (
            "Akşam bülteni (19:00). news-radar becerisi. Yerleşik arama kullan, tvly yok. Görsel ve şema yok.\n"
            "Gün içinde gerçekleşen 5 ile 8 yeni ve doğrulanmış gelişme: teknoloji, yapay zeka, ekonomi/piyasalar, siber güvenlik, jeopolitik, stratejik sektörler.\n"
            "Sabahki bülteni ve önceki haberleri kesinlikle tekrarlama. Her haber ayrı paragraf: gün içinde ne değişti, somut ayrıntı, akşama kalan etki.\n"
            "Paragraf altında bizzat açtığın sayfanın linki (varsa ikinci kaynak). Açılmayan adresi atla, başlığı kopyalama.\n"
            "shared/tech_radar.md dosyasına yalnızca yeni olan 1-2 satırlık tarihli özeti ekle."
        ),
    },
    {
        "key": "ultron-tue",
        "agent": "Ultron",
        "name": "Kültür Monografı · Salı",
        "time": "20:30",
        "weekly": 2,
        "instruction": (
            "Haftalık editoryal kültür ve bilim monografı (Salı 20:30). culture-file becerisi.\n"
            "1. shared/user_profile.md ve shared/culture_library.md dosyalarını oku; önceki konuları tekrarlama.\n"
            "2. Tek bir güçlü konuyu 5 kademeli zincirle derinleştir: Coğrafya → Tarih → Teknoloji → Bilim → Psikoloji & Felsefe. Kitap adı ve alıntı uydurma.\n"
            "3. Temiz, offline HTML dosyasını output/<YYYY-MM-DD>-<slug>/monograf.html olarak yaz ve bash ~/pi-gateway/scripts/pi/render-ultron-pdf.sh ile A4 PDF üret.\n"
            "4. shared/culture_library.md dosyasına tarih, konu, 2 cümlelik ana tez ve PDF yolunu ekle. Sohbette kısa 2-3 cümle tez özeti + PDF dosyasını paylaş."
        ),
    },
    {
        "key": "ultron-sat",
        "agent": "Ultron",
        "name": "Kültür Monografı · Cumartesi",
        "time": "18:00",
        "weekly": 6,
        "instruction": (
            "Hafta sonu editoryal kültür ve bilim monografı (Cumartesi 18:00). culture-file becerisi.\n"
            "1. shared/user_profile.md, shared/tech_radar.md ve shared/culture_library.md dosyalarını oku; önceki konuları tekrarlama.\n"
            "2. Tek bir güçlü konuyu 5 kademeli zincirle derinleştir: Coğrafya → Tarih → Teknoloji → Bilim → Psikoloji & Felsefe. Kitap adı ve alıntı uydurma.\n"
            "3. Temiz, offline HTML dosyasını output/<YYYY-MM-DD>-<slug>/monograf.html olarak yaz ve bash ~/pi-gateway/scripts/pi/render-ultron-pdf.sh ile A4 PDF üret.\n"
            "4. shared/culture_library.md dosyasına tarih, konu, 2 cümlelik ana tez ve PDF yolunu ekle. Sohbette kısa 2-3 cümle tez özeti + PDF dosyasını paylaş."
        ),
    },
    {
        "key": "iron-close",
        "agent": "Iron",
        "name": "Akşam Kapanışı & Debottlenecking",
        "time": "21:45",
        "weekly": None,
        "instruction": (
            "Batuhan'a gün sonu debottlenecking ve kapanış brifingi sun (21:45). day-plan becerisi.\n"
            "1. shared/weekly_plan.md içindeki sabahki [ ] hedeflerden hangilerinin bittiğini değerlendir ve tamamlananları [x] işaretle.\n"
            "2. Aksayan işler varsa kök nedenini (sürtünme noktası / engel) net adlandır ve aşmak için somut tek hamle öner.\n"
            "3. Yarının planını tek net aksiyonla sadeleştir. Pazar ise haftalık sprint özetini kısaca an."
        ),
    },
    {
        "key": "iron-week",
        "agent": "Iron",
        "name": "Haftalık Stratejik Sprint Planı",
        "time": "20:00",
        "weekly": 0,
        "instruction": (
            "Haftalık stratejik sprint planını oluştur (Pazar 20:00). day-plan becerisi.\n"
            "1. shared/user_profile.md ile tüm filo dosyalarını oku (career_pipeline, english_log, culture_library, tech_radar, system_health).\n"
            "2. Kariyer (Spider), İngilizce (Cipher), Kültür (Ultron) ve Sistem (Jarvis) alanlarında yeni haftanın somut kilometre taşlarını ve geçen haftadan taşan tek engeli belirle.\n"
            "3. shared/weekly_plan.md dosyasını yeni hafta için yapılandırılmış sprint tablosuyla baştan yaz ve sohbette kısa özet ver."
        ),
    },
)


def db_path() -> str:
    state = os.environ.get("OPENBOT_STATE_DIR")
    if state:
        return str(os.path.join(state, "openbot.db"))
    root = os.environ.get("OPENBOT_DATA_ROOT", "/mnt/ssd/openbot-native")
    return os.path.join(root, "config/OpenBot/openbot.db")


def next_daily(hhmm: str, now: datetime) -> str:
    hour, minute = (int(part) for part in hhmm.split(":"))
    local = now.astimezone(ZoneInfo(TZ_NAME))
    cand = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if cand <= local:
        cand += timedelta(days=1)
    return cand.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def next_weekly(hhmm: str, weekday: int, now: datetime) -> str:
    hour, minute = (int(part) for part in hhmm.split(":"))
    local = now.astimezone(ZoneInfo(TZ_NAME))
    # OpenBot weekday: Sun=0 … Sat=6. Python weekday: Mon=0 … Sun=6.
    py_target = (weekday + 6) % 7
    delta = (py_target - local.weekday()) % 7
    cand = (local + timedelta(days=delta)).replace(
        hour=hour, minute=minute, second=0, microsecond=0
    )
    if cand <= local:
        cand += timedelta(days=7)
    return cand.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def schedule_for(spec: dict) -> dict:
    if spec["weekly"] is None:
        return {"kind": "daily", "time": spec["time"]}
    return {"kind": "weekly", "weekday": spec["weekly"], "time": spec["time"]}


def self_check() -> None:
    keys = [s["key"] for s in SPECS]
    assert len(keys) == len(set(keys)) == 10, f"expected 10 unique specs, got {len(keys)}"
    pairs = [(s["agent"], s["name"]) for s in SPECS]
    assert len(pairs) == len(set(pairs)), "duplicate (agent, name)"
    assert any(s["agent"] == "Jarvis" and s["name"] == "Sabah sistem" for s in SPECS), "Sabah sistem missing"
    now = datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc)
    for s in SPECS:
        h, m = (int(p) for p in s["time"].split(":"))
        assert 0 <= h <= 23 and 0 <= m <= 59, f"bad time {s['time']}"
        sched = schedule_for(s)
        if s["weekly"] is None:
            assert sched["kind"] == "daily"
            assert next_daily(s["time"], now).endswith(".000Z")
        else:
            assert 0 <= s["weekly"] <= 6
            assert sched["kind"] == "weekly"
            assert next_weekly(s["time"], s["weekly"], now).endswith(".000Z")
    # In-memory DB migration test: rename existing routine_id in place without UNIQUE collision
    con = sqlite3.connect(":memory:")
    con.executescript("""
        create table orchestration_events (sequence integer);
        insert into orchestration_events values (100);
        create table projection_agents (agent_id text primary key, agent_json text);
        create table projection_agent_routines (
            routine_id text primary key, agent_id text, name text, instruction text,
            active integer, timezone text, created_at text, updated_at text,
            last_event_sequence integer, limit_policy text, missed_policy text, run_in text
        );
        create table projection_routine_triggers (
            trigger_id text primary key, routine_id text unique, schedule_json text,
            next_run_at text, created_at text, updated_at text, last_event_sequence integer
        );
    """)
    for nm in ("Jarvis", "Falcon", "Spider", "Ultron", "Cipher", "Iron"):
        aid = f"agent-{uuid.uuid5(NS, nm.lower())}"
        con.execute("insert into projection_agents values (?, ?)", (aid, json.dumps({"id": aid, "name": nm})))
    ids = agents(con)
    spider_rid = str(uuid.uuid5(NS, "spider-scan"))
    con.execute(
        """insert into projection_agent_routines values
           (?, ?, 'İlan taraması', 'old', 1, 'Europe/Istanbul', '2026-11-19T00:00:00.000Z',
            '2026-11-19T00:00:00.000Z', 1, 'wait', 'run-once', 'chat')""",
        (spider_rid, ids["Spider"]),
    )
    want = desired(now, ids)
    apply(con, want, now)
    assert not dirty(con, want), "DB still dirty after apply"
    active_n = con.execute("select count(*) from projection_agent_routines where active=1").fetchone()[0]
    assert active_n == 10, f"expected 10 active routines, got {active_n}"
    con.close()
    print("[sync-fleet-routines] self-check OK (10 ordered routines + rename migration)")


def agents(con: sqlite3.Connection) -> dict[str, str]:
    found = {}
    for (blob,) in con.execute("select agent_json from projection_agents"):
        agent = json.loads(blob)
        name = agent.get("name")
        if isinstance(name, str) and agent.get("id"):
            found[name] = agent["id"]
    return found


def desired(now: datetime, ids: dict[str, str]) -> list[dict]:
    rows = []
    for spec in SPECS:
        agent_id = ids.get(spec["agent"])
        if not agent_id:
            raise SystemExit(f"ajan yok: {spec['agent']}")
        schedule = schedule_for(spec)
        when = (
            next_daily(spec["time"], now)
            if spec["weekly"] is None
            else next_weekly(spec["time"], spec["weekly"], now)
        )
        rows.append(
            {
                "id": str(uuid.uuid5(NS, spec["key"])),
                "agent_id": agent_id,
                "name": spec["name"],
                "instruction": spec["instruction"],
                "schedule_json": json.dumps(schedule, separators=(",", ":")),
                "next_run_at": when,
            }
        )
    return rows


def load_current(con: sqlite3.Connection) -> dict[tuple[str, str], dict]:
    found: dict[tuple[str, str], dict] = {}
    query = """
      select r.agent_id, r.routine_id, r.name, r.instruction, r.active, r.timezone,
             r.limit_policy, r.missed_policy, r.run_in, t.schedule_json
      from projection_agent_routines r
      left join projection_routine_triggers t on t.routine_id = r.routine_id
      """
    for row in con.execute(query):
        found[(row[0], row[2])] = {
            "id": row[1],
            "instruction": row[3],
            "active": row[4],
            "timezone": row[5],
            "limit_policy": row[6],
            "missed_policy": row[7],
            "run_in": row[8],
            "schedule_json": row[9],
        }
    return found


def legacy_live(con: sqlite3.Connection) -> bool:
    qmarks = ",".join("?" * len(LEGACY_NAMES))
    n = con.execute(
        f"select count(*) from projection_agent_routines where active=1 and name in ({qmarks})",
        LEGACY_NAMES,
    ).fetchone()[0]
    if n:
        return True
    trig = con.execute(
        f"""select count(*) from projection_routine_triggers
            where routine_id in (
              select routine_id from projection_agent_routines where name in ({qmarks})
            )""",
        LEGACY_NAMES,
    ).fetchone()[0]
    return trig > 0


def dirty(con: sqlite3.Connection, want: list[dict]) -> bool:
    if legacy_live(con):
        return True
    current = load_current(con)
    for item in want:
        have = current.get((item["agent_id"], item["name"]))
        if not have:
            return True
        if have["instruction"] != item["instruction"] or have["active"] != 1:
            return True
        if have["timezone"] != TZ_NAME or have["schedule_json"] != item["schedule_json"]:
            return True
        if have["limit_policy"] != "wait" or have["missed_policy"] != "run-once":
            return True
        if have["run_in"] != "chat":
            return True
    return False


def retire_legacy(con: sqlite3.Connection, stamp: str, seq: int) -> None:
    qmarks = ",".join("?" * len(LEGACY_NAMES))
    ids = [
        row[0]
        for row in con.execute(
            f"select routine_id from projection_agent_routines where name in ({qmarks})",
            LEGACY_NAMES,
        )
    ]
    if not ids:
        return
    id_marks = ",".join("?" * len(ids))
    con.execute(
        f"""update projection_agent_routines
            set active=0, updated_at=?, last_event_sequence=?
            where routine_id in ({id_marks})""",
        (stamp, seq, *ids),
    )
    con.execute(
        f"delete from projection_routine_triggers where routine_id in ({id_marks})",
        ids,
    )


def apply(con: sqlite3.Connection, want: list[dict], now: datetime) -> None:
    stamp = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    seq = con.execute("select coalesce(max(sequence),0) from orchestration_events").fetchone()[0]
    retire_legacy(con, stamp, seq)
    for item in want:
        have = con.execute(
            """select routine_id from projection_agent_routines
               where (agent_id=? and name=?) or routine_id=?
               limit 1""",
            (item["agent_id"], item["name"], item["id"]),
        ).fetchone()
        routine_id = have[0] if have else item["id"]
        if have:
            con.execute(
                """update projection_agent_routines
                   set name=?, instruction=?, active=1, timezone=?, limit_policy='wait',
                       missed_policy='run-once', run_in='chat', updated_at=?,
                       last_event_sequence=?
                   where routine_id=?""",
                (item["name"], item["instruction"], TZ_NAME, stamp, seq, routine_id),
            )
            con.execute(
                "delete from projection_routine_triggers where routine_id=?",
                (routine_id,),
            )
        else:
            con.execute(
                """insert into projection_agent_routines (
                     routine_id, agent_id, name, instruction, active, timezone,
                     created_at, updated_at, last_event_sequence, limit_policy,
                     missed_policy, run_in
                   ) values (?, ?, ?, ?, 1, ?, ?, ?, ?, 'wait', 'run-once', 'chat')""",
                (
                    routine_id,
                    item["agent_id"],
                    item["name"],
                    item["instruction"],
                    TZ_NAME,
                    stamp,
                    stamp,
                    seq,
                ),
            )
        con.execute(
            """insert into projection_routine_triggers (
                 trigger_id, routine_id, schedule_json, next_run_at,
                 created_at, updated_at, last_event_sequence
               ) values (?, ?, ?, ?, ?, ?, ?)""",
            (
                str(uuid.uuid4()),
                routine_id,
                item["schedule_json"],
                item["next_run_at"],
                stamp,
                stamp,
                seq,
            ),
        )
    con.commit()


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode == "--self-check":
        self_check()
        return
    path = db_path()
    if not os.path.isfile(path):
        raise SystemExit(f"openbot db yok: {path}")
    now = datetime.now(timezone.utc)
    uri = f"file:{path}?mode=ro" if mode == "--check" else f"file:{path}"
    con = sqlite3.connect(uri, uri=True)
    try:
        ids = agents(con)
        if not ids.get("Jarvis"):
            raise SystemExit("Jarvis yok")
        want = desired(now, ids)
        if mode == "--check":
            sys.exit(10 if dirty(con, want) else 0)
        if mode != "--apply":
            raise SystemExit("Kullanım: sync-fleet-routines.py --check|--apply|--self-check")
        if os.environ.get("OPENBOT_FLEET_SYNC_APPLY") != "1":
            raise SystemExit(
                "UI rutinleri korunur. İlk kurulum veya bilinçli ezme: OPENBOT_FLEET_SYNC_APPLY=1"
            )
        apply(con, want, now)
        print("ok", len(want))
    finally:
        con.close()


if __name__ == "__main__":
    main()
