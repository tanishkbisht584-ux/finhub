"""Health: everything connected, one verdict per subsystem, the diagnosis in
plain language and the fix beside it. Platform problems (Supabase/GitHub down)
are labeled as theirs — nothing to fix, wait it out — so an incident never
reads as a broken app again."""
from common import *  # noqa: F401,F403

run = pipeline_mod()
import ops  # noqa: E402  (pipeline/ on sys.path after pipeline_mod)

if st.session_state.get("health_facts") is None:
    with st.spinner("checking everything — platform, database, pipeline, AI, edge, market, sources, app …"):
        st.session_state["health_facts"] = ops.gather(GITHUB_REPO, gh_token() or "", deep=True)
        st.session_state["health_at"] = datetime.now(timezone.utc).isoformat()
f = st.session_state["health_facts"]
v = ops.evaluate(f)
probs = v["problems"]

header("Health", "Every connected system, checked now: what is wrong, whose fault it is, and how to fix it.",
       [pill("ALL CLEAR" if not probs else f"{len(probs)} problem(s)", not probs),
        pill(f"checked {ago(st.session_state['health_at'])} ago · auto every 2 min", True, DIM)])
if st.button("Refresh", type="primary", icon=":material/refresh:"):
    st.session_state["health_facts"] = None
    st.rerun()


def card(p):
    """One problem: red name, plain-language diagnosis, the fix beside it."""
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
            if fix == "keys" and st.button("Smoke-test keys", key=f"hk_{p['name']}"):
                import check_keys
                keys_table(check_keys.check_keys())
        if p["name"] == "edge down":
            with st.expander("redeploy steps (do this by hand — it overwrites the live function)"):
                st.markdown(f"1. On this PC: `cd {REPO}`\n"
                            "2. `supabase functions deploy qa --project-ref " + PROJECT_REF + "`\n"
                            "3. Same for `deepread` if it is the one down.\n"
                            "4. If BOTH are unreachable the project itself is likely paused — "
                            "open the Supabase dashboard first.")


def group(title, hint, area, pills):
    section(title, hint)
    mine = [p for p in probs if p.get("area") == area]
    st.markdown("".join(pills) + ("" if mine else pill(" healthy ", True)), unsafe_allow_html=True)
    for p in mine:
        card(p)


def tri(label, val, fmt=lambda x: x):
    """Tri-state pill: green known-good, red known-bad, grey unknown."""
    return pill(f"{label} {fmt(val) if val is not None else '?'}", val is not None, DIM if val is None else None)


# notes routed under the group they explain; the rest under the header
NOTE_AREA = {"Supabase reports": "platform", "GitHub": "platform", "maintenance": "app",
             "pipeline switch": "pipeline"}
notes_for = lambda area: [n for n in v["notes"]  # noqa: E731
                          if next((a for k, a in NOTE_AREA.items() if k in n), None) == area]
for n in notes_for(None):
    note(n, DIM)

# ---------- Platform ----------
sbs = f.get("sb_status") or {}
lat = f.get("sb_latency_ms")
group("Platform", "the services everything runs on — their problems are not yours", "platform",
      [pill(f"supabase: {sbs.get('indicator', '?')}", sbs.get("indicator") == "none",
            DIM if not sbs else (AMBER if sbs.get("indicator") not in (None, "none") else None)),
       pill(f"gateway {lat} ms" if lat is not None else "gateway ?",
            lat is not None and lat < ops.SLOW_MS, DIM if lat is None else None),
       pill(f"github: {f.get('gh_status', '?')}", f.get("gh_status") == "none",
            DIM if "gh_status" not in f else None)])
for n in notes_for("platform"):
    note(n, AMBER)
if sbs.get("incidents"):
    for name in sbs["incidents"][:3]:
        note(f"open Supabase incident: {name}", AMBER)
c1, c2 = st.columns(2)
c1.link_button("Usage & quota →", f"https://supabase.com/dashboard/project/{PROJECT_REF}/settings/billing/usage",
               icon=":material/data_usage:")
c2.caption("Free-tier usage isn't readable by API. If the platform is green but requests fail "
           "or the project pauses itself, quota is the next suspect — check it here.")

# ---------- Database ----------
group("Database", "schema + reachability of your own project", "database",
      [pill("schema complete" if schema_ok() else "schema incomplete", schema_ok()),
       pill("project reachable", "supabase" not in f["errors"])])
page_link("doctor", "→ Doctor · full migration status + one-click apply")

# ---------- Pipeline ----------
group("Pipeline", "ingestion, scoring, publishing (GitHub Actions)", "pipeline",
      [tri("run active:", f.get("gh_active"), lambda b: "yes" if b else "no"),
       pill(f"last run {'ok' if f.get('last_run_ok') else 'FAILED' if f.get('last_run_ok') is False else '?'}",
            f.get("last_run_ok") is not False, DIM if f.get("last_run_ok") is None else None),
       tri("newest story", f.get("ingested_age"), lambda h: f"{h:.1f}h"),
       tri("newest approved", f.get("approved_age"), lambda h: f"{h:.1f}h"),
       tri("feed top", f.get("top_age"), lambda h: f"{h:.1f}h")])
for n in notes_for("pipeline"):
    note(n, AMBER)
if v["dispatch"]:
    note("Nothing ingested and no run active — a fresh run would fix it.", AMBER)
    if st.button("Dispatch pipeline run now", type="primary", icon=":material/play_arrow:"):
        try:
            gh("POST", "/actions/workflows/pipeline.yml/dispatches", json={"ref": "main"})
            st.success("dispatched")
        except Exception as e:  # noqa: BLE001
            st.error(f"{e}")

# ---------- AI & keys ----------
group("AI & keys", "model lanes + the keys that feed them", "ai",
      [tri("starved cycles:", f.get("starved_cycles")),
       tri("flagged last hour:", f.get("flagged_hour"))])
k1, k2 = st.columns([1, 3])
if k1.button("Smoke-test all keys", icon=":material/key:"):
    import check_keys
    keys_table(check_keys.check_keys())
k2.caption("Groq is Cloudflare-blocked from this PC — a local 'unreachable' is expected; "
           "CI usage on the AI page is the real proof a key works.")

# ---------- Edge functions ----------
ed = f.get("edge_deploy") or {}
group("Edge functions", "Ask + Deep Read, running inside Supabase", "edge",
      [pill(f"{fn} {'deployed' if up else 'DOWN' if up is False else '?'}",
            up is not False, DIM if up is None else None) for fn, up in (ed.items() or [])]
      or [pill("not probed", True, DIM)])
ec, ef = f.get("edge_calls"), f.get("edge_failed")
if ec is not None:
    st.markdown(pill(f"last hour: {ec - (ef or 0)}/{ec} calls ok",
                     not (ec >= ops.EDGE_MIN_CALLS and (ef or 0) * 2 > ec),
                     DIM if ec < ops.EDGE_MIN_CALLS else None), unsafe_allow_html=True)

# ---------- Market data ----------
qa_h = f.get("quote_age_h") or {}
group("Market data", "quotes + list blobs the Markets tab reads", "market",
      [pill(f"{k} {a:.1f}h", a <= ops.MAX_QUOTE_AGE_H.get(k, 999)) for k, a in sorted(qa_h.items())]
      or [pill("no quote rows / not probed", True, DIM)])
if f.get("blob_age_h"):
    kv_rows([(k, f"{a:.1f}h ago") for k, a in sorted(f["blob_age_h"].items())])

# ---------- Sources ----------
group("Sources", "the feeds the pipeline reads", "sources",
      [tri("active:", f.get("src_active")),
       pill(f"{f.get('src_stale', '?')} stale (>3 h)", not f.get("src_stale"),
            DIM if "src_stale" not in f else None)])
page_link("sources", "→ Sources · per-feed health, test-fetch, on/off")

# ---------- App ----------
group("App", "what installed phones see", "app",
      [tri("devices below min version:", f.get("app_below_min")),
       pill("maintenance banner ON" if f.get("maintenance_on") else "no maintenance banner",
            not f.get("maintenance_on"), AMBER if f.get("maintenance_on") else None),
       tri("analysis backlog:", f.get("analysis_backlog"))])
for n in notes_for("app"):
    note(n, AMBER)
page_link("app_config", "→ App Config · version gate + maintenance + flags")

# ---------- probe failures + raw ----------
@st.fragment(run_every=120)
def _auto_refresh():
    """Re-gather every 2 min while the page is open, so a recovering incident
    clears itself. Closed tab = nothing runs."""
    age = (datetime.now(timezone.utc)
           - datetime.fromisoformat(st.session_state["health_at"])).total_seconds()
    if age > 110:  # skip if a manual Refresh just ran
        st.session_state["health_facts"] = None
        st.rerun(scope="app")


_auto_refresh()

bad = {a: e for a, e in f["errors"].items() if a != "supabase"}  # supabase already a problem card
if bad:
    section("Probes that failed", "these areas show grey above — the check could not run")
    for area, err in bad.items():
        note(f"{area}: {err[:200]}", AMBER)
with st.expander("raw facts"):
    st.code(jdump(f), language="json")
