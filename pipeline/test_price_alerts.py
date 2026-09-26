"""price_alerts.py: pure rules + the lap hook. Run: cd pipeline && py -3 -m pytest test_price_alerts.py"""
from datetime import datetime, timedelta, timezone

import requests

import market
import price_alerts
import run
from market import IST

UTC = timezone.utc


def ist(y, m, d, hh, mm):
    return datetime(y, m, d, hh, mm, tzinfo=IST).astimezone(UTC)


NOW = ist(2026, 9, 28, 11, 30)  # Monday, in hours
PX = {"TCS": {"symbol": "TCS", "price": 4200.0, "change_pct": 2.4},
      "INFY": {"symbol": "INFY", "price": 1500.0, "change_pct": -0.3}}


def alert(id_, kind, threshold=None, symbol="TCS", last=None, user="u1"):
    return {"id": id_, "user_id": user, "symbol": symbol, "kind": kind, "threshold": threshold,
            "last_fired_at": last, "fire_count": 0}


def test_decide_above_below_move_and_52w():
    alerts = [alert(1, "above", 4100), alert(2, "above", 4300), alert(3, "below", 4300),
              alert(4, "move", 2.0), alert(5, "move", 3.0), alert(6, "hi52"), alert(7, "lo52"),
              alert(8, "above", 1000, symbol="NOQUOTE"), alert(9, "hi52", symbol="INFY")]
    fired = price_alerts.decide(alerts, PX, {"TCS": (4150.0, 3000.0)}, NOW)
    assert [a["id"] for a, _ in fired] == [1, 3, 4, 6]   # 9: INFY has no level -> skipped
    assert fired[0][1] == 4200.0


def test_daily_kinds_fire_once_per_ist_day_but_once_kinds_are_not_date_gated():
    today = (NOW - timedelta(hours=1)).isoformat()
    yesterday = (NOW - timedelta(days=1)).isoformat()
    alerts = [alert(1, "move", 1.0, last=today), alert(2, "move", 1.0, last=yesterday),
              alert(3, "hi52", last=today), alert(4, "above", 4100, last=today)]
    fired = price_alerts.decide(alerts, PX, {"TCS": (4150.0, 3000.0)}, NOW)
    assert [a["id"] for a, _ in fired] == [2, 4]


def test_evaluate_is_market_hours_only_and_skips_when_off_or_missing_table():
    calls = []
    sb = lambda m, p, **kw: calls.append(p) or []  # noqa: E731
    assert price_alerts.evaluate(sb, [PX["TCS"]], ist(2026, 9, 28, 23, 0)) == 0   # off-hours
    assert price_alerts.evaluate(sb, [PX["TCS"]], ist(2026, 9, 27, 11, 0)) == 0   # Sunday
    assert price_alerts.evaluate(sb, [PX["TCS"]], NOW, off=True) == 0
    assert calls == []  # no reads at all

    def missing(m, p, **kw):
        raise requests.HTTPError("404 price_alerts: relation does not exist")
    assert price_alerts.evaluate(missing, [PX["TCS"]], NOW) == 0


def test_evaluate_pushes_with_symbol_records_history_and_deactivates_once_kinds(monkeypatch):
    paths, patches, posts, pushed = [], [], [], []

    def sb(method, path, json=None, **kw):
        paths.append((method, path))
        if path.startswith("price_alerts?select"):
            return [alert(1, "above", 4100), alert(2, "move", 2.0, user="u2"), alert(3, "hi52")]
        if path.startswith("screener_metrics"):
            assert '"TCS"' in path
            return [{"symbol": "TCS", "hi52": 4150.0, "lo52": 3000.0}]
        if path.startswith("profiles?select"):
            return [{"id": "u1", "fcm_token": "tok1"}, {"id": "u2", "fcm_token": "tok2"}]
        if method == "PATCH":
            patches.append((path, json))
            return None
        if method == "POST":
            posts.append(json)
            return None
        raise AssertionError(path)

    def fake_send(tok, title, body, sid, score, data=None):
        pushed.append((tok, title, body, data))
        return "dead" if tok == "tok2" else "sent"

    monkeypatch.setattr(run, "send_fcm_token", fake_send)
    sent = price_alerts.evaluate(sb, list(PX.values()), NOW)
    assert sent == 2  # tok2 dead: not counted, token nulled
    assert pushed[0][1] == "TCS above ₹4,100.00" and pushed[0][3] == {"symbol": "TCS", "alert_id": "1"}
    assert pushed[0][2] == "₹4,200.00 at 11:30 IST"
    assert pushed[2][1] == "TCS new 52-week high"
    assert ("profiles?id=eq.u2", {"fcm_token": None}) in patches
    by_id = {p: j for p, j in patches if p.startswith("price_alerts?id=eq.")}
    assert by_id["price_alerts?id=eq.1"]["active"] is False      # above: fire once
    assert by_id["price_alerts?id=eq.2"]["active"] is True       # move: stays armed
    assert by_id["price_alerts?id=eq.3"]["fire_count"] == 1
    assert len(posts) == 1 and [h["alert_id"] for h in posts[0]] == [1, 2, 3]
    assert posts[0][0]["price"] == 4200.0


def test_refresh_equities_survives_an_alerts_failure(monkeypatch):
    monkeypatch.setattr(market, "equity_universe", lambda sb, now: [("TCS", "TCS")])
    monkeypatch.setattr(market, "fetch_spark", lambda syms: {"TCS.NS": {}})
    monkeypatch.setattr(market, "parse_spark", lambda d: market.Parsed(1.0, 1.0, 0.0, NOW.isoformat(), [1.0]))
    monkeypatch.setattr(market, "upsert", lambda sb, rows, **kw: len(rows))
    monkeypatch.setattr(price_alerts, "evaluate",
                        lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("alerts down")))
    assert market.refresh_equities(lambda *a, **kw: [], NOW) == 1


def test_send_fcm_token_merges_data_and_keeps_story_id(monkeypatch):
    seen = {}

    class Creds:
        project_id, token = "p", "t"

    class R:
        ok = True

    monkeypatch.setattr(run, "_fcm_creds", lambda: Creds())
    monkeypatch.setattr(run.requests, "post", lambda url, headers, json, timeout: seen.update(json) or R())
    assert run.send_fcm_token("tok", "TCS above ₹4,100", "body", "", "", data={"symbol": "TCS"}) == "sent"
    assert seen["message"]["data"] == {"story_id": "", "hook": "TCS above ₹4,100", "impact_score": "",
                                       "symbol": "TCS"}
