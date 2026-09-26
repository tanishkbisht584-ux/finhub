"""concalls.py: selection + the nightly loop with the PDF and the model faked.
Run: cd pipeline && py -3 -m pytest test_concalls.py"""
from datetime import datetime, timezone

import concalls as cc

NOW = datetime(2026, 9, 26, 19, 30, tzinfo=timezone.utc)


def test_call_date_formats():
    assert cc.call_date("17-Jul-2026 18:30") == "2026-07-17"
    assert cc.call_date("2026-07-17T10:00:00") == "2026-07-17"
    assert cc.call_date("17-07-2026") == "2026-07-17"
    assert cc.call_date("junk") is None and cc.call_date(None) is None


def test_pick_todo_transcripts_only_newest_per_symbol_cap_and_skip_done():
    docs = [
        {"symbol": "RELIANCE", "concalls": [
            {"date": "17-Apr-2026", "subject": "Transcript of Q4 earnings call", "url": "https://x/q4.pdf"},
            {"date": "17-Jul-2026", "subject": "Earnings Call Transcript Q1", "url": "https://x/q1.pdf"},
            {"date": "18-Jul-2026", "subject": "Investor presentation", "url": "https://x/ppt.pdf"},
            {"date": "19-Jul-2026", "subject": "Audio transcript", "url": "https://x/audio.mp3"}]},
        {"symbol": "TCS", "concalls": [{"date": "10-Jul-2026", "subject": "Transcript", "url": "https://x/t.pdf"}]},
        {"symbol": "INFY", "concalls": [{"date": "11-Jul-2026", "subject": "Transcript", "url": "https://x/i.pdf"}]},
    ]
    todo = cc.pick_todo(docs, {("TCS", "2026-07-10")}, cap=5)
    assert todo == [("RELIANCE", "2026-07-17", "Earnings Call Transcript Q1", "https://x/q1.pdf"),
                    ("INFY", "2026-07-11", "Transcript", "https://x/i.pdf")]
    assert cc.pick_todo(docs, set(), cap=1) == [("RELIANCE", "2026-07-17", "Earnings Call Transcript Q1", "https://x/q1.pdf")]


def test_refresh_summarises_records_no_text_and_writes_the_blob(monkeypatch):
    import ai
    import market
    calls = []

    def sb(method, path, **kw):
        calls.append((method, path.split("?")[0]))
        if path.startswith("screener_metrics"):
            return [{"symbol": "RELIANCE"}, {"symbol": "TCS"}]
        if path.startswith("fundamentals?select=symbol,period&kind=eq.concall"):
            return []
        if path.startswith("fundamentals?select=symbol,concalls"):
            return [{"symbol": "TCS", "concalls": [{"date": "10-Jul-2026", "subject": "Transcript", "url": "https://x/t.pdf"}]},
                    {"symbol": "RELIANCE", "concalls": [{"date": "17-Jul-2026", "subject": "Transcript", "url": "https://x/r.pdf"}]}]
        if path.startswith("fundamentals?select=symbol,period,summary"):
            return [{"symbol": "RELIANCE", "period": "2026-07-17", "summary": "Solid quarter.", "sentiment": "confident"}]
        return None

    class R:
        def __init__(self, url):
            self.url = url

        def raise_for_status(self):
            pass

        @property
        def raw(self):
            outer = self

            class Raw:
                def read(self, n):
                    return b"RELIANCE" if "r.pdf" in outer.url else b"TCS"
            return Raw()

    monkeypatch.setattr(cc.requests, "get", lambda url, **k: R(url))
    monkeypatch.setattr(cc, "pdf_text", lambda data: "x" * 5000 if data == b"RELIANCE" else "short")
    monkeypatch.setattr(ai, "summarise_transcript", lambda text: {"summary": "Solid quarter.", "guidance": [], "risks": [],
                                                                  "qa_highlights": [], "sentiment": "confident"})
    written, blobs = [], []
    monkeypatch.setattr(market, "upsert", lambda sb_, rows, table, key: written.extend(rows) or len(rows))
    monkeypatch.setattr(market, "write_blobs", lambda sb_, rows: blobs.extend(rows) or len(rows))
    assert cc.refresh(sb, NOW, cap=5) == 1
    by = {r["symbol"]: r for r in written}
    assert by["RELIANCE"]["kind"] == "concall" and by["RELIANCE"]["period"] == "2026-07-17"
    assert by["RELIANCE"]["data"]["summary"] == "Solid quarter." and by["RELIANCE"]["data"]["chars"] == 5000
    assert by["TCS"]["data"]["note"] == "no_text"                    # scanned: recorded, never retried
    assert blobs[0]["key"] == "concall_takeaways" and blobs[0]["payload"]["items"][0]["symbol"] == "RELIANCE"


def test_pdf_text_reads_a_real_pdf():
    from pypdf import PdfWriter
    import io
    w = PdfWriter()
    w.add_blank_page(width=200, height=200)
    buf = io.BytesIO()
    w.write(buf)
    assert cc.pdf_text(buf.getvalue()) == ""   # blank page → no text, no crash
