"""FinSwipe Admin — entry point: theme, password gate, grouped navigation,
sidebar status, one error guard around every view.
Run: admin/launch.bat  ·  views in admin/views/, plumbing + UI kit in admin/common.py."""
from streamlit.runtime.scriptrunner_utils.exceptions import ScriptControlException

from common import *  # noqa: F401,F403

st.set_page_config(page_title="FinSwipe Admin", page_icon=str(REPO / "admin" / "finswipe.ico"),
                   layout="wide", initial_sidebar_state="expanded")
inject_css()
st.logo(str(REPO / "admin" / "logo.svg"), size="large")


# ---------- gate: one password per browser session ----------

def gate():
    if st.session_state.get("authed"):
        return
    _, mid, _ = st.columns([1, 1.1, 1])
    with mid:
        st.markdown("<div style='height:18vh'></div>", unsafe_allow_html=True)
        with st.container(border=True):
            st.markdown("<div class='fs-title'>FinSwipe Admin</div>"
                        "<div class='fs-sub'>Cockpit for the pipeline, content, alerts, users and the app.</div>",
                        unsafe_allow_html=True)
            pw = st.text_input("Admin password", type="password")
            if not hmac.compare_digest(pw, st.secrets["ADMIN_PASSWORD"]):
                if pw:  # wrong guess (not the initial empty render): slow brute force
                    time.sleep(1)
                    st.error("Wrong password.")
                st.stop()
            st.session_state["authed"] = True
            st.rerun()


gate()

# ---------- navigation (sections like a studio console) ----------

P = pages()
nav = st.navigation({sec: [P[slug] for slug, _, _ in items] for sec, items in NAV.items()},
                    position="sidebar", expanded=True)


# ---------- sidebar: live status + session controls ----------

def sidebar_status():
    t = iso_days_ago(1)
    c = counts(("stories?status=eq.pending", "stories?status=eq.flagged",
                f"stories?status=eq.approved&created_at=gte.{t}"))
    pending, flagged, published = c.values()
    runs = q_try("pipeline_runs?select=started_at,finished_at,ok&order=started_at.desc&limit=3")
    done = [r for r in runs if r.get("finished_at")]
    active = any(not r.get("finished_at") and run_age(r) < 900 for r in runs)
    bits = []
    if done:
        bits.append(pill(f"run {ago(done[0]['finished_at'])} ago", bool(done[0]["ok"]),
                         None if done[0]["ok"] else RED))
    else:
        bits.append(pill("no run log", True, DIM))
    bits.append(pill("run active" if active else "idle", True, GREEN if active else DIM))
    bits.append(pill(f"{published} published today", True, DIM))
    bits.append(pill(f"{pending} pending", True, DIM if pending < 50 else AMBER))
    bits.append(pill(f"{flagged} flagged", flagged < 15))
    off = [s for s, v in (cfg("pipeline").get("switches") or {}).items() if v is False]
    bits += [pill(f"{s} OFF", False) for s in off]
    if not schema_ok():
        bits.append(pill("schema: migration pending", False, AMBER))
    st.markdown("<div class='fs-sec' style='margin-top:4px'><span class='t'>Status</span></div>"
                "<div class='fs-pills' style='justify-content:flex-start'>" + "".join(bits) + "</div>",
                unsafe_allow_html=True)


with st.sidebar:
    try:
        sidebar_status()
    except Exception as e:  # the nav must never die because a status probe did
        st.caption(f"status unavailable: {type(e).__name__}")
    st.markdown("<div style='height:8px'></div>", unsafe_allow_html=True)
    b1, b2 = st.columns(2)
    if b1.button("Refresh", icon=":material/refresh:", width="stretch", help="Drop cached reads (20 s TTL)"):
        refresh()
    if b2.button("Sign out", icon=":material/logout:", width="stretch"):
        st.session_state.clear()
        st.rerun()
    st.caption(f"{PROJECT_REF} · service role · local only")

# ---------- run the selected view behind one guard ----------
try:
    nav.run()
except ScriptControlException:
    raise
except Exception as e:  # noqa: BLE001
    error_card(e)
