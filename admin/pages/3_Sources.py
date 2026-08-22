"""Sources: health, on/off, add / edit / delete, test-fetch a feed from here."""
from common import *  # noqa: F401,F403

gate("Sources")
run = pipeline_mod()
st.markdown("### Sources")

TYPES = ["rss", "google_news_query", "nse", "bse", "sebi", "rbi", "youtube",
         "gnews_api", "newsdata", "marketaux"]  # migration 011 CHECK (was 007)
sources = sb("GET", "sources?select=*&order=name")
by_name = {s["name"]: s for s in sources}
day = iso_hours_ago(24)
per_source = Counter(r["source_name"] for r in sb_all(f"stories?select=source_name&created_at=gte.{day}"))
published = Counter(r["source_name"] for r in
                    sb_all(f"stories?select=source_name&created_at=gte.{day}&status=in.(approved,pending)"))

# ---------- health ----------
st.markdown("**HEALTH** — last fetch, and what each source actually yielded in 24 h")
active = [s for s in sources if s["is_active"]]
stale = [s for s in active if not s["last_fetched_at"] or run_age(s, "last_fetched_at") > 3 * 3600]
silent = [s for s in active if s not in stale and per_source[s["name"]] == 0]
st.markdown(pill(f"{len(active)}/{len(sources)} on", True, DIM)
            + pill(f"{len(stale)} stale (>3 h)", not stale)
            + pill(f"{len(silent)} fetching but yielding nothing", True, AMBER if silent else DIM),
            unsafe_allow_html=True)
st.dataframe([{"name": s["name"], "type": s["type"], "auth": s["authority"],
               "on": "on" if s["is_active"] else "off",
               "last fetch": ("off" if not s["is_active"] else ago(s["last_fetched_at"]) + " ago"),
               "items 24h": per_source[s["name"]], "published 24h": published[s["name"]],
               "state": ("stale" if s in stale else "silent" if s in silent else
                         "off" if not s["is_active"] else "ok")}
              for s in sources], hide_index=True, width="stretch", height=420)

# ---------- edit grid ----------
st.markdown("**EDIT** — flip on/off, change authority, fix a feed URL. A retired source is re-probed every 12 h anyway.")
edited = st.data_editor(
    [{"id": s["id"], "name": s["name"], "type": s["type"], "feed_url": s.get("feed_url") or "",
      "authority": s["authority"], "is_active": s["is_active"]} for s in sources],
    disabled=["id", "name"], hide_index=True, key="src_grid", height=420, width="stretch",
    column_config={"type": st.column_config.SelectboxColumn(options=TYPES),
                   "authority": st.column_config.NumberColumn(min_value=1, max_value=10, step=1),
                   "feed_url": st.column_config.TextColumn(width="large")})
if st.button("Save changes", type="primary"):
    n = 0
    for before, after in zip(sources, edited):
        patch = {k: after[k] for k in ("type", "feed_url", "authority", "is_active")
                 if (before.get(k) or "") != (after[k] or "")}
        if patch:
            sb("PATCH", f"sources?id=eq.{before['id']}", json=patch)
            n += 1
    st.success(f"{n} source(s) updated")
    st.rerun()

# ---------- add ----------
with st.expander("Add a source"):
    with st.form("add_src"):
        a1, a2 = st.columns([2, 1])
        name = a1.text_input("Name")
        typ = a2.selectbox("Type", TYPES)
        feed_url = st.text_input("Feed URL / query", help="RSS url, Google News query, or YouTube channel feed")
        auth = st.slider("Authority", 1, 10, 6, help="8+ can alert solo after 5 min; 10 = primary source")
        if st.form_submit_button("Add", type="primary") and name.strip():
            sb("POST", "sources", json={"name": name.strip(), "type": typ, "feed_url": feed_url.strip() or None,
                                        "authority": auth, "is_active": True})
            st.rerun()

# ---------- test fetch / delete ----------
st.markdown("**ONE SOURCE** — test the fetcher from here, or delete it")
pick = st.selectbox("Source", list(by_name), label_visibility="collapsed")
s = by_name[pick]
t1, t2, _ = st.columns([1, 1, 4])
if t1.button("Test fetch", type="primary"):
    with st.spinner(f"fetching {pick} …"):
        try:
            fetcher = run.fetch_videos if s["type"] == "youtube" else run.FETCHERS.get(s["type"], run.fetch_items)
            t0 = time.monotonic()
            items = fetcher(s)
            st.success(f"{len(items)} item(s) in {time.monotonic() - t0:.1f}s")
            for i in items[:5]:
                st.markdown(f"- {escape(str(i.get('headline') or i.get('title') or i))[:140]}  "
                            f"<span style='color:{DIM}'>{i.get('published_at') or ''}</span>",
                            unsafe_allow_html=True)
        except Exception as e:
            st.error(f"{type(e).__name__}: {e}")
sure = t2.checkbox("confirm delete", key="del_sure")
if t2.button("Delete source", disabled=not sure):
    sb("DELETE", f"sources?id=eq.{s['id']}")  # stories keep source_name text, nothing cascades
    st.rerun()
