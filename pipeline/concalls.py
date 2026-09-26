"""Concall summaries (free-parity P5, 26 Sep 2026): the transcript PDFs NSE
already lists in each symbol's docs row (fundamentals kind=docs →
data.concalls), read with pypdf and reduced by ai.summarise_transcript to
one card per call: summary, guidance, risks, Q&A highlights, sentiment.
Nightly at 01:00 IST for the top CONCALL_UNIVERSE names by market cap, at
most CONCALL_DAILY_CAP calls (each is one Gemini call under the hourly pace
gate). A transcript with no extractable text (scanned) is recorded once as
no_text so it is never retried.

Run the checks: cd pipeline && py -3 -m pytest test_concalls.py
"""
import io
import re
from datetime import datetime

import requests

CONCALL_DAILY_CAP = 40      # knob
CONCALL_UNIVERSE = 500      # top by mcap
MAX_PDF = 8 * 1024 * 1024
MIN_CHARS = 2000            # under this it's a scanned PDF or a cover note
TRANSCRIPT = re.compile(r"transcript", re.I)


def call_date(s):
    """'17-Jul-2026 18:30' / '2026-07-17' / '17-07-2026' -> 'YYYY-MM-DD' or None."""
    head = (s or "").strip()
    for cand in (head[:11].strip(), head[:10]):
        for fmt in ("%Y-%m-%d", "%d-%b-%Y", "%d-%m-%Y"):
            try:
                return datetime.strptime(cand, fmt).date().isoformat()
            except ValueError:
                continue
    return None


def pick_todo(docs_rows, have, cap=CONCALL_DAILY_CAP):
    """docs rows (mcap-desc) [{symbol, concalls:[{date, subject, url}]}] ->
    [(symbol, date, subject, url)] transcripts not yet summarised, newest
    per symbol first, one per symbol per night, at most `cap`."""
    out = []
    for r in docs_rows:
        calls = sorted((c for c in (r.get("concalls") or []) if TRANSCRIPT.search(c.get("subject") or "")
                        and str(c.get("url") or "").lower().endswith(".pdf") and call_date(c.get("date"))),
                       key=lambda c: call_date(c["date"]), reverse=True)
        for c in calls:
            d = call_date(c["date"])
            if (r["symbol"], d) in have:
                continue
            out.append((r["symbol"], d, c.get("subject") or "", c["url"]))
            break
        if len(out) >= cap:
            break
    return out


def pdf_text(data):
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    parts = []
    for page in reader.pages[:60]:
        try:
            parts.append(page.extract_text() or "")
        except Exception:  # noqa: BLE001 — a broken page, not a broken document
            continue
    return re.sub(r"[ \t]+", " ", "\n".join(parts)).strip()


def refresh(sb, now, cap=None):
    """Nightly: summarise up to `cap` new transcripts, then refresh the
    concall_takeaways blob (latest 10 across the market)."""
    import ai
    from market import IST, upsert, write_blobs
    cap = cap or CONCALL_DAILY_CAP
    top = [r["symbol"] for r in sb("GET", "screener_metrics?select=symbol&board=eq.MAIN&mcap_cr=not.is.null"
                                        f"&order=mcap_cr.desc&limit={CONCALL_UNIVERSE}")]
    have = {(r["symbol"], r["period"]) for r in sb("GET", "fundamentals?select=symbol,period&kind=eq.concall")}
    docs = []
    for i in range(0, len(top), 100):
        vals = ",".join(f'"{s}"' for s in top[i:i + 100])
        docs += sb("GET", f"fundamentals?select=symbol,concalls:data->concalls&kind=eq.docs&symbol=in.({vals})")
    order = {s: i for i, s in enumerate(top)}
    docs.sort(key=lambda r: order.get(r["symbol"], 1e9))
    todo = pick_todo(docs, have, cap)
    rows, done = [], 0
    for sym, d, subject, url in todo:
        try:
            r = requests.get(url, timeout=60, headers={"User-Agent": "Mozilla/5.0 FinFlick/1.0"}, stream=True)
            r.raise_for_status()
            data = r.raw.read(MAX_PDF + 1)
            if len(data) > MAX_PDF:
                raise ValueError("pdf too large")
            text = pdf_text(data)
            if len(text) < MIN_CHARS:
                rows.append({"symbol": sym, "kind": "concall", "period": d,
                             "data": {"subject": subject, "url": url, "note": "no_text"}})
                continue
            card = ai.summarise_transcript(text)
            rows.append({"symbol": sym, "kind": "concall", "period": d,
                         "data": {"subject": subject, "url": url, **card, "chars": len(text),
                                  "at": now.isoformat()}})
            done += 1
        except ai.QuotaExhausted as e:
            print(f"CONCALL {sym}: {e}; rest tomorrow")
            break
        except Exception as e:  # noqa: BLE001
            print(f"CONCALL {sym} {d}: {e}")
    if rows:
        upsert(sb, rows, table="fundamentals", key="symbol,kind,period")
    latest = sb("GET", "fundamentals?select=symbol,period,summary:data->>summary,sentiment:data->>sentiment"
                       "&kind=eq.concall&data->>note=is.null&order=period.desc&limit=10")
    if latest:
        write_blobs(sb, [{"key": "concall_takeaways",
                          "payload": {"asof": now.astimezone(IST).date().isoformat(),
                                      "items": [{"symbol": r["symbol"], "date": r["period"],
                                                 "line": (r.get("summary") or "")[:160],
                                                 "sentiment": r.get("sentiment")} for r in latest]},
                          "updated_at": now.isoformat()}])
    print(f"CONCALL: {done} summarised, {len(todo)} tried")
    return done
