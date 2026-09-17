"""fund_audit: pure verdict/deficit/rollup checks, plus deep_fetch writing the
verdict (network faked). Run: cd pipeline && py -3 -m pytest test_fund_audit.py"""
from datetime import datetime, timezone

import fund_audit as fa
import fundamentals as fu

NOW = datetime(2026, 9, 15, 12, 0, tzinfo=timezone.utc)


def fy(sales, src="yahoo_ts", **extra):
    """A full industrial FY row: identities hold by construction."""
    op = round(sales * 0.2)
    d = {"src": src, "sales": sales, "expenses": sales - op, "op_profit": op, "interest": 10,
         "net_profit": round(sales * 0.1), "eps": 5.0, "total_assets": 1000, "equity_cap": 50,
         "reserves": 650, "borrowings": 200, "other_liab": 100, "cfo": 120, "fcf": 80,
         "roe": 14.0, "roce": 18.0, "debtor_days": 40}
    d.update(extra)
    return d


def q(sales, src="yahoo_ts", **extra):
    op = round(sales * 0.2)
    d = {"src": src, "sales": sales, "expenses": sales - op, "op_profit": op, "interest": 2,
         "net_profit": round(sales * 0.1), "eps": 1.2}
    d.update(extra)
    return d


def complete_stock():
    """10 FYs of 1000 sales (4 x 250 quarters, so quarters-vs-annual holds)."""
    annuals = {f"FY{y}": fy(1000, src="kaggle" if y < 2024 else "yahoo_ts")
               for y in range(2017, 2027)}
    quarters = {}
    for y in (2024, 2025, 2026):
        for m in ("03", "06", "09", "12"):
            quarters[f"{y}-{m}"] = q(250)
    quarters = {p: d for p, d in quarters.items() if p <= "2026-06"}
    shp = {p: {"promoters": 50.0, "fiis": 20.0, "diis": 15.0, "govt": 0.5, "public": 14.5}
           for p in ("2025-09", "2025-12", "2026-03", "2026-06")}
    return annuals, quarters, shp


def audit(annuals, quarters, shp, docs_at="2026-09-14T12:00:00+00:00", basis_drop=False):
    return fa.audit_symbol(annuals, quarters, shp, docs_at, basis_drop, NOW,
                           complete_q=fu._complete_quarters(quarters))


# ---------- verdict ----------

def test_complete_stock_has_no_gaps_or_issues():
    a = audit(*complete_stock())
    assert a["missing"] == [] and a["unfixable"] == [] and a["issues"] == []
    assert a["newest_fy"] == "FY2026" and a["newest_q"] == "2026-06" and a["shp_newest"] == "2026-06"
    assert fa.deficit(a, NOW)[0] == 0


def test_missing_balance_sheet_is_a_yahoo_fixable_gap():
    annuals, quarters, shp = complete_stock()
    for p in ("FY2026", "FY2025"):
        for k in fa.ANNUAL_BS + fa.ANNUAL_CF + ("roe", "roce"):
            annuals[p].pop(k, None)
    a = audit(annuals, quarters, shp)
    assert {"bs.missing", "cf.missing", "ratios.missing"} <= set(a["missing"])
    assert a["unfixable"] == []
    assert fa.deficit(a, NOW)[0] == 3 and fa.FIXER["bs.missing"] == "yahoo"
    # negative net worth: ROE/ROCE are undefined, not missing
    annuals, quarters, shp = complete_stock()
    annuals["FY2026"].update({"reserves": -200, "roe": None, "roce": None})
    assert "ratios.missing" not in audit(annuals, quarters, shp)["missing"]


def test_basis_dropped_symbol_with_nse_only_annuals_is_unfixable():
    annuals, quarters, shp = complete_stock()
    for p in list(annuals):
        annuals[p] = {"src": "nse", "sales": 900, "net_profit": 90, "eps": 4.0}
    a = audit(annuals, quarters, shp, basis_drop=True)
    assert {"bs.missing", "cf.missing", "ratios.missing"} <= set(a["unfixable"])
    assert fa.deficit(a, NOW)[0] == 0  # nothing left that any source can fill


def test_young_listing_short_history_is_unfixable():
    annuals, quarters, shp = complete_stock()
    annuals = {p: annuals[p] for p in ("FY2026", "FY2025", "FY2024")}
    a = audit(annuals, quarters, shp)
    assert a["missing"] == ["annual.short"] and a["unfixable"] == ["annual.short"]
    # a 2025 IPO: 5 quarters is all that exists, so q.short is not a gap NSE can fill
    young_q = {p: quarters[p] for p in sorted(quarters)[-5:]}
    a = audit(annuals, young_q, shp)
    assert a["missing"] == ["annual.short", "q.short"] and a["unfixable"] == ["annual.short", "q.short"]
    assert fa.deficit(a, NOW)[0] == 0
    # the same 5 quarters on a 10-FY stock: NSE filings hold the rest
    a = audit(complete_stock()[0], young_q, shp)
    assert a["missing"] == ["q.short"] and a["unfixable"] == []


def test_lender_identity_passes_and_needs_no_roce():
    annuals, quarters, shp = complete_stock()
    for p in annuals:  # bank layout: sales = expenses + op_profit + interest
        annuals[p].update({"sales": 400, "interest": 250, "expenses": 115, "op_profit": 35})
        annuals[p].pop("roce")
        annuals[p].pop("debtor_days")
    a = audit(annuals, quarters, shp)
    assert "ratios.missing" not in a["missing"]
    assert not [i for i in a["issues"] if i["code"] == "pnl_identity"]


def test_identity_failures_are_issues_not_gaps():
    annuals, quarters, shp = complete_stock()
    annuals["FY2026"]["reserves"] = 100        # sheet no longer sums
    annuals["FY2025"]["expenses"] = 1          # kaggle-style bad P&L row
    a = audit(annuals, quarters, shp)
    assert {"bs_identity", "pnl_identity"} <= {i["code"] for i in a["issues"]}
    assert a["missing"] == []


def test_quarters_vs_annual_mismatch_flags_basis_mix():
    annuals, quarters, shp = complete_stock()
    for p in ("2025-06", "2025-09", "2025-12", "2026-03"):  # FY2026 quarters sum 1080
        quarters[p]["sales"] = 100                          # -> 400 vs 1450 annual
        quarters[p]["expenses"] = 80
        quarters[p]["op_profit"] = 20
    a = audit(annuals, quarters, shp)
    assert {"code": "q_vs_annual", "period": "FY2026"} in a["issues"]


def test_quarter_without_op_profit_is_an_nse_gap():
    annuals, quarters, shp = complete_stock()
    del quarters["2026-06"]["op_profit"]
    a = audit(annuals, quarters, shp)
    assert "q.op_profit" in a["missing"] and fa.FIXER["q.op_profit"] == "nse"


def test_shareholding_and_docs_gaps():
    annuals, quarters, shp = complete_stock()
    for p in shp:
        shp[p].pop("fiis")
    a = audit(annuals, quarters, shp, docs_at=None)
    assert {"shp.split", "docs.missing"} <= set(a["missing"])
    assert audit(annuals, quarters, {}, docs_at=None)["missing"][:1] == ["shp.missing"]


# ---------- read-time staleness ----------

def test_stale_codes_flat_rule_and_sa_last_report_date():
    a = audit(*complete_stock())
    assert fa.stale_codes(a, NOW) == []
    old = {**a, "newest_q": "2026-03"}  # 5.5 months: flat rule says stale
    assert fa.stale_codes(old, NOW) == ["q.stale"]
    # SA says the company last reported on 2026-07-20: a Jun quarter is current
    assert fa.stale_codes(old, NOW, lrd="2026-07-20") == ["q.stale"]
    assert fa.stale_codes({**a, "newest_q": "2026-06"}, NOW, lrd="2026-07-20") == []
    # SA says a filing landed 2026-08-01 (Jun quarter) but we only hold Mar
    assert fa.stale_codes({**a, "newest_q": "2026-03"}, NOW, lrd="2026-08-01") == ["q.stale"]
    assert fa.stale_codes({**a, "shp_newest": "2026-03", "docs_at": "2026-07-01T00:00:00+00:00"},
                          NOW) == ["shp.stale", "docs.stale"]
    # shareholding follows the same lrd rule: SA says the Jun quarter was
    # reported 2026-08-01, so a Mar shareholding is out even though 120 d have not passed
    assert fa.stale_codes({**a, "shp_newest": "2026-06"}, NOW, lrd="2026-08-01") == []
    assert fa.stale_codes({**a, "shp_newest": "2026-03"}, NOW, lrd="2026-08-01") == ["shp.stale"]
    assert fa.stale_codes({**a, "shp_newest": "2026-06"}, NOW, lrd="2099-01-01") == []  # future lrd ignored


def test_deficit_never_audited_is_infinite():
    assert fa.deficit(None, NOW) == (fa.INF, ["never_audited"])


# ---------- rollup / ordering ----------

def test_rollup_counts_and_worst():
    ok = audit(*complete_stock())
    a2 = {**ok, "missing": ["bs.missing", "cf.missing"], "unfixable": ["cf.missing"]}
    roll = fa.rollup([("A", ok, None), ("B", a2, None), ("C", None, None)], NOW, prev_pct=50.0)
    assert roll["n"] == 3 and roll["audited"] == 2 and roll["complete"] == 1
    assert roll["pct_complete"] == 33.3 and roll["prev_pct"] == 50.0
    assert roll["by_code"] == {"bs.missing": 1, "never_audited": 1}
    assert roll["unfixable"] == {"cf.missing": 1}
    assert [w["symbol"] for w in roll["worst"]] == ["C", "B"]


def test_warm_universe_orders_by_deficit_then_age():
    ages = {"BIG": "2026-08-01T00:00:00", "SMALL": "2026-07-01T00:00:00",
            "NEW": "", "FRESH": "2026-09-14T00:00:00"}
    out = fu.warm_universe(ages, priority=[], now=NOW, cap=5,
                           deficit={"BIG": 3, "SMALL": 1, "NEW": fa.INF})
    assert out == ["NEW", "BIG", "SMALL"]  # FRESH skipped by the 7-day gate


def test_write_rollup_keeps_day_over_day_prev(monkeypatch):
    def run(stored):
        posted = []

        def sb(method, path, **kw):
            if method == "POST":
                posted.extend(kw["json"])
                return None
            return [{"value": stored}] if "fund_audit" in path else []

        fu.write_rollup(sb, {"A": audit(*complete_stock())}, {}, NOW)
        return posted[0]["value"]["prev_pct"]

    # yesterday's rollup: its pct becomes today's "prev day"
    assert run({"pct_complete": 40.0, "prev_pct": 30.0, "at": "2026-09-14T12:00:00+00:00"}) == 40.0
    # an intra-day rewrite (deep_drain) keeps the day-over-day figure
    assert run({"pct_complete": 45.0, "prev_pct": 40.0, "at": "2026-09-15T10:00:00+00:00"}) == 40.0
    assert run({}) is None


def test_deep_drain_pops_the_queue_and_skips_yahoo_for_nse_only_gaps(monkeypatch):
    done = audit(*complete_stock())
    audits = {"NEW": None, "NSEONLY": {**done, "missing": ["shp.missing"]},
              "OLDFULL": {**done, "missing": ["shp.split", "docs.missing"], "at": "2026-08-01T00:00:00+00:00"},
              "DONE": done}
    gets, fetched = [], []

    def sb(method, path, **kw):
        if method == "GET":
            gets.append(path)
            if path.startswith("screener_metrics"):
                return [{"symbol": s, "lrd": None} for s in audits]
            if "kind=eq.summary" in path:
                return [{"symbol": s, "audit": a} for s, a in audits.items()]
            return []  # no docs rows: every symbol is eligible; no stored rollup
        return None

    monkeypatch.setattr(fu, "deep_fetch",
                        lambda sb, syms, now, nse=True, q_cap=2, yahoo=True: fetched.append((syms, yahoo)) or len(syms))
    monkeypatch.setattr(fu, "_drain", {"at": None, "todo": []})
    assert fu.refresh_deep_drain(sb, NOW, cap=2) == 2
    # deficit order: never-audited first, then the 2-gap symbol; both need Yahoo
    # (never fetched / statements a month old) so they share one deep_fetch call
    assert fetched == [(["NEW", "OLDFULL"], True)]
    reads = len(gets)
    assert fu.refresh_deep_drain(sb, NOW, cap=8) == 1
    assert fetched[-1] == (["NSEONLY"], False)  # NSE-only gap: statements untouched
    assert len(gets) == reads  # the queue served the lap; no rebuild inside 2 h
    assert fu.refresh_deep_drain(sb, NOW, cap=8) == 0 and len(gets) == reads  # drained, and quiet
    assert "DONE" not in [s for syms, _ in fetched for s in syms]


def test_deep_fetch_without_yahoo_re_audits_from_stored_rows(monkeypatch):
    annuals, quarters, shp = complete_stock()
    monkeypatch.setattr(fu, "fetch_statements", lambda sym, now=None: (_ for _ in ()).throw(AssertionError("yahoo called")))
    monkeypatch.setattr(fu, "fetch_chart_deep", lambda sym, now: ([], None))
    monkeypatch.setattr(fu.time, "sleep", lambda s: None)
    posted = []

    def sb(method, path, **kw):
        if method == "POST":
            posted.extend(kw["json"])
            return None
        if method == "GET" and "kind=eq.annual" in path:
            return [{"period": p, "data": d} for p, d in annuals.items()]
        if method == "GET" and "kind=in.(shareholding,docs)" in path:
            return [{"kind": "shareholding", "period": p, "data": d, "updated_at": "x"} for p, d in shp.items()]
        return []

    fu.deep_fetch(sb, ["TCS"], NOW, nse=False, yahoo=False)
    (summary,) = [r for r in posted if r["kind"] == "summary"]
    assert summary["data"]["audit"]["newest_fy"] == "FY2026"  # stored annuals were merged
    assert not [r for r in posted if r["kind"] == "annual"]     # nothing rewritten


def test_explain_lines_name_the_fixer():
    a = audit(*complete_stock())
    a["missing"], a["unfixable"] = ["bs.missing", "shp.split"], []
    lines = fa.explain("X", a, NOW)
    assert any("bs.missing" in l and "Yahoo" in l for l in lines)
    assert any("shp.split" in l and "NSE" in l for l in lines)
    assert fa.explain("Y", None, NOW)[0].startswith("Y: never audited")


# ---------- deep_fetch writes the verdict and applies the junk rule ----------

def test_deep_fetch_writes_audit_and_deletes_legacy_zero_rows(monkeypatch):
    annuals, quarters, shp = complete_stock()
    new_a = {p: annuals[p] for p in ("FY2026", "FY2025")}
    new_q = {p: quarters[p] for p in ("2026-06", "2026-03")}
    monkeypatch.setattr(fu, "fetch_statements", lambda sym, now=None: (new_a, new_q, {"shares": 1e9}))
    monkeypatch.setattr(fu, "fetch_chart_deep", lambda sym, now: ([100.0] * 13, 3.0))
    monkeypatch.setattr(fu.time, "sleep", lambda s: None)
    calls = []

    def sb(method, path, **kw):
        calls.append((method, path))
        if method == "GET" and "kind=eq.annual" in path:
            return [{"period": p, "data": {**annuals[p], "src": "kaggle"}}
                    for p in annuals if p < "FY2025"] + \
                   [{"period": "FY1998", "data": {"src": "yahoo", "sales": 0, "net_profit": 0, "eps": 0}}]
        if method == "GET" and "kind=eq.quarter" in path:
            return [{"period": p, "src": "kaggle", "sales": quarters[p]["sales"], "net_profit": 1,
                     "eps": 1.0, "op_profit": quarters[p]["op_profit"], "expenses": 1, "interest": 1}
                    for p in quarters if p < "2026-03"] + \
                   [{"period": "2023-03", "src": "yahoo", "sales": 0, "net_profit": 0, "eps": 0,
                     "op_profit": None, "expenses": None, "interest": None}]
        if method == "GET" and "kind=in.(shareholding,docs)" in path:
            return [{"kind": "shareholding", "period": p, "data": d, "updated_at": "2026-09-01T00:00:00+00:00"}
                    for p, d in shp.items()] + \
                   [{"kind": "docs", "period": "latest", "data": {}, "updated_at": "2026-09-10T00:00:00+00:00"}]
        if method == "POST":
            return None
        return []

    fu.deep_fetch(sb, ["TCS"], NOW, nse=False)
    deletes = [p for m, p in calls if m == "DELETE"]
    assert deletes == ["fundamentals?symbol=eq.TCS&kind=eq.annual&period=eq.FY1998",
                       "fundamentals?symbol=eq.TCS&kind=eq.quarter&period=eq.2023-03"]
    assert [c for c in calls if c[0] == "POST"], "summary upsert happened"


def test_deep_fetch_summary_carries_audit(monkeypatch):
    annuals, quarters, shp = complete_stock()
    monkeypatch.setattr(fu, "fetch_statements", lambda sym, now=None: (annuals, quarters, {}))
    monkeypatch.setattr(fu, "fetch_chart_deep", lambda sym, now: ([], None))
    monkeypatch.setattr(fu.time, "sleep", lambda s: None)
    posted = []

    def sb(method, path, **kw):
        if method == "POST":
            posted.extend(kw["json"])
            return None
        if method == "GET" and "kind=in.(shareholding,docs)" in path:
            return [{"kind": "shareholding", "period": p, "data": d, "updated_at": "x"} for p, d in shp.items()]
        return []

    fu.deep_fetch(sb, ["M&M"], NOW, nse=False)
    (summary,) = [r for r in posted if r["kind"] == "summary"]
    a = summary["data"]["audit"]
    assert a["missing"] == ["docs.missing"] and a["docs_at"] is None  # Yahoo-only pass never read docs
    assert a["issues"] == [] and a["newest_q"] == "2026-06"
