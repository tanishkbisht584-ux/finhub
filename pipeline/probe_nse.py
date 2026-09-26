"""One-shot NSE endpoint probe (run from a GitHub runner via the probe
workflow — NSE Akamai-blocks the dev machine). Prints the shapes step B
needs: shareholding-master row keys + SHP XBRL element names, the
financial-results list + results XBRL element names, the credit-rating
endpoint's raw answer, annual-reports/announcements samples. No writes.
"""
import json

from fundamentals import parse_ix_facts
from market import NSE_API, nse_session

SYM = "RELIANCE"

s = nse_session()


def get(path, **params):
    r = s.get(NSE_API + path, params=params, timeout=25)
    print(f"[{r.status_code}] {r.url[:160]}")
    if "json" in r.headers.get("content-type", ""):
        return r.json()
    raise RuntimeError(f"non-JSON ({r.text[:120]!r})")


def rows_of(j):
    return (j.get("data") if isinstance(j, dict) else j) or []


def show(label, fn):
    print(f"\n===== {label} =====")
    try:
        fn()
    except Exception as e:
        print(f"FAILED: {e}")


def xbrl_elements(row):
    url = next((v for k, v in row.items() if "xbrl" in k.lower() and v), None)
    print("xbrl url:", url)
    if not url:
        return
    xml = s.get(url, timeout=25).text
    facts = parse_ix_facts(xml)
    print(f"{len(facts)} ix facts (inline)")
    # plain-XBRL instance: dump element localnames with contextRef + first value
    import re
    seen = {}
    for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
        name, ctx, val = m.group(1), m.group(2), m.group(3).strip()
        if name not in seen and val:
            seen[name] = (ctx, val)
    print(f"{len(seen)} plain-XBRL elements; name = (context, value):")
    for name, (ctx, val) in list(seen.items())[:150]:
        print(f"  {name} = ({ctx[:40]}, {val[:50]})")
    print("raw head:", xml[:1200].replace(chr(10), " ")[:1200])


def shp():
    rows = rows_of(get("corporate-share-holdings-master", index="equities", symbol=SYM))
    print("rows:", len(rows), "| first row keys:", sorted(rows[0]) if rows else None)
    if not rows:
        return
    url = rows[0].get("xbrl")
    print("xbrl url:", url)
    xml = s.get(url, timeout=25).text
    # every (context, value) for the two elements the split needs — the SHP
    # taxonomy repeats one element per category context
    import re
    for el in ("ShareholdingAsAPercentageOfTotalNumberOfShares", "NumberOfShareholders"):
        print(f"\nall contexts of {el}:")
        for m in re.finditer(
                rf"<[\w.-]+:{el}[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
            print(f"  {m.group(1)} = {m.group(2).strip()}")


def results():
    rows = rows_of(get("corporates-financial-results", index="equities",
                       symbol=SYM, period="Quarterly"))
    print("rows:", len(rows))
    con = next((r for r in rows if "Consolidated" == r.get("consolidated")), rows[0] if rows else None)
    if not con:
        return
    print("consolidated row:", json.dumps(con)[:700])
    xbrl_elements(con)
    link = con.get("resultDetailedDataLink")
    if link:
        r = s.get(link, timeout=25)
        print(f"\nresultDetailedDataLink [{r.status_code}] {r.headers.get('content-type')}")
        print(r.text[:1500])


def results_listing():
    """15 Sep 2026: every NSE-sourced quarter in the table is 2024-09 or
    2024-12 and no 2025+ filing was ever picked — print the newest listing
    rows in full (Quarterly + Annual, an industrial + a bank) and the element
    names of a 2025+ filing so pick_results_filings/RESULTS_ELEMENTS can be
    fixed against the real shape."""
    import re
    from market import parse_nse_date

    def when(r):
        return parse_nse_date(r.get("toDate")) or parse_nse_date("01-Jan-1900")

    for sym in ("RELIANCE", "HDFCBANK"):
        for period in ("Quarterly", "Annual"):
            j = get("corporates-financial-results", index="equities", symbol=sym, period=period)
            rows = rows_of(j)
            print(f"\n-- {sym} {period}: {len(rows)} rows; top-level keys:",
                  sorted(j) if isinstance(j, dict) else type(j).__name__)
            if not rows:
                continue
            print("   row keys:", sorted(rows[0]))
            rows = sorted(rows, key=when, reverse=True)
            for r in rows[:6]:
                print("  ", json.dumps(r))
            newest = next((r for r in rows if when(r).year >= 2025), None)
            if newest and period == "Quarterly":
                urls = {k: v for k, v in newest.items() if isinstance(v, str) and v.startswith("http")}
                print("   url-ish fields of the newest 2025+ row:", json.dumps(urls))
                for k, u in urls.items():
                    if any(t in u.lower() for t in (".xml", "xbrl", ".zip")):
                        print(f"   fetching {k}: {u}")
                        xml = s.get(u, timeout=25).text
                        seen = {}
                        for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
                            name, ctx, val = m.group(1), m.group(2), m.group(3).strip()
                            if name not in seen and val and re.search(
                                    r"Revenue|Income|Profit|Tax|Expense|Interest|Deposit|Advance|Share|Earning", name):
                                seen[name] = (ctx, val)
                        print(f"   {len(seen)} matching elements:")
                        for name, (ctx, val) in list(seen.items())[:120]:
                            print(f"     {name} = ({ctx[:40]}, {val[:40]})")
                        print("   raw head:", xml[:600].replace(chr(10), " "))
                        break
    # v2 (same day): the legacy listing ends at Dec-2024 for everyone — SEBI's
    # integrated filing regime moved newer results to a separate feed. Print
    # its shape for an industrial and a bank, a 2026 filing's elements, the
    # bank taxonomy's elements, and the results-comparision summary feed.
    for sym in ("RELIANCE", "HDFCBANK"):
        for params in ({"period": "Quarterly"}, {"period_ended": "Quarterly"}, {}):
            try:
                j = get("integrated-filing-results", index="equities", symbol=sym,
                        type="Integrated Filing- Financials", **params)
            except Exception as e:
                print(f"\n-- {sym} integrated {params}: FAILED {e}")
                continue
            rows = rows_of(j)
            print(f"\n-- {sym} integrated {params}: {len(rows)} rows; top-level keys:",
                  sorted(j) if isinstance(j, dict) else type(j).__name__)
            if rows:
                print("   row keys:", sorted(rows[0]))
                for r in rows[:4]:
                    print("  ", json.dumps(r)[:900])
                break
        # element dump of the newest real xml in that feed
        for r in rows:
            u = (r.get("xbrl") or "").strip()
            if u.lower().endswith(".xml"):
                print(f"   fetching integrated xbrl: {u}")
                xml = s.get(u, timeout=25).text
                seen = {}
                for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
                    name, ctx, val = m.group(1), m.group(2), m.group(3).strip()
                    if name not in seen and val and re.search(
                            r"Revenue|Income|Profit|Tax|Expense|Interest|Deposit|Advance|Share|Earning|Provision|Deprec", name):
                        seen[name] = (ctx, val)
                print(f"   {len(seen)} matching elements:")
                for name, (ctx, val) in list(seen.items())[:150]:
                    print(f"     {name} = ({ctx[:40]}, {val[:40]})")
                ctxs = re.findall(r"<xbrli:context id=\"([^\"]+)\">.*?<xbrli:startDate>([^<]+)</xbrli:startDate>\s*"
                                  r"<xbrli:endDate>([^<]+)</xbrli:endDate>", xml, re.S)
                print("   duration contexts:", ctxs[:12])
                print("   raw head:", xml[:500].replace(chr(10), " "))
                break
    # the legacy BANKING taxonomy (HDFCBANK Dec-2024 filing): element names
    rows = rows_of(get("corporates-financial-results", index="equities", symbol="HDFCBANK", period="Quarterly"))
    con = next((r for r in rows if r.get("consolidated") == "Consolidated" and (r.get("xbrl") or "").endswith(".xml")), None)
    if con:
        print(f"\n-- HDFCBANK legacy bank xbrl: {con.get('toDate')} {con['xbrl']}")
        xml = s.get(con["xbrl"], timeout=25).text
        seen = {}
        for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
            name, ctx, val = m.group(1), m.group(2), m.group(3).strip()
            if name not in seen and val:
                seen[name] = (ctx, val)
        print(f"   {len(seen)} elements:")
        for name, (ctx, val) in list(seen.items())[:200]:
            print(f"     {name} = ({ctx[:40]}, {val[:40]})")
        ctxs = re.findall(r"<xbrli:context id=\"([^\"]+)\">.*?<xbrli:startDate>([^<]+)</xbrli:startDate>\s*"
                          r"<xbrli:endDate>([^<]+)</xbrli:endDate>", xml, re.S)
        print("   duration contexts:", ctxs[:12])
    # results-comparision: NSE's own last-quarters P&L summary
    for sym in ("RELIANCE", "HDFCBANK"):
        try:
            j = get("results-comparision", symbol=sym)
            print(f"\n-- {sym} results-comparision: type={type(j).__name__} keys={sorted(j) if isinstance(j, dict) else None}")
            print("  ", json.dumps(j)[:2500])
        except Exception as e:
            print(f"\n-- {sym} results-comparision FAILED {e}")


def ratings():
    for path in ("corporate-credit-rating", "corporates-credit-rating"):
        r = s.get(NSE_API + path, params={"index": "equities", "symbol": SYM}, timeout=25)
        print(f"[{r.status_code}] {path}: {r.text[:500]!r}")


def reports_announcements():
    rep = rows_of(get("annual-reports", index="equities", symbol=SYM))
    print("annual-reports first:", json.dumps(rep[0])[:300] if rep else None)
    ann = rows_of(get("corporate-announcements", index="equities", symbol=SYM))
    print("announcements rows:", len(ann))
    print("announcements first keys:", sorted(ann[0]) if ann else None)


def market_shapes():
    """12 Sep 2026: F&O + announcements shapes for the Markets-tab tables —
    the live fno blob had ltp/pct null on every OI row and hi52/lo52 = 0."""
    def head(label, j, n=2, keys=None):
        rows = market_rows(j)
        print(f"\n-- {label}: {len(rows)} rows; top-level keys: {sorted(j) if isinstance(j, dict) else type(j).__name__}")
        for r in rows[:n]:
            print("  ", json.dumps({k: r.get(k) for k in keys} if keys else r)[:900])
        if rows:
            print("   row keys:", sorted(rows[0]))
        return rows

    head("oi-spurts", get("live-analysis-oi-spurts-underlyings"))
    for idx in ("high", "low"):
        j = get("live-analysis-52Week", index=idx)
        print(f"\n-- 52Week {idx}: type={type(j).__name__} keys={sorted(j) if isinstance(j, dict) else None}")
        print("  ", json.dumps(j)[:700])
    head("variations gainers", get("live-analysis-variations", index="gainers"))
    head("F&O securities", get("equity-stockIndices", index="SECURITIES IN F&O"))
    ann = get("corporate-announcements", index="equities")
    rows = head("announcements (all)", ann, n=3,
                keys=["symbol", "desc", "an_dt", "sm_name", "attchmntFile", "sort_date", "bd_dt"])
    dts = sorted(str(r.get("an_dt") or "") for r in rows)
    print("   an_dt span:", dts[:1], dts[-1:])


def market_rows(j):
    from market import _rows
    return [r for r in _rows(j) if isinstance(r, dict)]


def tape_shapes():
    """20 Sep 2026 (Phase 4, MC stock page): per-symbol tape. Every endpoint
    isolated (a 403 on one must not hide the rest); the quote API wants the
    cookies the quote PAGE sets, so that page is visited first."""
    def dump(label, j, n=1400):
        print()
        print(f"-- {label}: type={type(j).__name__} keys={sorted(j) if isinstance(j, dict) else None}")
        print("  ", json.dumps(j)[:n])

    def attempt(label, fn):
        try:
            fn()
        except Exception as e:
            print(f"-- {label}: FAILED {str(e)[:200]}")

    for url in ("https://www.nseindia.com/get-quotes/equity?symbol=TCS",
                "https://www.nseindia.com/get-quotes/derivatives?symbol=TCS"):
        try:
            r = s.get(url, timeout=15)
            print(f"[{r.status_code}] warm-up {url} cookies={sorted(s.cookies.keys())}")
        except Exception as e:
            print("warm-up failed", e)

    def quote(sym):
        q = get("quote-equity", symbol=sym)
        dump(f"quote-equity {sym}", q, 600)
        for k in ("priceInfo", "securityInfo", "preOpenMarket", "industryInfo", "metadata"):
            if isinstance(q, dict) and k in q:
                print(f"   {k}:", json.dumps(q[k])[:900])
    attempt("quote-equity", lambda: quote("TCS"))
    attempt("trade_info", lambda: dump("trade_info TCS", get("quote-equity", symbol="TCS", section="trade_info"), 2500))

    def deriv():
        d = get("quote-derivative", symbol="TCS")
        dump("quote-derivative TCS", d, 600)
        if isinstance(d, dict):
            print("   info:", json.dumps(d.get("info"))[:300], "| fut_timestamp:", d.get("fut_timestamp"), "| opt_timestamp:", d.get("opt_timestamp"))
            st = d.get("stocks") or []
            print("   stocks rows:", len(st))
            kinds = {}
            for r in st:
                md = r.get("metadata") or {}
                kinds.setdefault(md.get("instrumentType"), []).append(r)
            for k, rows in kinds.items():
                print(f"   [{k}] {len(rows)} rows; first:", json.dumps(rows[0])[:1500])
            print("   strikePrices:", json.dumps(d.get("strikePrices"))[:300], "| expiryDates:", json.dumps(d.get("expiryDates"))[:300])
    attempt("quote-derivative", deriv)
    attempt("corporate-actions", lambda: dump("corporate-actions TCS", get("corporate-actions", index="equities", symbol="TCS"), 1500))
    attempt("board-meetings", lambda: dump("board-meetings TCS", get("corporate-board-meetings", index="equities", symbol="TCS"), 1200))
    attempt("option-chain", lambda: dump("option-chain-equities TCS", get("option-chain-equities", symbol="TCS"), 1200))
    attempt("equity-meta", lambda: dump("equity-meta-info TCS", get("equity-meta-info", symbol="TCS"), 800))
    attempt("chart-databyindex", lambda: dump("chart-databyindex TCSEQN", get("chart-databyindex", index="TCSEQN"), 400))


def free_parity():
    """26 Sep 2026: every upstream shape the free-parity plan (P1-P5) assumes,
    printed once from a runner so the parsers are written against reality:
    F&O bhav instrument codes (index contracts), corporate-action feeds,
    balance-sheet XBRL tags (instant contexts), SHP pledge tag, SME series,
    the BSE scrip master."""
    import re
    from collections import Counter
    from datetime import date, datetime, timedelta

    import requests

    from bhav import fetch_fo, fetch_full
    from market import IST

    day = datetime.now(IST).date() - timedelta(days=1)
    fo = full = None
    for _ in range(6):
        if fo is None:
            fo = fetch_fo(day)
        if full is None:
            full = fetch_full(day)
        if fo and full:
            break
        day -= timedelta(days=1)
    print(f"\n-- bhav day {day}: fo rows {len(fo or [])}, full rows {len(full or [])}")
    if fo:
        print("   FinInstrmTp counts:", Counter(r.get("FinInstrmTp") for r in fo).most_common())
        for typ in ("IDF", "IDO", "STF", "STO"):
            row = next((r for r in fo if r.get("FinInstrmTp") == typ), None)
            print(f"   first {typ}:", json.dumps(row)[:600] if row else None)
        idx = [r for r in fo if r.get("TckrSymb") in ("NIFTY", "BANKNIFTY", "FINNIFTY", "MIDCPNIFTY")]
        by = {}
        for r in idx:
            by.setdefault((r.get("TckrSymb"), r.get("FinInstrmTp")), set()).add(r.get("XpryDt"))
        for k, v in sorted(by.items()):
            print(f"   {k}: {len(v)} expiries {sorted(v)[:8]}")
        print("   distinct TckrSymb:", len({r.get("TckrSymb") for r in fo}))
    if full:
        print("   SERIES counts:", Counter(r.get("SERIES") for r in full).most_common())
        sm = next((r for r in full if r.get("SERIES") in ("SM", "ST")), None)
        print("   first SME row:", json.dumps(sm)[:400] if sm else None)
    for u in ("https://nsearchives.nseindia.com/content/equities/SME_EQUITY_L.csv",
              "https://nsearchives.nseindia.com/emerge/corporates/content/SME_EQUITY_L.csv",
              "https://nsearchives.nseindia.com/content/equities/EQUITY_L.csv"):
        try:
            r = requests.get(u, headers={"User-Agent": "Mozilla/5.0"}, timeout=25)
            print(f"   [{r.status_code}] {u} {len(r.text)} chars: {r.text[:160]!r}")
        except Exception as e:  # noqa: BLE001
            print(f"   FAILED {u}: {e}")

    print("\n-- corporate actions feeds")
    frm = (date.today() - timedelta(days=7)).strftime("%d-%m-%Y")
    to = (date.today() + timedelta(days=45)).strftime("%d-%m-%Y")
    for label, path, params in (
            ("corporates-corporateActions", "corporates-corporateActions", {"index": "equities", "from_date": frm, "to_date": to}),
            ("corporate-board-meetings", "corporate-board-meetings", {"index": "equities"}),
            ("event-calendar", "event-calendar", {"index": "equities", "from_date": frm, "to_date": to}),
            ("corporates-corporateActions (no dates)", "corporates-corporateActions", {"index": "equities"})):
        try:
            j = get(path, **params)
            rows = rows_of(j)
            print(f"   {label}: type={type(j).__name__} rows={len(rows)} top-keys={sorted(j)[:10] if isinstance(j, dict) else None}")
            for r in rows[:3]:
                print("     ", json.dumps(r)[:500])
        except Exception as e:  # noqa: BLE001
            print(f"   {label}: FAILED {e}")
    bse = {"User-Agent": "Mozilla/5.0", "Referer": "https://www.bseindia.com/", "Origin": "https://www.bseindia.com"}
    for label, u, params in (
            ("bse forthcoming corp actions", "https://api.bseindia.com/BseIndiaAPI/api/Corpforthres/w",
             {"scripcode": "", "Fdate": "", "TDate": "", "Purposecode": "", "strSearch": "S",
              "ddlindustrys": "", "ddlcategorys": "E", "segment": "0"}),
            ("bse scrip master", "https://api.bseindia.com/BseIndiaAPI/api/ListofScripData/w",
             {"Group": "", "Scripcode": "", "industry": "", "segment": "Equity", "status": "Active"})):
        try:
            r = requests.get(u, params=params, headers=bse, timeout=30)
            print(f"   {label}: [{r.status_code}] {r.headers.get('content-type', '?')[:30]} {len(r.text)} chars")
            print("     ", r.text[:700].replace("\n", " "))
        except Exception as e:  # noqa: BLE001
            print(f"   {label}: FAILED {e}")

    print("\n-- balance-sheet XBRL tags (instant contexts) + SHP pledge tag")
    for sym in ("RELIANCE", "HDFCBANK"):
        try:
            rows = rows_of(get("integrated-filing-results", index="equities", symbol=sym,
                               type="Integrated Filing- Financials", period="Quarterly"))
        except Exception as e:  # noqa: BLE001
            print(f"   {sym}: listing FAILED {e}")
            continue
        xmls = [(r.get("toDate"), r.get("xbrl")) for r in rows if (r.get("xbrl") or "").lower().endswith(".xml")]
        print(f"   {sym}: {len(rows)} filings, {len(xmls)} with xml; newest: {xmls[:4]}")
        for to_date, u in xmls[:3]:
            try:
                xml = s.get(u, timeout=25).text
            except Exception as e:  # noqa: BLE001
                print(f"     {u}: FAILED {e}")
                continue
            inst = dict(re.findall(r"<xbrli:context id=\"([^\"]+)\">.*?<xbrli:instant>([^<]+)</xbrli:instant>", xml, re.S))
            print(f"     {to_date} {u[-60:]}: {len(inst)} instant contexts {list(inst.items())[:6]}")
            seen = {}
            for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml):
                name, ctx, val = m.group(1), m.group(2), m.group(3).strip()
                if ctx in inst and val and name not in seen:
                    seen[name] = (inst[ctx], val)
            print(f"     {len(seen)} instant-context elements:")
            for name, (d, val) in list(seen.items())[:120]:
                print(f"       {name} = ({d}, {val[:30]})")
            if seen:
                break
    try:
        rows = rows_of(get("corporate-share-holdings-master", index="equities", symbol="RELIANCE"))
        u = rows[0].get("xbrl") if rows else None
        xml = s.get(u, timeout=25).text if u else ""
        names = sorted({m.group(1) for m in re.finditer(r"<(?:[\w.-]+:)?(\w+)[^>]*contextRef=", xml)
                        if re.search(r"Pledg|Encumb", m.group(1))})
        print("   SHP pledge-ish elements:", names)
        for name in names[:6]:
            for m in list(re.finditer(rf"<[\w.-]+:{name}[^>]*contextRef=\"([^\"]+)\"[^>]*>([^<]*)<", xml))[:6]:
                print(f"     {name} [{m.group(1)}] = {m.group(2).strip()}")
    except Exception as e:  # noqa: BLE001
        print(f"   SHP pledge: FAILED {e}")


show("free-parity plan shapes (F&O codes, corp actions, BS tags, pledge, SME, BSE)", free_parity)
show("tape shapes (quote / trade_info / derivative / actions / meetings)", tape_shapes)
show("results listing 2025+ (industrial + bank)", results_listing)
show("market shapes (F&O, 52wk, announcements)", market_shapes)
show("SHP master + XBRL", shp)
show("financial results + XBRL", results)
show("credit ratings raw", ratings)
show("annual reports / announcements", reports_announcements)
print("\nprobe done")
