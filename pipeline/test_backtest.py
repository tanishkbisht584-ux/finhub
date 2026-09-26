"""backtest.py: the simulation on synthetic series + the weekly gate. Run: cd pipeline && py -3 -m pytest test_backtest.py"""
from datetime import date, datetime, timedelta, timezone

import backtest as bt


def trading_days(n, end=date(2026, 9, 25)):
    out, d = [], end
    while len(out) < n:
        if d.weekday() < 5:
            out.append(d)
        d -= timedelta(days=1)
    return list(reversed(out))


def test_month_starts_picks_first_trading_day_and_keeps_the_last_date():
    days = trading_days(800)
    steps = bt.month_starts(days, 36)
    assert len(steps) == 38 and steps[-1] == days[-1]
    assert all(steps[i].month != steps[i + 1].month or i == len(steps) - 2 for i in range(len(steps) - 1))
    assert steps[1].day <= 3 and bt.month_starts([], 3) == []


def test_simulate_doubling_vs_flat():
    days = trading_days(800)
    nifty = {d: 100.0 for d in days}                                  # flat benchmark
    grow = {d: 100.0 * (1.0 + i / len(days)) for i, d in enumerate(days)}   # doubles across the window
    res = bt.simulate({"UP": grow, "FLAT": dict(nifty)}, nifty, months=36, cost=0.0)
    assert res["nifty"][-1] == 100.0 and res["nifty_cagr"] == 0.0 and res["nifty_mdd"] == 0.0
    assert res["curve"][-1] > 130 and res["cagr"] > 5 and res["mdd"] == 0.0
    assert res["hit_rate"] == 100 and res["n"] == 2 and res["lookahead"] is True
    assert len(res["curve"]) == len(res["dates"]) == 38
    # a member with no prints sits out: same curve as before
    res2 = bt.simulate({"UP": grow, "FLAT": dict(nifty), "NONE": {}}, nifty, months=36, cost=0.0)
    assert res2["curve"] == res["curve"] and res2["n"] == 3
    assert bt.simulate({}, {d: 1.0 for d in days[:20]}) is None


def test_series_aligns_to_the_calendar_tail():
    cal = trading_days(10)
    row = {"asof": cal[-2].isoformat(), "closes": [1.0, None, 3.0]}
    s = bt._series(row, cal)
    assert s == {cal[-4]: 1.0, cal[-2]: 3.0}


def test_refresh_runs_on_sundays_only_and_writes_presets_and_saved(monkeypatch):
    days = trading_days(800)
    posts, gets = [], []

    def sb(method, path, **kw):
        gets.append(path.split("?")[0]) if method == "GET" else posts.append(kw["json"])
        if path.startswith("price_history?select=asof,closes,dates"):
            return [{"asof": days[-1].isoformat(), "closes": [100.0 + i for i in range(len(days))],
                     "dates": [d.isoformat() for d in days]}]
        if path.startswith("user_screens"):
            return [{"user_id": "u1", "name": "MINE", "filters": [{"metric": "pe", "gte": False, "value": 20}],
                     "sort_col": "roe", "sort_asc": False},
                    {"user_id": "u1", "name": "MF:X", "filters": [{"metric": "cagr_5y", "gte": True, "value": 1}]}]
        if path.startswith("screener_metrics"):
            return [{"symbol": "A"}, {"symbol": "B"}]
        if path.startswith("price_history?select=symbol"):
            return [{"symbol": s, "asof": days[-1].isoformat(), "closes": [50.0 + i for i in range(len(days))]}
                    for s in ("A", "B")]
        return None

    saturday = datetime(2026, 9, 26, 17, 30, tzinfo=timezone.utc)   # 23:00 IST Saturday
    assert bt.refresh(sb, saturday) == 0
    sunday = saturday + timedelta(days=1)
    assert bt.refresh(sb, sunday) == 7                              # 6 presets + MINE (MF:X skipped)
    rows = posts[0]
    assert {r["name"] for r in rows} == set(bt.PRESETS) | {"MINE"}
    mine = next(r for r in rows if r["name"] == "MINE")
    assert mine["user_id"] == "u1" and mine["result"]["symbols"] == ["A", "B"] and mine["result"]["cagr"] > 0
    assert mine["params"]["filters"] == [["pe", False, 20]]
