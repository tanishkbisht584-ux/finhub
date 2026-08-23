"""Pipeline cockpit: kill switches, run now, last runs + logs, runtime knobs."""
from common import *  # noqa: F401,F403

run = pipeline_mod()
pc = cfg("pipeline")
HELP = {
    "pipeline": "OFF = the resident poller skips every iteration (no fetch, no AI, no alerts, "
                "no auto-approve). Feed freezes. Use for incidents.",
    "auto_approve": "OFF = strict manual review: nothing below the fast lane publishes until you "
                    "approve it. NOTE: the 10-min backstop is off too.",
    "alerts": "OFF = no broadcast pushes. Qualifying stories still publish, silently.",
    "personal_alerts": "OFF = no per-user (followed company/sector) pushes.",
    "chief_editor": "OFF = no comparative relevel/merge/feature pass (saves 1 AI call per cycle).",
    "market": "OFF = no quotes/FX/crypto refresh into `quotes` (market.py). News is unaffected.",
}
sw = {s: bool((pc.get("switches") or {}).get(s, True)) for s in run.SWITCHES}
off = [s for s, v in sw.items() if not v]
runs = sb_try("pipeline_runs?select=*&order=started_at.desc&limit=20")
done = [r for r in runs if r.get("finished_at")]
open_runs = [r for r in runs if not r.get("finished_at")]
active = bool(open_runs) and run_age(open_runs[0]) < 900

pills = [pill(f"run #{open_runs[0]['id']} active · {ago(open_runs[0]['started_at'])} ago" if active else "idle",
              True, GREEN if active else DIM)]
if done:
    pills.append(pill(f"last run {ago(done[0]['finished_at'])} ago · {'ok' if done[0]['ok'] else 'FAILED'}", done[0]["ok"]))
pills += [pill(f"{s} OFF", False) for s in off]
header("Pipeline", "Switches, run control, every run's counts and stdout, and every tunable constant.", pills)
if not pc:
    note("app_config has no `pipeline` row — apply migration 010 (Doctor › Schema). Defaults shown; "
         "the first save creates the row.")

tab_c, tab_r, tab_k = st.tabs(["Control", f"Runs · {len(runs)}", "Knobs"])

with tab_c:
    section("Switches", "picked up on the next loop iteration (under 45 s)")
    cols = st.columns(len(run.SWITCHES))
    new = {s: c.toggle(s.replace("_", " "), value=sw[s], help=HELP.get(s, ""), key=f"sw_{s}")
           for c, s in zip(cols, run.SWITCHES)}
    if new != sw:
        cfg_save("pipeline", {**pc, "switches": new})
        refresh()

    section("Run control", "the GitHub Actions job is the only runner")
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
        if st.button("Run now", type="primary", icon=":material/play_arrow:", help="GitHub workflow_dispatch"):
            try:
                gh("POST", "/actions/workflows/pipeline.yml/dispatches", json={"ref": "main"})
                st.success("Dispatched — appears in the runs list within ~30 s.")
            except Exception as e:  # noqa: BLE001
                st.error(f"{e}")
        if open_runs and not active and st.button("Close the stuck run row", icon=":material/close:",
                                                  help="Marks it failed so the Doctor stops reporting it"):
            sb("PATCH", f"pipeline_runs?id=eq.{open_runs[0]['id']}",
               json={"finished_at": datetime.now(timezone.utc).isoformat(), "ok": False,
                     "errors": ["closed from the admin: never finished"]})
            refresh()
    with c2:
        try:
            ghr = gh("GET", "/actions/workflows/pipeline.yml/runs?per_page=6")["workflow_runs"]
            st.dataframe([{"status": r["status"], "conclusion": r["conclusion"],
                           "started": ago(r["run_started_at"]) + " ago", "event": r["event"],
                           "logs": r["html_url"]} for r in ghr],
                         hide_index=True, width="stretch",
                         column_config={"logs": st.column_config.LinkColumn("logs", display_text="open")})
        except Exception as e:  # noqa: BLE001
            st.caption(f"GitHub runs unavailable: {e}")

    if done:
        last = done[0]
        section(f"Last run · #{last['id']}", f"finished {ago(last['finished_at'])} ago")
        st.markdown(pill("ok" if last["ok"] else "FAILED", last["ok"]), unsafe_allow_html=True)
        lc1, lc2 = st.columns(2)
        c = last.get("counts") or {}
        with lc1:
            kv_rows([(k.replace("_", " "), v) for k, v in c.items() if k != "switched_off"])
            if c.get("switched_off"):
                st.caption("switched off: " + ", ".join(c["switched_off"]))
        with lc2:
            if last.get("ai_usage"):
                st.markdown("<div class='fs-muted'>AI lanes this run</div>", unsafe_allow_html=True)
                html_bars(dict(sorted(last["ai_usage"].items(), key=lambda kv: -kv[1])), GREEN)
            for e in last.get("errors") or []:
                st.markdown(f"<span style='color:{RED};font-size:0.85em'>{escape(e)}</span>",
                            unsafe_allow_html=True)
        with st.expander("stdout"):
            st.code(last.get("log") or "", language=None)
    else:
        st.caption("No run rows yet — the next pipeline iteration after migration 010 writes one.")

with tab_r:
    if runs:
        runs_table(runs, height=500)
        pick = st.selectbox("Open a run", [r["id"] for r in runs], format_func=lambda i: f"#{i}")
        r = next(x for x in runs if x["id"] == pick)
        for e in r.get("errors") or []:
            st.markdown(f"<span style='color:{RED};font-size:0.85em'>{escape(e)}</span>", unsafe_allow_html=True)
        st.code(r.get("log") or "(no stdout captured)", language=None)
    else:
        st.caption("No run rows yet.")

with tab_k:
    st.markdown("<div class='fs-muted'>Override any pipeline constant; blank = code default. Applied at the start "
                "of the next iteration. Model lists are comma-separated.</div>", unsafe_allow_html=True)
    knob_editor(run.KNOBS + run.MODEL_ENVS + ("AI_RPM_PER_LANE",), "knobs_all")
