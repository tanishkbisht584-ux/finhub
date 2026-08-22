"""Sources: health + on/off."""
from common import *  # noqa: F401,F403

gate("Sources")
st.markdown("### Sources")

sources = sb("GET", "sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
sc1, sc2 = st.columns(2)
with sc1:
    st.markdown("**HEALTH** — last successful fetch")
    lines = []
    for s in sources:
        stale = not s["is_active"]
        color = RED if stale else GREEN
        label = "off" if stale else ago(s["last_fetched_at"])
        lines.append(f"{escape(s['name'])} <span style='float:right;color:{color}'>{label}</span>")
    st.markdown("<br>".join(lines), unsafe_allow_html=True)
with sc2:
    st.markdown("**ON / OFF** — a retired source is re-probed every 12 h anyway")
    edited = st.data_editor(
        [{"name": s["name"], "is_active": s["is_active"]} for s in sources],
        disabled=["name"], hide_index=True, key="health", height=500)
    if st.button("Save active flags"):
        for before, after in zip(sources, edited):
            if before["is_active"] != after["is_active"]:
                sb("PATCH", f"sources?id=eq.{before['id']}",
                   json={"is_active": after["is_active"]})
        st.rerun()
