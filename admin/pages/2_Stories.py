"""Stories: search + act on anything published."""
from common import *  # noqa: F401,F403

gate("Stories")
st.markdown("### Stories")

q = st.text_input("Search headlines", placeholder="tata, repo rate, ipo …")
status_pick = st.radio("Status", ["approved", "rejected", "duplicate", "any"],
                       horizontal=True, label_visibility="collapsed")
path = "stories?select=id,headline,hook,status,impact_score,category,source_name,created_at,is_featured"
if status_pick != "any":
    path += f"&status=eq.{status_pick}"
if q.strip():
    path += f"&headline=ilike.{quote('*' + q.strip() + '*')}"
rows = sb("GET", path + "&order=id.desc&limit=25")
st.markdown(f"<span style='color:{DIM}'>{len(rows)} shown (newest first)</span>",
            unsafe_allow_html=True)
for s in rows:
    with st.container(border=True):
        star = " ⭐" if s.get("is_featured") else ""
        st.markdown(
            f"{impact_span(s['impact_score'])} &nbsp; **{escape(s['headline'])}**{star}<br>"
            f"<span style='color:{DIM};font-size:0.8em'>{s['status']} · "
            f"{s['source_name']} · {s['category'] or '—'} · {ago(s['created_at'])} ago</span>"
            + (f"<br><span style='font-size:0.85em'>{escape(s['hook'])}</span>" if s.get("hook") else ""),
            unsafe_allow_html=True)
        c1, c2, c3, _ = st.columns([1, 1, 1, 3])
        if s["status"] != "approved":
            if c1.button("Approve", key=f"sa{s['id']}"):
                set_status(s["id"], status="approved")
        else:
            if c1.button("Reject", key=f"sr{s['id']}"):
                set_status(s["id"], status="rejected", is_featured=False)
        if s["status"] == "approved" and not s.get("is_featured"):
            if c2.button("Feature", key=f"sf{s['id']}"):
                sb("PATCH", "stories?is_featured=eq.true", json={"is_featured": False})
                set_status(s["id"], is_featured=True)
        if s.get("is_featured"):
            if c2.button("Unfeature", key=f"su{s['id']}"):
                set_status(s["id"], is_featured=False)
