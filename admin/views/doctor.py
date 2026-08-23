"""Doctor: the watchdog's checks on demand with the fix beside each, schema
(migrations) status + one-click apply, searchable run/edge logs, environment."""
import platform

from common import *  # noqa: F401,F403

run = pipeline_mod()
import ops  # noqa: E402  (pipeline/ on sys.path after pipeline_mod)

FIX_HELP = {
    "repo": ("Repo settings", f"https://github.com/{GITHUB_REPO}/settings"),
    "supabase": ("Supabase dashboard", f"https://supabase.com/dashboard/project/{PROJECT_REF}"),
}
PAGE_FOR = {"logs": ("pipeline", "Pipeline · last run + stdout"),
            "keys": ("ai", "AI · keys + lanes"),
            "review": ("review", "Review · pending + flagged"),
            "switch": ("pipeline", "Pipeline · switches")}
# migration file prefix -> PostgREST probe that 404/400s until it is applied
MARKERS = {"001": "stories?select=id", "003": "profiles?select=id", "004": "stories?select=fts",
           "007": "stories?select=video_url", "008": "stories?select=deep_read",
           "010": "app_config?select=key", "011": "quotes?select=symbol"}
MIG_DIR = REPO / "pipeline" / "migrations"


def probe(path):
    return HTTP.get(f"{URL}/rest/v1/{path}&limit=0", headers=sb_headers(), timeout=30).ok


migs = sorted(MIG_DIR.glob("*.sql"))
with ThreadPoolExecutor(8) as _ex:
    status = dict(zip([m.name for m in migs],
                      _ex.map(lambda m: probe(MARKERS[m.name[:3]]) if m.name[:3] in MARKERS else None, migs)))
pending = [m for m in migs if status[m.name] is False]

header("Doctor", "Diagnose anything: the watchdog's checks with a fix beside each, schema, logs, environment.",
       [pill(f"{len(pending)} migration(s) pending", not pending, AMBER if pending else GREEN),
        pill("management token" if mgmt_token() else "no management token", bool(mgmt_token()), None if mgmt_token() else DIM),
        pill("github token" if gh_token() else "no github token", bool(gh_token()), None if gh_token() else DIM)])

tab_c, tab_s, tab_r, tab_e, tab_v = st.tabs(["Checks", f"Schema · {len(pending)} pending", "Run logs", "Edge log", "Environment"])

# ---------- checks ----------
with tab_c:
    d1, d2, _ = st.columns([1, 1, 4])
    go = d1.button("Run checks", type="primary", icon=":material/stethoscope:")
    if d2.button("Run watchdog.yml", help="Dispatches the hourly GitHub job immediately", icon=":material/cloud_sync:"):
        try:
            gh("POST", "/actions/workflows/watchdog.yml/dispatches", json={"ref": "main"})
            st.success("dispatched")
        except Exception as e:  # noqa: BLE001
            st.error(f"{e}")
    if go or "doctor_facts" not in st.session_state:
        with st.spinner("gathering facts from GitHub + Supabase …"):
            st.session_state["doctor_facts"] = ops.gather(GITHUB_REPO, gh_token() or "")
            st.session_state["doctor_at"] = datetime.now(timezone.utc).isoformat()
    f = st.session_state["doctor_facts"]
    v = ops.evaluate(f)
    st.markdown((pill("ALL CLEAR") if not v["problems"] else pill(f"{len(v['problems'])} problem(s)", False))
                + pill(f"checked {ago(st.session_state['doctor_at'])} ago", True, DIM), unsafe_allow_html=True)
    for n in v["notes"]:
        note(n, DIM)
    for area, err in (f.get("errors") or {}).items():
        hint = " — migration 010 not applied" if area == "runlog" and "PGRST205" in err else ""
        note(f"{area} probe failed: {err[:200]}{hint}", AMBER)
    for p in v["problems"]:
        with st.container(border=True):
            st.markdown(f"<span style='color:{RED};font-weight:700'>{escape(p['name'].upper())}</span> &nbsp; "
                        f"{escape(p['msg'])}", unsafe_allow_html=True)
            fix = p["fix"]
            b1, b2, b3, _ = st.columns([1, 1, 1, 3])
            with b1:
                if fix in PAGE_FOR:
                    page_link(PAGE_FOR[fix][0], f"→ {PAGE_FOR[fix][1]}")
                elif fix in FIX_HELP:
                    st.link_button(FIX_HELP[fix][0], FIX_HELP[fix][1], icon=":material/open_in_new:")
            with b2:
                if fix == "logs" and f.get("last_gh_url"):
                    st.link_button("GitHub run logs", f["last_gh_url"], icon=":material/open_in_new:")
            with b3:
                if fix == "keys" and st.button("Smoke-test keys", key=f"keys_{p['name']}"):
                    import check_keys
                    keys_table(check_keys.check_keys())
    if v["dispatch"]:
        note("Nothing ingested and no run active — the watchdog would dispatch a pipeline run.", AMBER)
        if st.button("Dispatch pipeline run now", type="primary", icon=":material/play_arrow:"):
            try:
                gh("POST", "/actions/workflows/pipeline.yml/dispatches", json={"ref": "main"})
                st.success("dispatched")
            except Exception as e:  # noqa: BLE001
                st.error(f"{e}")
    section("Facts", "what the checks saw")
    kv = [("approved age (h)", f"{f['approved_age']:.1f}" if "approved_age" in f else "—"),
          ("ingested age (h)", f"{f['ingested_age']:.1f}" if "ingested_age" in f else "—"),
          ("feed top age (h)", f"{f['top_age']:.1f}" if "top_age" in f else "—"),
          ("flagged last hour", f.get("flagged_hour", "—")),
          ("AI starved cycles", f.get("starved_cycles", "—")),
          ("last run ok", f.get("last_run_ok", "—")), ("stuck run", f.get("stuck_run") or "none"),
          ("edge calls / failed (1 h)", f"{f.get('edge_calls', '—')} / {f.get('edge_failed', '—')}"),
          ("GitHub run active", f.get("gh_active", "—")), ("crash loop", f.get("crash_loop", "—")),
          ("repo private", f.get("private", "—"))]
    kv_rows(kv)
    with st.expander("raw facts"):
        st.code(jdump(f), language="json")

# ---------- schema ----------
with tab_s:
    st.markdown("<div class='fs-muted'>Each migration is probed through PostgREST (a table/column it adds). "
                "Apply runs the file through the Supabase Management API — additive files only; read the SQL "
                "first if unsure.</div>", unsafe_allow_html=True)
    for m in migs:
        s = status[m.name]
        c1, c2, c3 = st.columns([3, 1, 2])
        c1.markdown(pill(m.name, s is not False, DIM if s is None else None)
                    + (f"<span class='fs-muted'> &nbsp;{'applied' if s else 'PENDING' if s is False else 'no probe — assumed applied'}</span>"),
                    unsafe_allow_html=True)
        with c2.popover("SQL"):
            st.code(m.read_text(encoding="utf8"), language="sql")
        if s is False:
            with c3:
                ok_tok = bool(mgmt_token())
                if st.button(f"Apply {m.name[:3]}", key=f"apply_{m.name}", type="primary", disabled=not ok_tok,
                             icon=":material/bolt:", help=None if ok_tok else "needs SUPABASE_ACCESS_TOKEN"):
                    try:
                        with st.spinner(f"applying {m.name} …"):
                            run_sql(m.read_text(encoding="utf8"))
                        st.success(f"{m.name} applied")
                        st.cache_data.clear()
                        st.rerun()
                    except Exception as e:  # noqa: BLE001
                        st.error(f"{e}")
    if not pending:
        st.markdown(pill("schema up to date"), unsafe_allow_html=True)
    section("Ad-hoc SQL", "read-only by habit; the Management API will run anything")
    sql = st.text_area("SQL", "select count(*) from stories;", height=80, label_visibility="collapsed")
    if st.button("Run SQL", disabled=not mgmt_token(), icon=":material/terminal:"):
        try:
            out = run_sql(sql)
            st.dataframe(out, hide_index=True, width="stretch") if isinstance(out, list) and out else st.code(jdump(out))
        except Exception as e:  # noqa: BLE001
            st.error(f"{e}")

# ---------- run logs ----------
with tab_r:
    l1, l2, l3 = st.columns([3, 1, 1])
    needle = l1.text_input("stdout contains", placeholder="FEED FAIL, MODEL SWAP, INSERT FAIL, Traceback …")
    only_bad = l2.checkbox("failed only")
    n = l3.number_input("max runs", 5, 200, 30)
    path = "pipeline_runs?select=id,started_at,finished_at,ok,host,counts,errors,log&order=started_at.desc"
    if needle.strip():
        path += f"&log=ilike.{quote('*' + needle.strip() + '*')}"
    if only_bad:
        path += "&ok=eq.false"
    runs = sb_try(path + f"&limit={int(n)}")
    if not runs:
        st.caption("no matching run rows" + ("" if table_exists("pipeline_runs") else " — pipeline_runs table missing (migration 010)"))
    for r in runs:
        c = r.get("counts") or {}
        head = (f"#{r['id']} · {ago(r['started_at'])} ago · {'ok' if r['ok'] else ('FAILED' if r['ok'] is False else 'open')}"
                f" · fetched {c.get('fetched', '–')} · processed {c.get('processed', '–')} · flagged {c.get('flagged', '–')}"
                f" · {len(r.get('errors') or [])} error line(s)")
        with st.expander(head):
            log = r.get("log") or ""
            if needle.strip():
                hits = [l for l in log.splitlines() if needle.strip().lower() in l.lower()]
                st.code("\n".join(hits[:60]), language=None)
                with st.expander("full stdout"):
                    st.code(log, language=None)
            else:
                st.code(log, language=None)

# ---------- edge log ----------
with tab_e:
    e1, e2, e3 = st.columns([3, 1, 1])
    eq = e1.text_input("error / lane contains", placeholder="429, quota, gemini …")
    efn = e2.radio("fn", ["both", "qa", "deepread"], horizontal=True, label_visibility="collapsed")
    ebad = e3.checkbox("errors only", value=True)
    epath = "edge_log?select=*&order=created_at.desc&limit=300"
    if eq.strip():
        epath += f"&or=(error.ilike.{quote('*' + eq.strip() + '*')},lane.ilike.{quote('*' + eq.strip() + '*')})"
    if efn != "both":
        epath += f"&fn=eq.{efn}"
    if ebad:
        epath += "&ok=eq.false"
    edge_table(sb_try(epath), height=420)

# ---------- environment ----------
with tab_v:
    try:
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                              cwd=REPO, timeout=10).stdout.strip()
    except Exception:  # noqa: BLE001
        head = "?"
    nkeys = lambda env: len([k for k in os.environ.get(env, "").split(",") if k.strip()])  # noqa: E731
    kv_rows([("Repo HEAD", head), ("Python", platform.python_version()), ("Streamlit", st.__version__),
             ("Supabase project", PROJECT_REF), ("GitHub repo", GITHUB_REPO),
             ("GitHub token", "secrets" if st.secrets.get("GITHUB_TOKEN") else ("git credential" if gh_token() else "none")),
             ("Management token (migrations)", "yes" if mgmt_token() else "no"),
             ("FIREBASE_SERVICE_ACCOUNT_JSON", "yes" if os.environ.get("FIREBASE_SERVICE_ACCOUNT_JSON") else "no"),
             ("Gemini keys (local .env)", nkeys("GEMINI_API_KEY")), ("Groq keys (local .env)", nkeys("GROQ_API_KEY")),
             ("OpenRouter keys (local .env)", nkeys("OPENROUTER_API_KEY")),
             ("pipeline module", getattr(run, "__file__", "?"))])
    st.caption("GitHub Actions secrets are separate from this machine's pipeline/.env; the Lanes tab on AI shows "
               "what CI actually served.")
