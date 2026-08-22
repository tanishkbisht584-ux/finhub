"""Review queue: pending cards (edit + approve/reject/feature) and flagged ones."""
from common import *  # noqa: F401,F403

gate("Review")

n_pending = count("stories?status=eq.pending")
n_flagged = count("stories?status=eq.flagged")
st.markdown(f"### Review &nbsp; {pill(f'{n_pending} pending', n_pending == 0, DIM if n_pending else GREEN)}"
            f"{pill(f'{n_flagged} flagged', n_flagged == 0)}", unsafe_allow_html=True)

pending = sb("GET", "stories?status=eq.pending&select=*"
                    "&order=impact_score.desc.nullslast,created_at.desc&limit=50")
st.markdown(f"**PENDING · {len(pending)}** — auto-publishes in minutes; act only when a card is wrong")
for s in pending:
    with st.container(border=True):
        st.markdown(
            f"{impact_span(s['impact_score'])} &nbsp; **{escape(s['headline'])}**<br>"
            f"<span style='color:{DIM};font-size:0.8em'>{s['source_name']} · "
            f"{s['category'] or '—'} · {ago(s['created_at'])} ago</span>",
            unsafe_allow_html=True)
        hook = st.text_input("Hook", s["hook"] or "", key=f"h{s['id']}",
                             label_visibility="collapsed", placeholder="Hook")
        summary = st.text_area("Summary", s["summary"] or "", key=f"s{s['id']}",
                               label_visibility="collapsed", height=80)
        c1, c2, c3, _ = st.columns([1, 1, 1, 3])
        if c1.button("Approve", key=f"a{s['id']}", type="primary"):
            set_status(s["id"], status="approved", hook=hook, summary=summary)
        if c2.button("Reject", key=f"r{s['id']}"):
            set_status(s["id"], status="rejected")
        if c3.button("Feature", key=f"f{s['id']}"):
            sb("PATCH", "stories?is_featured=eq.true", json={"is_featured": False})
            set_status(s["id"], status="approved", hook=hook, summary=summary, is_featured=True)

flagged = sb("GET", "stories?status=eq.flagged&select=id,headline,source_name,"
                    "raw_ai_error,created_at&order=created_at.desc&limit=20")
if flagged:
    st.markdown(f"**FLAGGED · {n_flagged}** — AI failed twice; retried for 24 h, "
                "will not publish without you")
    for s in flagged:
        with st.container(border=True):
            st.markdown(
                f"<span style='color:{RED};font-weight:700'>Flagged</span> &nbsp; "
                f"{escape(s['headline'])}<br><span style='color:{DIM};font-size:0.8em'>"
                f"{s['source_name']} · {ago(s['created_at'])} ago</span>",
                unsafe_allow_html=True)
            with st.expander("Inspect error"):
                st.code(s["raw_ai_error"] or "", language=None)
            c1, c2, _ = st.columns([1, 1, 4])
            if c1.button("Discard", key=f"fr{s['id']}"):
                set_status(s["id"], status="rejected")
            if c2.button("Retry now", key=f"rt{s['id']}", help="Back to pending; next run re-runs the AI"):
                set_status(s["id"], status="pending", raw_ai_error=None)
    if st.button(f"Discard all {n_flagged} flagged"):
        sb("PATCH", "stories?status=eq.flagged", json={"status": "rejected"})
        st.rerun()
