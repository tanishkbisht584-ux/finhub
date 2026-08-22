"""Doctor: the watchdog's checks on demand, each with its fix beside it; searchable logs."""
from common import *  # noqa: F401,F403

gate("Doctor")
run = pipeline_mod()
import ops  # noqa: E402  (pipeline/ on sys.path after pipeline_mod)

st.markdown("### Doctor")

FIX_HELP = {
    "repo": ("Repo settings", f"https://github.com/{GITHUB_REPO}/settings"),
    "supabase": ("Supabase dashboard", "https://supabase.com/dashboard/projects"),
}
PAGE_FOR = {"logs": ("pages/4_Pipeline.py", "Pipeline · last run + stdout"),
            "keys": ("pages/7_AI.py", "AI · keys + lanes"),
            "review": ("pages/1_Review.py", "Review · pending + flagged"),
            "switch": ("pages/4_Pipeline.py", "Pipeline · switches")}

d1, d2, d3 = st.columns([1, 1, 4])
go = d1.button("Run checks", type="primary")
if d2.button("Run watchdog.yml now", help="Dispatches the hourly GitHub job immediately"):
    try:
        gh("POST", "/actions/workflows/watchdog.yml/dispatches", json={"ref": "main"})
        st.success("dispatched")
    except Exception as e:  # noqa: BLE001
        st.error(f"{e}")

if go or st.session_state.get("doctor_facts"):
    if go:
        with st.spinner("gathering facts from GitHub + Supabase …"):
            st.session_state["doctor_facts"] = ops.gather(GITHUB_REPO, gh_token() or "")
    f = st.session_state["doctor_facts"]
    v = ops.evaluate(f)
    st.markdown(pill("ALL CLEAR", True) if not v["problems"] else pill(f"{len(v['problems'])} problem(s)", False),
                unsafe_allow_html=True)
    for n in v["notes"]:
        st.caption(n)
    for p in v["problems"]:
        with st.container(border=True):
            st.markdown(f"<span style='color:{RED};font-weight:700'>{escape(p['name'].upper())}</span> &nbsp; "
                        f"{escape(p['msg'])}", unsafe_allow_html=True)
            fix = p["fix"]
            if fix in PAGE_FOR:
                st.page_link(PAGE_FOR[fix][0], label=f"→ {PAGE_FOR[fix][1]}")
            elif fix in FIX_HELP:
                st.link_button(FIX_HELP[fix][0], FIX_HELP[fix][1])
            if fix == "logs" and f.get("last_gh_url"):
                st.link_button("GitHub run logs", f["last_gh_url"])
            if fix == "keys":
                if st.button("Smoke-test keys now", key=f"keys_{p['name']}"):
                    import check_keys
                    rows = check_keys.check_keys()
                    st.dataframe([{"key": l, "id": m, "status": "unset" if ok is None else ("ok" if ok else "FAIL"),
                                   "detail": d} for l, m, ok, d in rows], hide_index=True, width="stretch")
    if v["dispatch"]:
        st.warning("Nothing ingested and no run active — the watchdog would dispatch a pipeline run.")
        if st.button("Dispatch pipeline run now", type="primary"):
            try:
                gh("POST", "/actions/workflows/pipeline.yml/dispatches", json={"ref": "main"})
                st.success("dispatched")
            except Exception as e:  # noqa: BLE001
                st.error(f"{e}")
    with st.expander("facts"):
        st.code(jdump(f), language="json")

# ---------- logs ----------
st.markdown("**PIPELINE RUN LOGS** — search the captured stdout")
l1, l2, l3 = st.columns([3, 1, 1])
q = l1.text_input("contains", placeholder="FEED FAIL, MODEL SWAP, INSERT FAIL …")
only_bad = l2.checkbox("failed only")
n = l3.number_input("max", 5, 200, 30)
path = "pipeline_runs?select=id,started_at,finished_at,ok,host,counts,errors,log&order=started_at.desc"
if q.strip():
    path += f"&log=ilike.{quote('*' + q.strip() + '*')}"
if only_bad:
    path += "&ok=eq.false"
runs = sb_try(path + f"&limit={int(n)}")
if not runs:
    st.caption("no matching run rows")
for r in runs:
    c = r.get("counts") or {}
    head = (f"#{r['id']} · {ago(r['started_at'])} ago · {'ok' if r['ok'] else ('FAILED' if r['ok'] is False else 'open')}"
            f" · fetched {c.get('fetched', '–')} · processed {c.get('processed', '–')} · flagged {c.get('flagged', '–')}"
            f" · {len(r.get('errors') or [])} error line(s)")
    with st.expander(head):
        log = r.get("log") or ""
        if q.strip():
            hits = [l for l in log.splitlines() if q.strip().lower() in l.lower()]
            st.code("\n".join(hits[:50]), language=None)
            with st.expander("full stdout"):
                st.code(log, language=None)
        else:
            st.code(log, language=None)

st.markdown("**EDGE CALL LOG** — search errors")
e1, e2 = st.columns([3, 1])
eq = e1.text_input("error / lane contains", placeholder="429, quota, gemini …")
efn = e2.radio("fn", ["both", "qa", "deepread"], horizontal=True, label_visibility="collapsed")
epath = "edge_log?select=*&order=created_at.desc&limit=200"
if eq.strip():
    epath += f"&or=(error.ilike.{quote('*' + eq.strip() + '*')},lane.ilike.{quote('*' + eq.strip() + '*')})"
if efn != "both":
    epath += f"&fn=eq.{efn}"
edge = sb_try(epath)
st.dataframe([{"when": ago(r["created_at"]) + " ago", "fn": r["fn"], "lane": r["lane"],
               "ok": "ok" if r["ok"] else "FAIL", "status": r["status"], "ms": r["ms"],
               "error": (r["error"] or "")[:160]} for r in edge],
             hide_index=True, width="stretch", height=300)
