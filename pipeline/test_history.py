"""history.py: pure checks, no network. Run: cd pipeline && py -3 -m pytest test_history.py"""
from datetime import date, timedelta, timezone

import history


def _days(start, n):
    d, out = start, []
    while len(out) < n:
        if d.weekday() < 5:
            out.append(d)
        d += timedelta(days=1)
    return out


def test_series_of_keeps_nulls_aligned():
    tz = timezone.utc
    j = {"chart": {"result": [{"timestamp": [86400 * 19000, 86400 * 19001, 86400 * 19002],
                               "indicators": {"quote": [{"close": [10.0, None, 12.0], "volume": [1, 2, 3]}]}}]}}
    dates, closes, vols = history.series_of(j, tz)
    assert len(dates) == 3 and closes == [10.0, None, 12.0] and vols == [1, 2, 3]


def test_full_row_extremes_and_trim():
    dates = _days(date(2015, 1, 1), history.MAX_CLOSES + 50)
    closes = [100.0 + i for i in range(len(dates))]
    closes[7] = 5.0                                   # an old all-time low, outside the kept window
    row = history.full_row("TCS", dates, closes, [1.0] * len(dates))
    assert len(row["closes"]) == history.MAX_CLOSES and len(row["vols"]) == history.MAX_VOLS
    assert row["atl"] == 5.0 and row["atl_date"] == dates[7].isoformat()
    assert row["ath"] == closes[-1] and row["asof"] == dates[-1].isoformat()
    assert "dates" not in row
    cal = history.full_row("^NSEI", dates, closes, [None] * len(dates))
    assert len(cal["dates"]) == history.MAX_CLOSES and cal["dates"][-1] == dates[-1].isoformat()


def test_plan_merge_overlap_and_new_extremes():
    dates = _days(date(2026, 1, 1), 250)
    closes = [50.0] * 250
    closes[3] = 20.0                                  # new all-time low inside the window
    have = {"symbol": "TCS", "asof": dates[199].isoformat(), "atl": 30.0, "ath": 60.0}
    verdict, p = history.plan_merge(have, dates, closes, [1.0] * 250)
    assert verdict == "merge"
    assert p["k"] == 200 and p["asof"] == dates[-1].isoformat() and p["chk"] == 50.0
    assert p["atl"] == 20.0 and p["atl_date"] == dates[3].isoformat()
    assert p["ath"] is None and p["ath_date"] is None  # 50 < stored 60: RPC keeps the old high


def test_plan_merge_gap_means_refill():
    dates = _days(date(2026, 3, 1), 10)
    have = {"symbol": "TCS", "asof": "2025-01-01", "atl": None, "ath": None}
    assert history.plan_merge(have, dates, [1.0] * 10, [1.0] * 10) == ("refill", None)


def test_update_routes_missing_rows_to_refill(monkeypatch):
    calls = []

    def fake_sb(method, path, **kw):
        calls.append((method, path.split("?")[0]))
        if method == "GET":
            return [{"symbol": "TCS", "asof": "2026-06-01", "atl": 1.0, "ath": 9.0}]
        if path.startswith("rpc/history_merge"):
            return ["TCS"]          # the RPC bounced it: series re-adjusted
        return None

    dates = _days(date(2026, 1, 1), 5) + [date(2026, 6, 1), date(2026, 6, 2)]
    series = {"TCS": (dates, [1.0] * 7, [1.0] * 7), "INFY": (dates, [2.0] * 7, [1.0] * 7)}
    monkeypatch.setattr(history, "fetch_max", lambda s, tz, h, t: (dates, [3.0] * 7, [1.0] * 7))
    monkeypatch.setattr(history.time, "sleep", lambda s: None)
    import market
    written = []
    monkeypatch.setattr(market, "upsert", lambda sb, rows, table="quotes", key="symbol": written.extend(rows) or len(rows))
    n = history.update(fake_sb, series, timezone.utc, {}, 5)
    assert ("POST", "rpc/history_merge") in calls
    assert sorted(r["symbol"] for r in written) == ["INFY", "TCS"]   # INFY missing, TCS bounced
    assert n == 1 + 2
