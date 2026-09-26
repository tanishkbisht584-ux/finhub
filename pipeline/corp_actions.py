"""Corporate actions (free-parity P2, 26 Sep 2026): NSE's two feeds that answer
from a runner (probe 36246785128) — `corporates-corporateActions` (ex-date /
record date / subject per symbol) and `event-calendar` (board meetings with a
purpose) — shaped into the `corp_actions` blob (Markets › CORPORATE ACTIONS)
and per-symbol lists for screener_metrics.actions (stock page › ACTIONS, which
until now knew only Yahoo dividends and splits). Pure; the fetch lives in
market.refresh_nse_blobs.

Run the checks: cd pipeline && py -3 -m pytest test_corp_actions.py
"""
import re
from datetime import timedelta

KINDS = (
    (re.compile(r"bonus", re.I), "bonus"),
    (re.compile(r"split|sub-?division", re.I), "split"),
    (re.compile(r"rights", re.I), "rights"),
    (re.compile(r"buy\s*-?\s*back", re.I), "buyback"),
    (re.compile(r"dividend", re.I), "dividend"),
    (re.compile(r"annual general meeting|\bagm\b", re.I), "agm"),
    (re.compile(r"extra\s*-?\s*ordinary general meeting|\begm\b", re.I), "egm"),
)
RATIO = re.compile(r"(\d+)\s*:\s*(\d+)")
AMOUNT = re.compile(r"(?:rs\.?|re\.?|₹|inr)\s*([\d.]+)", re.I)
SPLIT = re.compile(r"(?:rs\.?|re\.?|₹)\s*([\d.]+)[^\d]*?\bto\b[^\d]*?([\d.]+)", re.I)  # 'From Rs 10/- Per Share To Rs 2/-'
WINDOW_BACK, WINDOW_AHEAD = 7, 45


def normalise(subject):
    """'Dividend - Re 1 Per Share' -> ('dividend', '₹1'); 'Bonus 1:1' ->
    ('bonus', '1:1'); 'Face Value Split (Sub-Division) - From Rs 10/- Per
    Share To Rs 2/- Per Share' -> ('split', '₹10 → ₹2'); unknown -> ('other', None)."""
    text = subject or ""
    kind = next((k for rx, k in KINDS if rx.search(text)), "other")
    detail = None
    if kind == "split":
        m = SPLIT.search(text)
        detail = f"₹{_n(m.group(1))} → ₹{_n(m.group(2))}" if m else None
    elif kind in ("bonus", "rights"):
        m = RATIO.search(text)
        detail = f"{m.group(1)}:{m.group(2)}" if m else None
        if kind == "rights" and detail is None:
            m = AMOUNT.search(text)
            detail = f"₹{_n(m.group(1))}" if m else None
    elif kind in ("dividend", "buyback"):
        m = AMOUNT.search(text)
        detail = f"₹{_n(m.group(1))}" if m else None
    return kind, detail


def _n(s):
    try:
        f = float(s)
        return str(int(f)) if f == int(f) else str(f)
    except ValueError:
        return s


def shape_actions(ca_rows, meetings, known, now, parse_date):
    """-> {asof, items:[{symbol, name, kind, detail, ex, rec}], meetings:[{symbol,
    name, date, purpose}]}. Items keep a window of -7…+45 days around today,
    ex-date ascending; meetings today onward, deduped on (symbol, date)."""
    today = now.date() if hasattr(now, "date") else now
    lo, hi = today - timedelta(days=WINDOW_BACK), today + timedelta(days=WINDOW_AHEAD)
    items, seen = [], set()
    for r in ca_rows or []:
        sym = r.get("symbol")
        ex = parse_date(r.get("exDate"))
        if sym not in known or ex is None or not (lo <= ex <= hi):
            continue
        kind, detail = normalise(r.get("subject"))
        key = (sym, ex.isoformat(), kind, detail)
        if key in seen:
            continue
        seen.add(key)
        rec = parse_date(r.get("recDate"))
        items.append({"symbol": sym, "name": r.get("comp"), "kind": kind, "detail": detail,
                      "subject": (r.get("subject") or "")[:120],
                      "ex": ex.isoformat(), "rec": rec.isoformat() if rec else None})
    items.sort(key=lambda x: (x["ex"], x["symbol"]))
    meets, seen = [], set()
    for r in meetings or []:
        sym = r.get("symbol") or r.get("bm_symbol")
        d = parse_date(r.get("date") or r.get("bm_date"))
        if sym not in known or d is None or d < today or (sym, d) in seen:
            continue
        seen.add((sym, d))
        meets.append({"symbol": sym, "name": r.get("company") or r.get("sm_name"),
                      "date": d.isoformat(), "purpose": (r.get("purpose") or r.get("bm_purpose") or "")[:80]})
    meets.sort(key=lambda x: (x["date"], x["symbol"]))
    return {"asof": today.isoformat(), "items": items, "meetings": meets}


def per_symbol_rows(blob):
    """screener_metrics rows {symbol, actions:[…]} — the same events grouped
    per symbol, board meetings included as kind 'board_meeting'."""
    by = {}
    for it in blob.get("items") or []:
        by.setdefault(it["symbol"], []).append({k: it[k] for k in ("kind", "detail", "ex", "rec", "subject")})
    for m in blob.get("meetings") or []:
        by.setdefault(m["symbol"], []).append({"kind": "board_meeting", "detail": m["purpose"],
                                               "ex": m["date"], "rec": None, "subject": m["purpose"]})
    return [{"symbol": s, "actions": sorted(v, key=lambda x: x["ex"])} for s, v in by.items()]
