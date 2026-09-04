"""Markets: the whole market/fundamentals layer on one page — per-group refresh
status (from the app_config market_status row market.refresh writes each lap),
on/off per group, run-now, fundamentals coverage/quality, a symbol inspector,
and the read-only registry of code-defined market sources."""
import re

from common import *  # noqa: F401,F403

run = pipeline_mod()
import market as mkt  # noqa: E402  (pipeline/ on sys.path after pipeline_mod)
import fundamentals as fnd  # noqa: E402
import ops  # noqa: E402

# groups safe to run from this machine: NSE is Akamai-blocked locally, and the
# deep fetch lanes take minutes-to-hours — those stay CI-only.
RUN_NOW = [g for g, _ in mkt.GROUPS if g not in ("nse", "deep_new", "deep_warm", "fundamentals")]

status = cfg("market_status")
groups_st = status.get("groups") or {}
pc = cfg("pipeline")
off = list(pc.get("groups_off") or [])
failing = [g for g, s in groups_st.items()
           if g not in off and not s.get("ok")
           and (s.get("fails", 0) >= ops.GROUP_FAILS or s.get("daily"))]
scr = q_try("screener_metrics?select=updated_at&order=updated_at.desc&limit=1")
scr_age = ago(scr[0]["updated_at"]) if scr else "never"

header("Markets", "Every refresh group, the fundamentals data behind the screener, and where it all comes from.",
       [pill(f"{len(failing)} group(s) failing", not failing),
        pill(f"{len(off)} disabled", not off, AMBER if off else DIM),
        pill(f"screener rebuilt {scr_age} ago", True, DIM)])

tab_g, tab_c, tab_i, tab_s = st.tabs(["Groups", "Coverage", "Symbol inspector", "Sources"])


def cadence(g):
    if g in mkt.DAILY_SLOT:
        hh, mm = mkt.DAILY_SLOT[g]
        return f"daily {hh:02d}:{mm:02d} IST"
    if g in ("equity", "index"):
        return "15 m (mkt hrs) / 60 m"
    return f"{mkt.INTERVAL[g]} m" if g in mkt.INTERVAL else "daily"


# ---------- groups ----------
with tab_g:
    st.dataframe([{"group": g,
                   "state": ("off" if g in off else
                             "ok" if (s or {}).get("ok") else
                             "FAIL" if s else "no data yet"),
                   "cadence": cadence(g),
                   "last attempt": ago(s.get("ts")) + " ago" if s else "—",
                   "last success": ago(s.get("ok_ts")) + " ago" if s and s.get("ok_ts") else "—",
                   "fails": (s or {}).get("fails", 0) or "",
                   "error": ((s or {}).get("err") or "")[:120]}
                  for g, _ in mkt.GROUPS for s in [groups_st.get(g)]],
                 hide_index=True, width="stretch", height=600)
    st.caption("Status is written by the CI pipeline each lap. 'no data yet' = the resident "
               "process restarted and that group's slot has not come up since.")

    section("Disable groups", "skipped by the pipeline until re-enabled — the coarse market switch stays on")
    picked = st.multiselect("Disabled groups", [g for g, _ in mkt.GROUPS], default=off,
                            label_visibility="collapsed")
    if picked != off and st.button("Save", type="primary", icon=":material/save:"):
        cfg_save("pipeline", {**pc, "groups_off": picked})
        refresh()

    section("Run a group now", "in-process, writes to the live tables — same code CI runs")
    r1, r2, _ = st.columns([2, 1, 3])
    g = r1.selectbox("Group", RUN_NOW, label_visibility="collapsed")
    if r2.button("Run", type="primary", icon=":material/play_arrow:"):
        with st.spinner(f"running {g} …"):
            try:
                t0 = time.monotonic()
                n = dict(mkt.GROUPS)[g](run.sb, datetime.now(timezone.utc))
                st.success(f"{g}: {n} row(s) in {time.monotonic() - t0:.1f}s")
                st.cache_data.clear()
            except Exception as e:  # noqa: BLE001
                st.error(f"{type(e).__name__}: {e}")
    st.caption("nse / deep_new / deep_warm / fundamentals are CI-only: NSE blocks this machine "
               "and the deep lanes take minutes-to-hours. They converge on their own schedule.")

# ---------- coverage ----------
with tab_c:
    cut = (datetime.now(timezone.utc) - timedelta(days=fnd.DEEP_MAX_AGE_D)).strftime("%Y-%m-%dT%H:00:00Z")
    c = counts(("companies?select=id",
                "fundamentals?select=symbol&kind=eq.summary",
                f"fundamentals?select=symbol&kind=eq.summary&updated_at=lt.{cut}",
                "fundamentals?select=symbol&kind=eq.annual",
                "fundamentals?select=symbol&kind=eq.quarter",
                "fundamentals?select=symbol&kind=eq.shareholding",
                "screener_metrics?select=symbol",
                "screener_metrics?select=symbol&pe=is.null",
                "screener_metrics?select=symbol&pb=is.null",
                "screener_metrics?select=symbol&roe=is.null",
                "fundamentals?select=symbol&kind=eq.annual&data->>src=eq.kaggle",
                "fundamentals?select=symbol&kind=eq.annual&data->>src=eq.yahoo",
                "fundamentals?select=symbol&kind=eq.annual&data->>src=eq.nse"))
    vals = list(c.values())
    n_co, n_sum, n_stale, n_ann, n_q, n_shp, n_scr, n_pe, n_pb, n_roe, n_kag, n_yah, n_nse = vals
    kpis([("Companies", n_co, "NSE equity master", BLUE),
          ("With summary", n_sum, f"{n_sum * 100 // max(n_co, 1)}% of universe", GREEN),
          ("Warm backlog", n_stale, f"summary older than {fnd.DEEP_MAX_AGE_D} d "
                                    f"(deep_warm drains {fnd.WARM_CAP}/day)",
           AMBER if n_stale else GREEN),
          ("Screener rows", n_scr, f"rebuilt {scr_age} ago", GREEN)])
    section("Statement rows", "history accumulates forever; src says who provided each year")
    kv_rows([("annual rows", f"{n_ann}  (kaggle {n_kag} · yahoo {n_yah} · nse {n_nse})"),
             ("quarter rows", n_q), ("shareholding rows", n_shp)])
    section("Screener nulls", "symbols that silently drop out of screens on these metrics")
    kv_rows([("pe null", f"{n_pe} — stale TTM: needs all 4 recent quarters (NSE XBRL drains the holes)"),
             ("pb null", n_pb), ("roe null", n_roe)])
    section("Fetch failures", "process-lifetime tallies from the current CI run (reset on restart)")
    fund = status.get("fund") or {}
    if fund:
        kv_rows(sorted(fund.items()))
        note("basis_drop counts symbols whose Yahoo statements were rejected by the basis gate "
             "(standalone vs consolidated) — expected for ~35% of the market; NSE XBRL fills those.", DIM)
    else:
        st.caption("no market_status row yet — lands after the next CI lap on the new pipeline code")

# ---------- symbol inspector ----------
with tab_i:
    sym = st.text_input("NSE symbol", placeholder="RELIANCE, TCS, 360ONE …").strip().upper()
    if sym and not re.match(r"^[A-Z0-9][A-Z0-9&-]{0,19}$", sym):
        st.error("not a valid NSE symbol")
    elif sym:
        qs = quote(sym, safe="")
        rows = sb_all(f"fundamentals?select=kind,period,updated_at,data&symbol=eq.{qs}"
                      "&order=kind.asc,period.desc")
        met = q_try(f"screener_metrics?select=*&symbol=eq.{qs}")
        if not rows:
            st.warning(f"no fundamentals rows for {sym} — open its stock page in the app to queue "
                       "a deep fetch, or refresh it below")
        else:
            summary = next((r["data"] for r in rows if r["kind"] == "summary"), {})
            by_kind = Counter(r["kind"] for r in rows)
            st.markdown(pill(f"{len(rows)} rows", True, DIM)
                        + "".join(pill(f"{k} {n}", True, DIM) for k, n in sorted(by_kind.items()))
                        + pill("reported shares" if summary.get("shares") else "NO reported shares",
                               bool(summary.get("shares")))
                        + pill(f"updated {ago(max(r['updated_at'] for r in rows))} ago", True, DIM),
                        unsafe_allow_html=True)
            if met:
                section("screener_metrics", "what the screener serves for this symbol")
                kv_rows([(k, met[0].get(k) if met[0].get(k) is not None else "—")
                         for k in ("price", "mcap_cr", "pe", "pb", "div_yield", "roe", "roce",
                                   "de", "opm", "promoter_pct", "updated_at")])
            section("Annual history", "src = who provided the year; a yahoo/kaggle mismatch is what the basis gate catches")
            ann = [r for r in rows if r["kind"] == "annual"]
            st.dataframe([{"period": r["period"], "src": r["data"].get("src"),
                           "sales": r["data"].get("sales"), "np": r["data"].get("np"),
                           "eps": r["data"].get("eps"), "op_profit": r["data"].get("op_profit")}
                          for r in ann], hide_index=True, width="stretch")
            with st.expander("quarters"):
                st.dataframe([{"period": r["period"], "src": r["data"].get("src"),
                               "sales": r["data"].get("sales"), "np": r["data"].get("np"),
                               "eps": r["data"].get("eps")}
                              for r in rows if r["kind"] == "quarter"], hide_index=True, width="stretch")
            with st.expander("raw summary row"):
                st.code(jdump(summary), language="json")
        b1, b2, _ = st.columns([1, 1, 3])
        if b1.button("Refresh this symbol (Yahoo only)", type="primary", icon=":material/refresh:",
                     help="deep_fetch in-process; NSE pieces are Akamai-blocked here and drain via CI"):
            with st.spinner(f"deep-fetching {sym} …"):
                try:
                    n = fnd.deep_fetch(run.sb, [sym], datetime.now(timezone.utc), nse=False)
                    st.success(f"{n} row(s) upserted")
                    st.cache_data.clear()
                except Exception as e:  # noqa: BLE001
                    st.error(f"{type(e).__name__}: {e}")
        if b2.button("Probe NSE shapes (CI)", icon=":material/cloud_sync:",
                     help="dispatches probe.yml — read the output in the GitHub Actions log"):
            try:
                gh("POST", "/actions/workflows/probe.yml/dispatches", json={"ref": "main"})
                st.success("dispatched — output in the probe.yml run log on GitHub")
            except Exception as e:  # noqa: BLE001
                st.error(f"{e}")

# ---------- sources ----------
with tab_s:
    st.markdown("<div class='fs-muted'>Market/fundamentals sources are code (parsers in market.py / "
                "fundamentals.py), not DB rows — this is their live status. News feeds are edited on "
                "the Sources page.</div>", unsafe_allow_html=True)
    ages = {}
    for kind in ops.MAX_QUOTE_AGE_H:
        r = q_try(f"quotes?select=updated_at&kind=eq.{kind}&order=updated_at.desc&limit=1")
        if r:
            ages[kind] = ago(r[0]["updated_at"])
    blobs = {r["key"]: ago(r["updated_at"]) for r in q_try("market_blobs?select=key,updated_at")}
    st.dataframe([
        {"source": "Yahoo spark", "feeds": "index/equity/fx/commodity quotes",
         "freshest": ", ".join(f"{k} {ages[k]}" for k in ("index", "equity", "fx") if k in ages) or "—"},
        {"source": "Yahoo quoteSummary + chart", "feeds": "fundamentals statements (basis-gated), dividends, technicals",
         "freshest": "see Coverage tab"},
        {"source": "NSE API (XBRL results, shareholding, docs, blobs)", "feeds": "primary statements + " + ", ".join(sorted(blobs)) if blobs else "primary statements + blobs",
         "freshest": ", ".join(f"{k} {v}" for k, v in sorted(blobs.items())[:4]) or "—"},
        {"source": "CoinGecko", "feeds": "crypto quotes", "freshest": ages.get("crypto", "—")},
        {"source": "mfapi.in", "feeds": "MF NAVs", "freshest": ages.get("mf", "—")},
        {"source": "RBI homepage (Current Rates)", "feeds": "benchmark G-Sec yields, policy rates, T-bill cut-offs",
         "freshest": blobs.get("bonds", "—")},
        {"source": "FRED (keyed)", "feeds": "macro series", "freshest": ages.get("macro", "—")},
        {"source": "Wikidata SPARQL", "feeds": "company alias enrichment (daily)", "freshest": "—"},
        {"source": "Kaggle dump (static)", "feeds": "deep annual history, one-time backfill (src=kaggle)",
         "freshest": "static"},
    ], hide_index=True, width="stretch")
    page_link("sources", "→ Sources · the editable news feeds", icon=":material/rss_feed:")

auto_refresh()  # status page: heals itself while the tab is open
