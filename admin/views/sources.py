"""Sources: health, on/off, add / edit / delete, test-fetch a feed from here."""
from common import *  # noqa: F401,F403

run = pipeline_mod()

TYPES = ["rss", "google_news_query", "nse", "bse", "sebi", "rbi",
         "gnews_api", "newsdata", "marketaux"]  # migration 011 CHECK (was 007)
sources = sb("GET", "sources?select=*&order=name")
by_name = {s["name"]: s for s in sources}
day = iso_hours_ago(24)
per_source = Counter(r["source_name"] for r in sb_all(f"stories?select=source_name&created_at=gte.{day}"))
published = Counter(r["source_name"] for r in
                    sb_all(f"stories?select=source_name&created_at=gte.{day}&status=in.(approved,pending)"))
active = [s for s in sources if s["is_active"]]
stale = [s for s in active if not s["last_fetched_at"] or run_age(s, "last_fetched_at") > 3 * 3600]
silent = [s for s in active if s not in stale and per_source[s["name"]] == 0]

header("Sources", "Every feed the pipeline reads: health, yield, on/off, authority, URLs.",
       [pill(f"{len(active)}/{len(sources)} on", True, DIM), pill(f"{len(stale)} stale (>3 h)", not stale),
        pill(f"{len(silent)} silent (fetching, no items)", True, AMBER if silent else DIM)])
kpis([("Active", f"{len(active)}/{len(sources)}", "", GREEN),
      ("Stale", len(stale), "no fetch in 3 h", RED if stale else GREEN),
      ("Silent", len(silent), "fetched, 0 items in 24 h", AMBER if silent else GREEN),
      ("Items · 24 h", sum(per_source.values()), "after dedupe", BLUE),
      ("Published · 24 h", sum(published.values()), "approved + pending", BLUE)])

tab_h, tab_e, tab_a, tab_t = st.tabs(["Health", "Edit grid", "Add", "Test / delete"])

with tab_h:
    st.dataframe([{"name": s["name"], "type": s["type"], "auth": s["authority"],
                   "on": "on" if s["is_active"] else "off",
                   "last fetch": ("off" if not s["is_active"] else ago(s["last_fetched_at"]) + " ago"),
                   "items 24h": per_source[s["name"]], "published 24h": published[s["name"]],
                   "state": ("stale" if s in stale else "silent" if s in silent else
                             "off" if not s["is_active"] else "ok")}
                  for s in sources], hide_index=True, width="stretch", height=520)
    section("Yield · 24 h", "items per source, top 15")
    html_bars(dict(per_source.most_common(15)), GREEN)

with tab_e:
    st.markdown("<div class='fs-muted'>Flip on/off, change authority, fix a feed URL. A retired source is "
                "re-probed every 12 h anyway.</div>", unsafe_allow_html=True)
    edited = st.data_editor(
        [{"id": s["id"], "name": s["name"], "type": s["type"], "feed_url": s.get("feed_url") or "",
          "authority": s["authority"], "is_active": s["is_active"]} for s in sources],
        disabled=["id", "name"], hide_index=True, key="src_grid", height=520, width="stretch",
        column_config={"type": st.column_config.SelectboxColumn(options=TYPES),
                       "authority": st.column_config.NumberColumn(min_value=1, max_value=10, step=1),
                       "feed_url": st.column_config.TextColumn(width="large")})
    if st.button("Save changes", type="primary", icon=":material/save:"):
        n = 0
        for before, after in zip(sources, edited):
            patch = {k: after[k] for k in ("type", "feed_url", "authority", "is_active")
                     if (before.get(k) or "") != (after[k] or "")}
            if patch:
                sb("PATCH", f"sources?id=eq.{before['id']}", json=patch)
                n += 1
        st.success(f"{n} source(s) updated")
        refresh()

with tab_a:
    with st.form("add_src"):
        a1, a2 = st.columns([2, 1])
        name = a1.text_input("Name")
        typ = a2.selectbox("Type", TYPES)
        feed_url = st.text_input("Feed URL / query", help="RSS url or Google News query")
        auth = st.slider("Authority", 1, 10, 6, help="8+ can alert solo after 5 min; 10 = primary source")
        if st.form_submit_button("Add source", type="primary", icon=":material/add:") and name.strip():
            sb("POST", "sources", json={"name": name.strip(), "type": typ, "feed_url": feed_url.strip() or None,
                                        "authority": auth, "is_active": True})
            refresh()

with tab_t:
    pick = st.selectbox("Source", list(by_name))
    s = by_name[pick]
    st.caption(f"type {s['type']} · authority {s['authority']} · {'on' if s['is_active'] else 'off'} · "
               f"last fetch {ago(s['last_fetched_at'])} ago · {s.get('feed_url') or ''}")
    t1, t2, t3, _ = st.columns([1, 1, 1, 3])
    if t1.button("Test fetch", type="primary", icon=":material/play_arrow:"):
        with st.spinner(f"fetching {pick} …"):
            try:
                fetcher = run.FETCHERS.get(s["type"], run.fetch_items)
                t0 = time.monotonic()
                items = fetcher(s)
                st.success(f"{len(items)} item(s) in {time.monotonic() - t0:.1f}s")
                for i in items[:8]:
                    st.markdown(f"- {escape(str(i.get('headline') or i.get('title') or i))[:140]}  "
                                f"<span class='fs-muted'>{i.get('published_at') or ''}</span>",
                                unsafe_allow_html=True)
            except Exception as e:  # noqa: BLE001
                st.error(f"{type(e).__name__}: {e}")
    if t2.button("Turn off" if s["is_active"] else "Turn on", icon=":material/power_settings_new:"):
        sb("PATCH", f"sources?id=eq.{s['id']}", json={"is_active": not s["is_active"]})
        refresh()
    sure = t3.checkbox("confirm delete", key="del_sure")
    if t3.button("Delete source", disabled=not sure, icon=":material/delete:"):
        sb("DELETE", f"sources?id=eq.{s['id']}")  # stories keep source_name text, nothing cascades
        refresh()
