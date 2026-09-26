"""mf.py: pure checks + the two groups with a fake db. Run: cd pipeline && py -3 -m pytest test_mf.py"""
from datetime import date, datetime, timedelta, timezone

import mf

TODAY = date(2026, 9, 26)


def navs(years=6, daily=0.0004, start=10.0):
    """A smooth ~10%/yr series, one point per calendar day, ending TODAY."""
    n = years * 365
    out, v = [], start
    for i in range(n):
        d = TODAY - timedelta(days=n - 1 - i)
        out.append((d, round(v, 4)))
        v *= 1 + daily
    return out


def test_wanted_and_category_split():
    assert mf.wanted("Parag Parikh Flexi Cap Fund - Direct Plan - Growth")
    assert not mf.wanted("Parag Parikh Flexi Cap Fund - Regular Plan - Growth")
    assert not mf.wanted("HDFC Top 100 Fund - Direct Plan - IDCW")
    assert not mf.wanted(None)
    assert mf.split_category("Equity Scheme - Large Cap Fund") == ("Equity", "Large Cap")
    assert mf.split_category("Debt Scheme - Liquid Fund") == ("Debt", "Liquid")
    assert mf.split_category("Other Scheme - Index Funds") == ("Other", "Index Funds")
    assert mf.split_category(None) == (None, None)


def test_parse_navs_sorts_and_drops_junk():
    j = {"data": [{"date": "26-09-2026", "nav": "12.5"}, {"date": "25-09-2026", "nav": "12.4"},
                  {"date": "junk", "nav": "1"}, {"date": "24-09-2026", "nav": "0"}]}
    assert mf.parse_navs(j) == [(date(2026, 9, 25), 12.4), (date(2026, 9, 26), 12.5)]


def test_mf_stats_returns_cagr_vol_drawdown_age():
    s = mf.mf_stats(navs(), TODAY)
    daily = 1.0004
    assert s["nav_date"] == "2026-09-26" and s["age_y"] == 6.0
    assert abs(s["cagr_3y"] - (daily ** 365 - 1) * 100) < 0.3
    assert abs(s["cagr_5y"] - (daily ** 365 - 1) * 100) < 0.3
    assert abs(s["ret_1y"] - (daily ** 365 - 1) * 100) < 0.3
    assert s["ret_1m"] > 0 and s["mdd_3y"] == 0.0 and s["vol_1y"] == 0.0  # smooth series: no drawdown, no vol
    assert s["sharpe_1y"] is None                                          # zero vol → undefined
    short = mf.mf_stats(navs(years=1), TODAY)
    assert short["ret_3y"] is None and short["cagr_5y"] is None and short["ret_6m"] is not None


def test_mf_stats_drawdown_and_sharpe_on_a_bumpy_series():
    series = navs(years=2)
    n = len(series)
    bumpy = [(d, v * (0.8 if n // 2 < i < n // 2 + 60 else 1.0)) for i, (d, v) in enumerate(series)]
    s = mf.mf_stats(bumpy, TODAY)
    assert s["mdd_3y"] < -19 and s["vol_1y"] > 0 and s["sharpe_1y"] is not None
    assert mf.mf_stats([], TODAY) == {}


def test_refresh_universe_adds_only_new_direct_growth(monkeypatch):
    import market

    class R:
        status_code = 200

        def raise_for_status(self):
            pass

        def json(self):
            return [{"schemeCode": 1, "schemeName": "A Fund - Direct Plan - Growth"},
                    {"schemeCode": 2, "schemeName": "B Fund - Direct Plan - Growth"},
                    {"schemeCode": 3, "schemeName": "C Fund - Regular Plan - Growth"},
                    {"schemeCode": "x", "schemeName": "Bad - Direct Growth"}]

    monkeypatch.setattr(mf.requests, "get", lambda *a, **k: R())
    written = []
    monkeypatch.setattr(market, "upsert", lambda sb, rows, table, key: written.extend(rows) or len(rows))
    n = mf.refresh_universe(lambda m, p, **k: [{"code": 1}], datetime(2026, 9, 26, tzinfo=timezone.utc))
    assert n == 1 and written == [{"code": 2, "name": "B Fund - Direct Plan - Growth"}]


def test_refresh_drain_skips_market_hours_and_fills_rows(monkeypatch):
    import market

    class R:
        status_code = 200

        def raise_for_status(self):
            pass

        def json(self):
            return {"meta": {"scheme_name": "A Fund - Direct Plan - Growth", "fund_house": "A AMC",
                             "scheme_category": "Equity Scheme - Mid Cap Fund"},
                    "data": [{"date": d.strftime("%d-%m-%Y"), "nav": str(v)} for d, v in reversed(navs(years=2))]}

    monkeypatch.setattr(mf.requests, "get", lambda *a, **k: R())
    monkeypatch.setattr(mf.time, "sleep", lambda s: None)
    written = []
    monkeypatch.setattr(market, "upsert", lambda sb, rows, table, key: written.extend(rows) or len(rows))
    sb = lambda m, p, **k: [{"code": 7}]  # noqa: E731
    open_hours = datetime(2026, 9, 25, 5, 0, tzinfo=timezone.utc)   # 10:30 IST Friday
    assert mf.refresh_drain(sb, open_hours) == 0
    night = datetime(2026, 9, 25, 16, 0, tzinfo=timezone.utc)
    assert mf.refresh_drain(sb, night) == 1
    row = written[0]
    assert row["code"] == 7 and row["category"] == "Equity" and row["sub_category"] == "Mid Cap"
    assert row["house"] == "A AMC" and row["cagr_3y"] is None and row["ret_1y"] is not None
