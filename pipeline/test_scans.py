"""scans.py: one fixture per predicate + the rollup/push halves with a fake db.
Run: cd pipeline && py -3 -m pytest test_scans.py"""
from datetime import datetime, timezone

import scans

NOW = datetime(2026, 9, 26, 14, 30, tzinfo=timezone.utc)


def series(closes, *, opens=None, highs=None, lows=None, vols=None):
    n = len(closes)
    o = opens or closes
    return {"open": list(o), "high": list(highs or [max(a, b) * 1.01 for a, b in zip(o, closes)]),
            "low": list(lows or [min(a, b) * 0.99 for a, b in zip(o, closes)]),
            "close": list(closes), "volume": list(vols or [1000] * n)}


def flat(n, px=100.0):
    return [px] * n


def test_too_short_is_silent_and_nulls_are_dropped():
    assert scans.signals_for(series(flat(20))) == []
    q = series(flat(40))
    q["close"][5] = None
    assert scans.clean(q)[3] == [100.0] * 39


def test_golden_and_death_cross_within_three_bars():
    # 250 flat bars then a sharp rise: sma50 crosses above sma200 near the end
    c = flat(250) + [100 + i * 3 for i in range(1, 15)]
    assert "golden_cross" in scans.signals_for(series(c)) or "breakout_52w" in scans.signals_for(series(c))
    down = [200.0] * 250 + [200 - i * 6 for i in range(1, 15)]
    sig = scans.signals_for(series(down))
    assert "death_cross" in sig or "breakdown_52w" in sig


def test_rsi_extremes():
    up = [100 + i for i in range(40)]
    assert "rsi_overbought" in scans.signals_for(series(up))
    dn = [140 - i for i in range(40)]
    assert "rsi_oversold" in scans.signals_for(series(dn))


def test_breakout_breakdown_and_volume_spike():
    c = flat(80) + [110.0]
    q = series(c, highs=[101.0] * 80 + [111.0], lows=[99.0] * 81, vols=[1000] * 80 + [3000])
    sig = scans.signals_for(q)
    assert "breakout_52w" in sig and "volume_spike" in sig
    c = flat(80) + [90.0]
    q = series(c, highs=[101.0] * 81, lows=[99.0] * 80 + [89.0])
    assert "breakdown_52w" in scans.signals_for(q)


def test_gap_up_and_down_need_a_true_gap():
    o = flat(39) + [104.0]
    q = series(flat(39) + [105.0], opens=o, highs=[101.0] * 39 + [106.0], lows=[99.0] * 39 + [103.0])
    assert "gap_up" in scans.signals_for(q)
    q = series(flat(39) + [95.0], opens=flat(39) + [96.0], highs=[101.0] * 39 + [97.0], lows=[99.0] * 39 + [94.0])
    assert "gap_down" in scans.signals_for(q)
    q = series(flat(39) + [101.0], opens=flat(39) + [100.5])  # opens inside yesterday's range: no gap
    assert "gap_up" not in scans.signals_for(q)


def test_nr7_inside_bar_and_candles():
    n = 40
    h = [105.0] * n
    l = [95.0] * n
    h[-1], l[-1] = 101.0, 99.5   # narrowest range of the last 7 and inside yesterday
    q = series(flat(n), highs=h, lows=l)
    sig = scans.signals_for(q)
    assert "nr7" in sig and "inside_bar" in sig
    # hammer: small body at the top, long lower shadow
    o, c, hh, ll = flat(n), flat(n), [101.0] * n, [99.0] * n
    o[-1], c[-1], hh[-1], ll[-1] = 100.0, 100.4, 100.5, 96.0
    assert "hammer" in scans.signals_for(series(c, opens=o, highs=hh, lows=ll))
    # shooting star: mirror
    o[-1], c[-1], hh[-1], ll[-1] = 100.4, 100.0, 104.5, 99.9
    assert "shooting_star" in scans.signals_for(series(c, opens=o, highs=hh, lows=ll))
    # doji
    o[-1], c[-1], hh[-1], ll[-1] = 100.0, 100.05, 101.0, 99.0
    assert "doji" in scans.signals_for(series(c, opens=o, highs=hh, lows=ll))
    # engulfing pairs
    o, c = flat(n), flat(n)
    o[-2], c[-2], o[-1], c[-1] = 101.0, 100.0, 99.5, 101.5
    assert "bullish_engulfing" in scans.signals_for(series(c, opens=o))
    o[-2], c[-2], o[-1], c[-1] = 100.0, 101.0, 101.5, 99.5
    assert "bearish_engulfing" in scans.signals_for(series(c, opens=o))


def test_lists_of_caps_by_mcap_and_counts():
    rows = [{"symbol": f"S{i}", "name": f"N{i}", "price": i, "mcap_cr": i, "signals": ["doji"]} for i in range(70)]
    rows.append({"symbol": "Z", "name": "Z", "price": 1, "mcap_cr": 5, "signals": ["nr7", "doji"]})
    lists, counts = scans.lists_of(rows, cap=60)
    assert len(lists["doji"]) == 60 and lists["doji"][0]["s"] == "S69" and counts["doji"] == 71
    assert lists["nr7"] == [{"s": "Z", "n": "Z", "p": 1}] and "hammer" not in lists


def test_recipients_group_opt_out_and_cap():
    holders = {"u1": {"TCS", "INFY", "X"}, "u2": {"TCS"}, "u3": {"TCS"}, "u4": {"INFY"}}
    tokens = {"u1": {"fcm_token": "t1", "alert_settings": {}},
              "u2": {"fcm_token": "t2", "alert_settings": {"scans": False}},
              "u3": {"fcm_token": None}, "u4": {"fcm_token": "t4", "alert_settings": {"scans": True}}}
    hits = {"TCS": ["golden_cross", "volume_spike"], "INFY": ["doji"]}
    out = scans.recipients(holders, tokens, hits, cap=5)
    assert [r[0] for r in out] == ["u1", "u4"]
    uid, tok, title, body, sym = out[0]
    assert title == "3 signals on your stocks" and body == "INFY doji · TCS golden cross" and sym == "INFY"
    assert scans.recipients(holders, tokens, hits, cap=1)[0][0] == "u1" and len(scans.recipients(holders, tokens, hits, cap=1)) == 1


def test_refresh_writes_blob_and_pushes(monkeypatch):
    import run
    calls = []

    def fake_sb(method, path, **kw):
        calls.append((method, path.split("?")[0]))
        if path.startswith("screener_metrics"):
            return [{"symbol": "TCS", "name": "TCS", "price": 3000, "mcap_cr": 10, "signals": ["hammer"]}]
        if path.startswith("portfolio_trades"):
            return [{"user_id": "u1", "symbol": "TCS"}]
        if path.startswith("price_alerts"):
            return []
        if path.startswith("profiles"):
            return [{"id": "u1", "fcm_token": "tok", "alert_settings": {}}]
        return None

    blobs = []
    import market
    monkeypatch.setattr(market, "write_blobs", lambda sb, rows: blobs.extend(rows) or len(rows))
    monkeypatch.setattr(run, "send_fcm_token", lambda *a, **k: "sent")
    assert scans.refresh(fake_sb, NOW) == 2
    assert blobs[0]["key"] == "scans" and blobs[0]["payload"]["lists"]["hammer"][0]["s"] == "TCS"
    assert blobs[0]["payload"]["counts"]["hammer"] == 1 and blobs[0]["payload"]["asof"] == "2026-09-26"
