"""Storage: what is eating the 500 MB free cap, the retention policy that keeps
it flat, one-click flushes, and disk reclaim. Sizes come from storage_stats()
(031, service_role); flush + vacuum go through the Management API token."""
import json

from common import *  # noqa: F401,F403

run = pipeline_mod()
ops = __import__("ops")
TOKEN = bool(mgmt_token())


@st.cache_data(ttl=60, show_spinner=False)
def storage_stats():
    return sb("POST", "rpc/storage_stats", json={}) or {}


try:
    S = storage_stats()
except Exception as e:  # noqa: BLE001
    S = {}
    note(f"storage_stats() unavailable — apply migration 031 from Doctor › Schema. ({e})", RED)

db_mb = float(S.get("db_mb") or 0)
tables = S.get("tables") or []
by_name = {t["name"]: t for t in tables}
stories = S.get("stories") or {}
db_color = GREEN if db_mb < ops.DB_SOFT_MB else AMBER if db_mb < ops.DB_HARD_MB else RED
dead_pct = {t["name"]: (t.get("dead") or 0) / t["rows"] for t in tables if (t.get("rows") or 0) > 0}
worst = max(dead_pct.values(), default=0)

header("Storage",
       "The free plan locks the project read-only over 500 MB. The daily sweep keeps it flat; flush here when it does not.",
       [pill(f"{db_mb:.0f} / {ops.DB_CAP_MB} MB", db_mb < ops.DB_SOFT_MB, db_color),
        pill("token" if TOKEN else "no token", TOKEN, GREEN if TOKEN else RED),
        pill(f"measured {ago(S['at'])} ago" if S.get("at") else "unmeasured", bool(S), DIM)])

kpis([
    ("database", f"{db_mb:.0f} MB", f"of {ops.DB_CAP_MB} · alert at {ops.DB_SOFT_MB}", db_color),
    ("stories", f"{by_name.get('stories', {}).get('total_mb', 0):.0f} MB",
     f"{by_name.get('stories', {}).get('rows', 0):,} rows", BORDER),
    ("dead rows", f"{worst:.0%}", "worst table · reclaim above 25%", AMBER if worst >= ops.DEAD_RATIO else BORDER),
    ("cards", f"{stories.get('approved', 0):,}",
     f"approved · {stories.get('duplicate', 0):,} dup · {stories.get('rejected', 0):,} rejected", BORDER),
])

tab_sizes, tab_policy, tab_flush, tab_reclaim = st.tabs(["Sizes", "Retention policy", "Flush", "Reclaim disk"])

with tab_sizes:
    section("Tables", "rows + dead rows from pg_stat; total includes indexes")
    if tables:
        st.dataframe([{"table": t["name"], "total MB": t["total_mb"], "rows MB": t["heap_mb"],
                       "index MB": t["index_mb"], "rows": t.get("rows"), "dead": t.get("dead"),
                       "dead %": f"{dead_pct.get(t['name'], 0):.0%}",
                       "last vacuum": ago(t["last_vacuum"]) + " ago" if t.get("last_vacuum") else "—"}
                      for t in tables], hide_index=True, width="stretch")
        html_bars({t["name"]: t["total_mb"] for t in tables[:8]}, db_color)
    if stories.get("oldest"):
        kv_rows([("oldest card", ago(stories["oldest"]) + " ago"),
                 ("watchdog", f"alerts at {ops.DB_SOFT_MB} MB, urgent at {ops.DB_HARD_MB} MB; VACUUM FULL by itself "
                              f"off-hours when the token is a GitHub secret (Settings › Integrations → push)")])

with tab_policy:
    section("Daily sweep", "runs once a day inside the pipeline (run.retention_sweep); saved stories never age out")
    kv_rows([("approved cards", f"{effective_knob('APPROVED_RETENTION_DAYS')} d"),
             ("rejected + duplicate", f"{effective_knob('REJECTED_RETENTION_DAYS')} d (they only hold a url hash)"),
             ("swipe events", f"{effective_knob('EVENTS_RETENTION_DAYS')} d"),
             ("Ask cache", f"{effective_knob('QA_CACHE_RETENTION_DAYS')} d"),
             ("run log / edge log / alert fires", "48 h ok runs, 14 d failed, 30 d, 90 d (fixed)")])
    knob_editor(("APPROVED_RETENTION_DAYS", "REJECTED_RETENTION_DAYS", "EVENTS_RETENTION_DAYS",
                 "QA_CACHE_RETENTION_DAYS"), "knobs_storage")


def flush(label, where, key, export_cols=None):
    """Batched delete through the Management API (10k rows per statement, each
    under the 2-min timeout — the 26 Sep prune's recipe). Shows the match count
    first; a checkbox arms the button."""
    try:
        n = run_sql(f"select count(*) as n from stories where {where}")[0]["n"] if TOKEN else None
    except Exception as e:  # noqa: BLE001
        st.error(f"{e}")
        return
    c1, c2, c3 = st.columns([3, 1, 1])
    c1.markdown(f"**{label}** — {n:,} rows match" if n is not None else f"**{label}** — needs the token",
                unsafe_allow_html=False)
    if export_cols and n:
        if c2.button("Export JSON", key=f"{key}_x", help="Download the rows before deleting them"):
            rows, last = [], 0
            while True:
                page = run_sql(f"select {export_cols} from stories where {where} and id > {last} "
                               f"order by id limit 2000")
                rows += page
                if len(page) < 2000:
                    break
                last = page[-1]["id"]
            st.session_state[f"{key}_blob"] = json.dumps(rows, ensure_ascii=False, default=str)
        if st.session_state.get(f"{key}_blob"):
            c2.download_button("Save file", st.session_state[f"{key}_blob"],
                               file_name=f"finflick-{key}.json", mime="application/json", key=f"{key}_dl")
    sure = c3.checkbox("confirm", key=f"{key}_sure", disabled=not (TOKEN and n))
    if c3.button("Flush", key=f"{key}_go", type="primary", disabled=not sure, icon=":material/delete_sweep:"):
        total = 0
        with st.status(f"flushing {label} …", expanded=True) as box:
            while True:
                got = run_sql(f"with d as (delete from stories where id in (select id from stories where {where} "
                              f"limit 10000) returning 1) select count(*) as n from d")[0]["n"]
                total += got
                box.write(f"-{got:,} (total {total:,})")
                if got < 10000:
                    break
            box.update(label=f"{label}: {total:,} rows deleted", state="complete")
        st.session_state.pop(f"{key}_blob", None)
        refresh()


EXPORT_COLS = ("id,url,url_hash,cluster_id,hook,headline,summary,impact_direction,impact_strength,impact_horizon,"
               "impact_score,severity_level,confidence,source_name,image_url,published_at,category,sectors,status,"
               "is_featured,created_at,deep_read,why_it_matters,winners_losers,whats_next")

with tab_flush:
    if not TOKEN:
        note("Flush and vacuum need SUPABASE_ACCESS_TOKEN (Settings › Integrations). Sizes still show.", RED)
    section("Cards", "the sweep does this daily at the policy above; use these to go further, once")
    d1 = st.number_input("duplicate + rejected older than (days)", 1, 365, int(effective_knob("REJECTED_RETENTION_DAYS")))
    flush("Duplicate + rejected cards", f"status in ('duplicate','rejected') and created_at < now() - interval '{d1} days'",
          "dup")
    d2 = st.number_input("approved older than (days)", 1, 365, int(effective_knob("APPROVED_RETENTION_DAYS")))
    flush("Approved cards (saved stories live on the phone, unaffected)",
          f"status = 'approved' and created_at < now() - interval '{d2} days'",
          "appr", export_cols=EXPORT_COLS)
    flush("Cards in any other status (pending / flagged / …) older than 30 days",
          "status not in ('approved','duplicate','rejected') and created_at < now() - interval '30 days'", "other")

    section("Logs and caches", "cheap to lose; the sweep prunes these too")
    ev = st.number_input("events older than (days)", 1, 365, int(effective_knob("EVENTS_RETENTION_DAYS")))
    if TOKEN:
        counts_ = run_sql(
            f"select (select count(*) from events where created_at < now() - interval '{ev} days') as events, "
            "(select count(*) from pipeline_runs where started_at < now() - interval '14 days') as runs, "
            "(select count(*) from edge_log where created_at < now() - interval '30 days') as edge, "
            "(select count(*) from qa_cache where created_at < now() - interval "
            f"'{int(effective_knob('QA_CACHE_RETENTION_DAYS'))} days') as qa, "
            "(select count(*) from price_alert_fires where fired_at < now() - interval '90 days') as fires, "
            "(select count(*) from story_companies sc where not exists (select 1 from stories s where s.id = sc.story_id)) as orphans")[0]
        kv_rows([("events", f"{counts_['events']:,}"), ("pipeline runs > 14 d", f"{counts_['runs']:,}"),
                 ("edge log > 30 d", f"{counts_['edge']:,}"), ("Ask cache", f"{counts_['qa']:,}"),
                 ("alert fires > 90 d", f"{counts_['fires']:,}"), ("orphan story links", f"{counts_['orphans']:,}")])
        sure = st.checkbox("confirm", key="logs_sure")
        if st.button("Flush logs, caches and orphans", type="primary", disabled=not sure, icon=":material/delete_sweep:"):
            with st.spinner("flushing …"):
                run_sql(f"delete from events where created_at < now() - interval '{ev} days'")
                run_sql("delete from pipeline_runs where started_at < now() - interval '14 days'")
                run_sql("delete from edge_log where created_at < now() - interval '30 days'")
                run_sql(f"delete from qa_cache where created_at < now() - interval "
                        f"'{int(effective_knob('QA_CACHE_RETENTION_DAYS'))} days'")
                run_sql("delete from price_alert_fires where fired_at < now() - interval '90 days'")
                run_sql("delete from story_companies sc where not exists (select 1 from stories s where s.id = sc.story_id)")
            st.success("flushed")
            refresh()

with tab_reclaim:
    section("VACUUM FULL", "Postgres keeps deleted rows' disk until this runs; the table is locked ~1 min (the feed pauses)")
    for t in ops.VACUUM_TABLES:
        p = dead_pct.get(t, 0)
        c1, c2 = st.columns([3, 1])
        c1.markdown(f"**{t}** — {by_name.get(t, {}).get('total_mb', 0):.0f} MB, {p:.0%} dead rows"
                    + ("" if p >= 0.05 else " · nothing to reclaim"))
        if c2.button(f"Vacuum {t}", key=f"vac_{t}", type="primary", disabled=not TOKEN, icon=":material/cleaning_services:",
                     help="Run outside NSE hours if you can"):
            try:
                with st.spinner(f"vacuum full {t} … (about a minute)"):
                    before = db_mb
                    run_sql(f"vacuum full {t}; analyze {t};")
                    storage_stats.clear()
                    after = float(storage_stats().get("db_mb") or 0)
                st.success(f"{t}: database {before:.0f} → {after:.0f} MB")
                refresh()
            except Exception as e:  # noqa: BLE001
                error_card(e)
    if st.button("ANALYZE all", disabled=not TOKEN, help="Refresh planner statistics after big deletes"):
        run_sql("analyze")
        st.success("analyzed")
