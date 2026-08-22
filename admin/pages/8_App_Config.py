"""App Config: what the installed app and the edge functions read at runtime."""
from common import *  # noqa: F401,F403

gate("App Config")
st.markdown("### App Config")

APP_DEFAULTS = {"min_version": "0.0.0", "force_update_message": "Please update FinSwipe to keep reading.",
                "update_url": "", "maintenance": "",
                "flags": {"deep_read_enabled": True, "qa_enabled": True, "live_default": True,
                          "live_poll_seconds": 15, "ambient_poll_seconds": 90}}
EDGE_DEFAULTS = {"qa_enabled": True, "deepread_enabled": True, "daily_cap": 50, "lanes": {}}
app = {**APP_DEFAULTS, **cfg("app")}
flags = {**APP_DEFAULTS["flags"], **(app.get("flags") or {})}
edge = {**EDGE_DEFAULTS, **cfg("edge")}

versions = Counter(p["app_version"] or "?" for p in
                   sb_try("profiles?select=app_version&app_version=not.is.null"))
if versions:
    st.markdown("installed: " + "".join(pill(f"{v} × {n}", True, DIM) for v, n in versions.most_common()),
                unsafe_allow_html=True)
else:
    st.caption("no app_version telemetry yet — builds before the remote-config release don't report it")

# ---------- app row ----------
st.markdown("**APP** — read once at boot by builds that ship remote config; older builds ignore it")
with st.form("app_form"):
    a1, a2 = st.columns([1, 2])
    min_version = a1.text_input("Minimum supported version", app["min_version"],
                                help="Semver. Devices below this see the update wall instead of the feed.")
    update_url = a2.text_input("Update URL (Play / APK link)", app["update_url"])
    force_msg = st.text_input("Force-update message", app["force_update_message"])
    maintenance = st.text_area("Maintenance banner (empty = none)", app["maintenance"], height=70,
                               help="Shown at the top of the app while non-empty.")
    f1, f2, f3, f4, f5 = st.columns(5)
    deep_read = f1.checkbox("deep read", flags["deep_read_enabled"])
    qa = f2.checkbox("ask (Q&A)", flags["qa_enabled"])
    live = f3.checkbox("LIVE by default", flags["live_default"])
    live_poll = f4.number_input("LIVE poll s", 5, 600, int(flags["live_poll_seconds"]))
    amb_poll = f5.number_input("ambient poll s", 15, 3600, int(flags["ambient_poll_seconds"]))
    if st.form_submit_button("Save app config", type="primary"):
        cfg_save("app", {"min_version": min_version.strip() or "0.0.0",
                         "force_update_message": force_msg.strip(), "update_url": update_url.strip(),
                         "maintenance": maintenance.strip(),
                         "flags": {"deep_read_enabled": deep_read, "qa_enabled": qa, "live_default": live,
                                   "live_poll_seconds": int(live_poll), "ambient_poll_seconds": int(amb_poll)}})
        st.rerun()
below = sum(n for v, n in versions.items() if v != "?" and
            [int(x) for x in v.split("+")[0].split(".") if x.isdigit()] <
            [int(x) for x in app["min_version"].split(".") if x.isdigit()])
st.caption(f"Effect: devices below {app['min_version']} get the update wall"
           + (f" — {below} installed device(s) right now" if versions else "")
           + ("; maintenance banner ON" if app["maintenance"] else "")
           + ("" if flags["deep_read_enabled"] else "; deep read hidden")
           + ("" if flags["qa_enabled"] else "; ask paused"))

# ---------- edge row ----------
st.markdown("**EDGE FUNCTIONS** — read on every qa / deepread request")
with st.form("edge_form"):
    e1, e2, e3 = st.columns(3)
    qa_on = e1.toggle("qa enabled", bool(edge["qa_enabled"]), help="OFF → app shows its 'busy' message")
    dr_on = e2.toggle("deepread enabled", bool(edge["deepread_enabled"]), help="OFF → honest refusal page")
    cap = e3.number_input("daily cap per user (asks, generations)", 1, 1000, int(edge["daily_cap"]))
    lanes_txt = st.text_area(
        "Lane order overrides (JSON) — keys: smart, fast, deepread; each a list of [provider, model]",
        jdump(edge.get("lanes") or {}), height=140,
        help='e.g. {"smart": [["gemini","gemini-3.7-flash"],["groq","openai/gpt-oss-120b"]]}. '
             "Empty {} = code defaults. Provider must be groq or gemini.")
    if st.form_submit_button("Save edge config", type="primary"):
        try:
            lanes = json.loads(lanes_txt or "{}")
            assert isinstance(lanes, dict)
            for k, v in lanes.items():
                assert k in ("smart", "fast", "deepread"), f"unknown lane kind {k}"
                assert all(isinstance(p, list) and len(p) == 2 and p[0] in ("groq", "gemini") and p[1]
                           for p in v), f"bad lane list for {k}"
            cfg_save("edge", {"qa_enabled": qa_on, "deepread_enabled": dr_on, "daily_cap": int(cap),
                              "lanes": lanes})
            st.rerun()
        except (ValueError, AssertionError) as e:
            st.error(f"not saved: {e}")

with st.expander("raw rows"):
    st.code("app = " + jdump(cfg("app")) + "\n\nedge = " + jdump(cfg("edge")), language="json")
