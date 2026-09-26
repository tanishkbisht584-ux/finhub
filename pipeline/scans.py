"""Technical scans (free-parity P3, 26 Sep 2026): the 18 patterns MC "Scans"
and Trendlyne sell, computed on the 1y daily OHLCV the technicals pass
already downloads per symbol (signals_for -> screener_metrics.signals), then
rolled up nightly into the Markets SCANS blob and ONE grouped push per user
holding a signalled stock (portfolio or price alert; `alert_settings.scans`
false opts out). Pure predicates; the only I/O is refresh() and push().

Run the checks: cd pipeline && py -3 -m pytest test_scans.py
"""
import statistics

SCANS = ("golden_cross", "death_cross", "rsi_oversold", "rsi_overbought",
         "breakout_52w", "breakdown_52w", "volume_spike", "macd_bull", "macd_bear",
         "gap_up", "gap_down", "nr7", "inside_bar",
         "hammer", "shooting_star", "bullish_engulfing", "bearish_engulfing", "doji")
LABEL = {"golden_cross": "golden cross", "death_cross": "death cross", "rsi_oversold": "RSI oversold",
         "rsi_overbought": "RSI overbought", "breakout_52w": "52-week breakout",
         "breakdown_52w": "52-week breakdown", "volume_spike": "volume spike", "macd_bull": "MACD bullish",
         "macd_bear": "MACD bearish", "gap_up": "gap up", "gap_down": "gap down", "nr7": "NR7 squeeze",
         "inside_bar": "inside bar", "hammer": "hammer", "shooting_star": "shooting star",
         "bullish_engulfing": "bullish engulfing", "bearish_engulfing": "bearish engulfing", "doji": "doji"}
LIST_CAP = 60          # symbols per scan in the blob (mcap-desc)
SCAN_PUSH_CAP = 300    # users pushed per night; knob
VOLUME_X = 2.5         # volume spike = today's volume vs the 20-day average
GAP_PCT = 0.02


def _ema(values, n):
    k = 2 / (n + 1)
    e = values[0]
    out = [e]
    for v in values[1:]:
        e = v * k + e * (1 - k)
        out.append(e)
    return out


def _sma(values, n):
    return [None] * (n - 1) + [sum(values[i - n + 1:i + 1]) / n for i in range(n - 1, len(values))]


def _rsi(c, n=14):
    if len(c) < n + 1:
        return None
    gains = losses = 0.0
    for a, b in zip(c[:n], c[1:n + 1]):
        gains += max(b - a, 0)
        losses += max(a - b, 0)
    avg_g, avg_l = gains / n, losses / n
    for a, b in zip(c[n:], c[n + 1:]):
        avg_g = (avg_g * (n - 1) + max(b - a, 0)) / n
        avg_l = (avg_l * (n - 1) + max(a - b, 0)) / n
    return 100.0 if avg_l == 0 else 100 - 100 / (1 + avg_g / avg_l)


def clean(q):
    """Yahoo quote lists -> aligned (o, h, l, c, v) with the null prints dropped."""
    cols = [q.get(k) or [] for k in ("open", "high", "low", "close", "volume")]
    n = min(len(x) for x in cols) if all(cols) else 0
    rows = [(cols[0][i], cols[1][i], cols[2][i], cols[3][i], cols[4][i] or 0) for i in range(n)
            if None not in (cols[0][i], cols[1][i], cols[2][i], cols[3][i])]
    return tuple(list(x) for x in zip(*rows)) if rows else ([], [], [], [], [])


def signals_for(q):
    """The scan names true on the LAST bar of a 1y daily series (Yahoo chart
    `quote` dict). Fewer than 30 bars -> nothing (no pattern is meaningful)."""
    o, h, l, c, v = clean(q)
    n = len(c)
    if n < 30:
        return []
    out = []
    s50, s200 = _sma(c, 50), _sma(c, 200)
    if n >= 204 and s50[-4] is not None and s200[-4] is not None:
        if s50[-4] <= s200[-4] and s50[-1] > s200[-1]:
            out.append("golden_cross")
        if s50[-4] >= s200[-4] and s50[-1] < s200[-1]:
            out.append("death_cross")
    rsi = _rsi(c)
    if rsi is not None:
        if rsi <= 30:
            out.append("rsi_oversold")
        elif rsi >= 70:
            out.append("rsi_overbought")
    if n >= 60:
        if c[-1] >= max(h[-250:-1]):
            out.append("breakout_52w")
        if c[-1] <= min(l[-250:-1]):
            out.append("breakdown_52w")
    avg_v = sum(v[-21:-1]) / 20
    if avg_v and v[-1] >= VOLUME_X * avg_v:
        out.append("volume_spike")
    if n >= 36:
        macd = [a - b for a, b in zip(_ema(c, 12), _ema(c, 26))]
        hist = [m - s for m, s in zip(macd, _ema(macd, 9))]
        if hist[-2] <= 0 < hist[-1]:
            out.append("macd_bull")
        if hist[-2] >= 0 > hist[-1]:
            out.append("macd_bear")
    if o[-1] > h[-2] and o[-1] / c[-2] - 1 >= GAP_PCT:
        out.append("gap_up")
    if o[-1] < l[-2] and 1 - o[-1] / c[-2] >= GAP_PCT:
        out.append("gap_down")
    rng = [hh - ll for hh, ll in zip(h[-7:], l[-7:])]
    if rng[-1] > 0 and rng[-1] == min(rng):
        out.append("nr7")
    if h[-1] <= h[-2] and l[-1] >= l[-2]:
        out.append("inside_bar")
    body, span = abs(c[-1] - o[-1]), h[-1] - l[-1]
    if span > 0:
        upper, lower = h[-1] - max(c[-1], o[-1]), min(c[-1], o[-1]) - l[-1]
        if body <= 0.3 * span and lower >= 2 * body and upper <= body:
            out.append("hammer")
        if body <= 0.3 * span and upper >= 2 * body and lower <= body:
            out.append("shooting_star")
        if body <= 0.1 * span:
            out.append("doji")
    if c[-2] < o[-2] and c[-1] > o[-1] and o[-1] <= c[-2] and c[-1] >= o[-2]:
        out.append("bullish_engulfing")
    if c[-2] > o[-2] and c[-1] < o[-1] and o[-1] >= c[-2] and c[-1] <= o[-2]:
        out.append("bearish_engulfing")
    return out


def lists_of(rows, cap=LIST_CAP):
    """screener rows (mcap-desc) -> {scan: [{s, n, p}]} + counts."""
    lists = {k: [] for k in SCANS}
    for r in sorted(rows, key=lambda r: -(r.get("mcap_cr") or 0)):
        for k in r.get("signals") or []:
            if k in lists and len(lists[k]) < cap:
                lists[k].append({"s": r["symbol"], "n": r.get("name"), "p": r.get("price")})
    counts = {k: sum(1 for r in rows if k in (r.get("signals") or [])) for k in SCANS}
    return {k: v for k, v in lists.items() if v}, counts


def refresh(sb, now):
    """Nightly (after the technicals pass): the SCANS blob + one push per holder."""
    from market import IST, write_blobs
    rows = sb("GET", "screener_metrics?select=symbol,name,price,mcap_cr,signals&signals=not.is.null")
    lists, counts = lists_of(rows)
    ts = now.isoformat()
    write_blobs(sb, [{"key": "scans", "payload": {"asof": now.astimezone(IST).date().isoformat(),
                                                  "counts": counts, "lists": lists}, "updated_at": ts}])
    hits = {r["symbol"]: r["signals"] for r in rows if r.get("signals")}
    try:
        return 1 + push(sb, hits, now)
    except Exception as e:  # noqa: BLE001 — the blob is written; a push failure is logged, not fatal
        print(f"SCANS push: {e}")
        return 1


def recipients(holders, tokens, hits, cap=SCAN_PUSH_CAP):
    """-> [(user_id, token, title, body, first_symbol)] for users who hold a
    signalled stock and have not opted out; at most `cap`."""
    out = []
    for uid in sorted(holders):
        syms = sorted(s for s in holders[uid] if s in hits)
        p = tokens.get(uid)
        if not syms or not p or not p.get("fcm_token") or (p.get("alert_settings") or {}).get("scans") is False:
            continue
        n = sum(len(hits[s]) for s in syms)
        parts = [f"{s} {LABEL.get(hits[s][0], hits[s][0])}" for s in syms][:4]
        title = f"{n} signal{'s' if n != 1 else ''} on your stocks"
        out.append((uid, p["fcm_token"], title, " · ".join(parts) + (" …" if len(syms) > 4 else ""), syms[0]))
        if len(out) >= cap:
            break
    return out


def push(sb, hits, now):
    import run  # local: run imports market
    if not hits:
        return 0
    holders = {}
    for path in ("portfolio_trades?select=user_id,symbol", "price_alerts?select=user_id,symbol&active=is.true"):
        for r in sb("GET", path):
            if r["symbol"] in hits:
                holders.setdefault(r["user_id"], set()).add(r["symbol"])
    if not holders:
        return 0
    quoted = ",".join(f'"{u}"' for u in sorted(holders))
    tokens = {r["id"]: r for r in sb("GET", f"profiles?select=id,fcm_token,alert_settings&id=in.({quoted})"
                                           "&fcm_token=not.is.null")}
    sent = 0
    for uid, tok, title, body, sym in recipients(holders, tokens, hits, cap=getattr(run, "SCAN_PUSH_CAP", SCAN_PUSH_CAP)):
        res = run.send_fcm_token(tok, title, body, "", "", data={"symbol": sym, "route": "scans"})
        if res == "sent":
            sent += 1
        elif res == "dead":
            sb("PATCH", f"profiles?id=eq.{uid}", json={"fcm_token": None})
    print(f"SCANS: {len(hits)} symbols signalled, {sent} pushed")
    return sent
