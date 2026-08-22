"""Pipeline cockpit: kill switches, runtime knobs, run now, last runs + logs."""
from common import *  # noqa: F401,F403

gate("Pipeline")
run = pipeline_mod()
st.markdown("### Pipeline")

pc = cfg("pipeline")
if not pc:
    st.warning("app_config has no `pipeline` row — apply pipeline/migrations/010_admin_cockpit.sql. "
               "Defaults shown; the first save creates the row.")

# ---------- switches ----------
HELP = {
    "pipeline": "OFF = the resident poller skips every iteration (no fetch, no AI, no alerts, "
                "no auto-approve). Feed freezes. Use for incidents.",
    "auto_approve": "OFF = strict manual review: nothing below the fast lane publishes until you "
                    "approve it. NOTE: the 10-min backstop is off too.",
    "alerts": "OFF = no broadcast pushes. Qualifying stories still publish, silently.",
    "personal_alerts": "OFF = no per-user (followed company/sector) pushes.",
    "chief_editor": "OFF = no comparative relevel/merge/feature pass (saves 1 AI call per cycle).",
    "video_match": "OFF = no YouTube matching (saves 1 AI call per cycle).",
}
sw = {s: bool((pc.get("switches") or {}).get(s, True)) for s in run.SWITCHES}
st.markdown("**SWITCHES** — picked up on the next loop iteration (under 45 s)")
cols = st.columns(len(run.SWITCHES))
new = {s: c.toggle(s.replace("_", " "), value=sw[s], help=HELP[s], key=f"sw_{s}")
       for c, s in zip(cols, run.SWITCHES)}
if new != sw:
    cfg_save("pipeline", {**pc, "switches": new})
    st.rerun()
off = [s for s, v in sw.items() if not v]
if off:
    st.markdown("".join(pill(f"{s} OFF", False) for s in off), unsafe_allow_html=True)

# ---------- run control ----------
st.markdown("**RUN CONTROL**")
open_runs = sb_try("pipeline_runs?select=id,started_at,host&finished_at=is.null"
                   "&order=started_at.desc&limit=1")
active = bool(open_runs) and run_age(open_runs[0]) < 900
c1, c2 = st.columns([2, 3])
with c1:
    if active:
        st.markdown(pill(f"run #{open_runs[0]['id']} active · started {ago(open_runs[0]['started_at'])} ago "
                         f"· {open_runs[0]['host']}", True), unsafe_allow_html=True)
    elif open_runs:
        st.markdown(pill(f"run #{open_runs[0]['id']} never finished (started {ago(open_runs[0]['started_at'])} "
                         "ago) — killed mid-run?", False), unsafe_allow_html=True)
    else:
        st.markdown(pill("no run in progress", True, DIM), unsafe_allow_html=True)
    if st.button("Run now (GitHub workflow_dispatch)", type="primary"):
        try:
            gh("POST", "/actions/workflows/pipeline.yml/dispatches", json={"ref": "main"})
            st.success("Dispatched — appears in the runs list within ~30 s.")
        except Exception as e:
            st.error(f"{e}")
with c2:
    try:
        ghr = gh("GET", "/actions/workflows/pipeline.yml/runs?per_page=5")["workflow_runs"]
        st.dataframe([{"status": r["status"], "conclusion": r["conclusion"],
                       "started": ago(r["run_started_at"]) + " ago", "event": r["event"],
                       "logs": r["html_url"]} for r in ghr],
                     hide_index=True, width="stretch",
                     column_config={"logs": st.column_config.LinkColumn("logs", display_text="open")})
    except Exception as e:
        st.caption(f"GitHub runs unavailable: {e}")

# ---------- last run ----------
runs = sb_try("pipeline_runs?select=*&order=started_at.desc&limit=20")
done = [r for r in runs if r.get("finished_at")]
if done:
    last = done[0]
    st.markdown(f"**LAST RUN** · #{last['id']} · finished {ago(last['finished_at'])} ago · "
                + pill("ok" if last["ok"] else "FAILED", last["ok"]), unsafe_allow_html=True)
    lc1, lc2 = st.columns(2)
    c = last.get("counts") or {}
    with lc1:
        kv_rows([(k.replace("_", " "), v) for k, v in c.items() if k != "switched_off"])
        if c.get("switched_off"):
            st.caption("switched off: " + ", ".join(c["switched_off"]))
    with lc2:
        if last.get("ai_usage"):
            st.markdown("AI lanes this run")
            html_bars(dict(sorted(last["ai_usage"].items(), key=lambda kv: -kv[1])), GREEN)
        for e in last.get("errors") or []:
            st.markdown(f"<span style='color:{RED};font-size:0.85em'>{escape(e)}</span>",
                        unsafe_allow_html=True)
    with st.expander("stdout"):
        st.code(last.get("log") or "", language=None)
    st.markdown("**RECENT RUNS**")
    runs_table(runs)
else:
    st.caption("No run rows yet — the next pipeline iteration after migration 010 writes one.")

# ---------- knobs ----------
st.markdown("**KNOBS** — override any pipeline constant; blank = code default. "
            "Applied at the start of the next iteration.")
knob_editor(run.KNOBS + run.MODEL_ENVS + ("AI_RPM_PER_LANE",), "knobs_all")
