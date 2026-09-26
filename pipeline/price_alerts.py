"""User-set price alerts (Phase B, 26 Sep 2026). Runs inside the equity quote
lap right after the rows are upserted, on the rows already in memory — no
second read of `quotes`. Market hours only by construction: outside them the
lap carries the same stale price and a just-created alert must not fire at
23:00. Rules (pure, in `decide`):

  above  price > threshold        fires once, then active=false (re-arm in app)
  below  price < threshold        fires once, then active=false
  move   |change_pct| >= threshold  at most once per IST day, stays active
  hi52   price > screener hi52     at most once per IST day (daily closes)
  lo52   price < screener lo52     at most once per IST day
"""
from datetime import timezone
from urllib.parse import quote

import requests

from market import IST, market_hours

ONCE = {"above", "below"}          # fire once, then deactivate
DAILY = {"move", "hi52", "lo52"}   # at most once per IST day

LABEL = {
    "above": lambda t: f"above ₹{t:,.2f}",
    "below": lambda t: f"below ₹{t:,.2f}",
    "move": lambda t: f"moved {t:g}% today",
    "hi52": lambda t: "new 52-week high",
    "lo52": lambda t: "new 52-week low",
}


def _ist_day(ts):
    return ts.astimezone(IST).strftime("%Y-%m-%d") if ts else None


def _fired_today(alert, now):
    last = alert.get("last_fired_at")
    if not last:
        return False
    from datetime import datetime
    try:
        ts = datetime.fromisoformat(last.replace("Z", "+00:00"))
    except ValueError:
        return False
    return _ist_day(ts) == _ist_day(now)


def decide(alerts, px, levels, now):
    """[(alert, price)] that fire this lap. `px` = {symbol: quote row} from
    the lap, `levels` = {symbol: (hi52, lo52)} from screener_metrics."""
    out = []
    for a in alerts:
        row = px.get(a["symbol"])
        if not row or row.get("price") is None:
            continue
        price, kind = float(row["price"]), a["kind"]
        t = a.get("threshold")
        if kind in DAILY and _fired_today(a, now):
            continue
        if kind == "above":
            hit = t is not None and price > float(t)
        elif kind == "below":
            hit = t is not None and price < float(t)
        elif kind == "move":
            pct = row.get("change_pct")
            hit = t is not None and pct is not None and abs(float(pct)) >= float(t)
        elif kind == "hi52":
            hi = (levels.get(a["symbol"]) or (None, None))[0]
            hit = hi is not None and price > float(hi)
        elif kind == "lo52":
            lo = (levels.get(a["symbol"]) or (None, None))[1]
            hit = lo is not None and price < float(lo)
        else:
            hit = False
        if hit:
            out.append((a, price))
    return out


def evaluate(sb, rows, now, off=False):
    """Read active alerts, decide, push, record. Returns pushes sent. Every
    failure is the caller's to log — quotes must never wait on alerts."""
    import run  # local: run imports market imports this module

    if off or not rows or not market_hours(now):
        return 0
    try:
        alerts = sb("GET", "price_alerts?select=id,user_id,symbol,kind,threshold,last_fired_at,fire_count"
                           "&active=is.true")
    except requests.HTTPError as e:
        if "price_alerts" in str(e):
            print("PRICE ALERTS: migration 029 missing")
            return 0
        raise
    if not alerts:
        return 0
    px = {r["symbol"]: r for r in rows}
    levels = {}
    need = sorted({a["symbol"] for a in alerts if a["kind"] in ("hi52", "lo52") and a["symbol"] in px})
    if need:
        vals = ",".join(f'"{quote(s, safe="")}"' for s in need)
        for r in sb("GET", f"screener_metrics?select=symbol,hi52,lo52&symbol=in.({vals})"):
            levels[r["symbol"]] = (r.get("hi52"), r.get("lo52"))
    fired = decide(alerts, px, levels, now)
    if not fired:
        return 0
    uids = sorted({a["user_id"] for a, _ in fired})
    quoted = ",".join(f'"{u}"' for u in uids)
    tokens = {r["id"]: r["fcm_token"] for r in
              sb("GET", f"profiles?select=id,fcm_token&id=in.({quoted})&fcm_token=not.is.null")}
    hhmm = now.astimezone(IST).strftime("%H:%M")
    sent, history, dead = 0, [], set()
    for a, price in fired:
        t = a.get("threshold")
        title = f"{a['symbol']} {LABEL[a['kind']](float(t) if t is not None else None)}"
        body = f"₹{price:,.2f} at {hhmm} IST"
        tok = tokens.get(a["user_id"])
        if tok and a["user_id"] not in dead:
            res = run.send_fcm_token(tok, title, body, "", "",
                                     data={"symbol": a["symbol"], "alert_id": str(a["id"])})
            if res == "sent":
                sent += 1
            elif res == "dead":
                dead.add(a["user_id"])
                sb("PATCH", f"profiles?id=eq.{a['user_id']}", json={"fcm_token": None})
        history.append({"alert_id": a["id"], "user_id": a["user_id"], "symbol": a["symbol"],
                        "kind": a["kind"], "threshold": t, "price": price,
                        "fired_at": now.astimezone(timezone.utc).isoformat()})
        sb("PATCH", f"price_alerts?id=eq.{a['id']}",
           json={"last_fired_at": now.astimezone(timezone.utc).isoformat(),
                 "fire_count": int(a.get("fire_count") or 0) + 1,
                 "active": a["kind"] not in ONCE})
    sb("POST", "price_alert_fires", json=history, headers={"Prefer": "return=minimal"})
    print(f"PRICE ALERTS: {len(fired)} fired, {sent} pushed")
    return sent
