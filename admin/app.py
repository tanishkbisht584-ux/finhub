"""FinSwipe admin panel (spec §9): review queue, flagged stories, source health.
Run: streamlit run admin/app.py  ·  Deploy: Streamlit Community Cloud (free)."""
import requests
import streamlit as st

st.set_page_config(page_title="FinSwipe Admin", layout="wide")

if st.text_input("Admin password", type="password") != st.secrets["ADMIN_PASSWORD"]:
    st.stop()

URL = st.secrets["SUPABASE_URL"].rstrip("/")
KEY = st.secrets["SUPABASE_SERVICE_KEY"]


def sb(method, path, **kwargs):
    r = requests.request(
        method, f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", **kwargs.pop("headers", {})},
        timeout=30, **kwargs)
    r.raise_for_status()
    return r.json() if r.text else None


def set_status(story_id, **fields):
    sb("PATCH", f"stories?id=eq.{story_id}", json=fields)
    st.rerun()


tab_queue, tab_flagged, tab_health = st.tabs(["Review queue", "Flagged", "Source health"])

with tab_queue:
    rows = sb("GET", "stories?status=eq.pending&select=*"
                     "&order=impact_score.desc.nullslast,created_at.desc&limit=50")
    st.caption(f"{len(rows)} pending — score < 7 auto-approves after 2 h; ≥ 8 single-source waits here")
    for s in rows:
        badge = f"L{s['severity_level']} · {s['impact_score']}/10 · {s['category']} · {s['confidence']}"
        with st.expander(f"[{badge}] {s['headline']}"):
            hook = st.text_input("Hook", s["hook"] or "", key=f"h{s['id']}")
            summary = st.text_area("Summary", s["summary"] or "", key=f"s{s['id']}")
            st.write(f"{s['impact_direction']} · {s['impact_horizon']} · sectors: "
                     f"{', '.join(s['sectors'] or [])} · [{s['source_name']}]({s['source_url']})")
            c1, c2, c3 = st.columns(3)
            if c1.button("Approve", key=f"a{s['id']}", type="primary"):
                set_status(s["id"], status="approved", hook=hook, summary=summary)
            if c2.button("Reject", key=f"r{s['id']}"):
                set_status(s["id"], status="rejected")
            if c3.button("Approve + Feature", key=f"f{s['id']}"):
                set_status(s["id"], status="approved", hook=hook, summary=summary, is_featured=True)

with tab_flagged:
    rows = sb("GET", "stories?status=eq.flagged&select=id,headline,source_name,raw_ai_error,created_at"
                     "&order=created_at.desc&limit=50")
    st.caption(f"{len(rows)} flagged — AI failed twice; pipeline retries these for 24 h")
    for s in rows:
        with st.expander(f"{s['headline']} ({s['source_name']})"):
            st.code(s["raw_ai_error"] or "", language=None)
            if st.button("Reject", key=f"fr{s['id']}"):
                set_status(s["id"], status="rejected")

with tab_health:
    rows = sb("GET", "sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
    edited = st.data_editor(rows, disabled=["id", "name", "type", "authority", "last_fetched_at"],
                            hide_index=True, key="health")
    if st.button("Save active flags"):
        for before, after in zip(rows, edited):
            if before["is_active"] != after["is_active"]:
                sb("PATCH", f"sources?id=eq.{before['id']}", json={"is_active": after["is_active"]})
        st.rerun()
