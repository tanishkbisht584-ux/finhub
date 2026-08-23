"""Review queue: pending cards (edit + approve/reject/feature) and flagged ones."""
from common import *  # noqa: F401,F403

n_pending = count("stories?status=eq.pending")
n_flagged = count("stories?status=eq.flagged")
header("Review", "Pending cards auto-publish in minutes — act only when a card is wrong. Flagged ones wait for you.",
       [pill(f"{n_pending} pending", True, DIM if n_pending else GREEN), pill(f"{n_flagged} flagged", n_flagged == 0)])

tab_p, tab_f = st.tabs([f"Pending · {n_pending}", f"Flagged · {n_flagged}"])

with tab_p:
    pending = sb("GET", "stories?status=eq.pending&select=*"
                        "&order=impact_score.desc.nullslast,created_at.desc&limit=50")
    if not pending:
        st.markdown(pill("queue empty"), unsafe_allow_html=True)
    for s in pending:
        with st.container(border=True):
            st.markdown(
                f"<div class='fs-card-title'>{impact_span(s['impact_score'])} &nbsp; {escape(s['headline'])}</div>"
                f"<div class='fs-card-meta'>{escape(s['source_name'])} · {s['category'] or '—'} · "
                f"{ago(s['created_at'])} ago</div>", unsafe_allow_html=True)
            hook = st.text_input("Hook", s["hook"] or "", key=f"h{s['id']}",
                                 label_visibility="collapsed", placeholder="Hook")
            summary = st.text_area("Summary", s["summary"] or "", key=f"s{s['id']}",
                                   label_visibility="collapsed", height=80)
            c1, c2, c3, _ = st.columns([1, 1, 1, 4])
            if c1.button("Approve", key=f"a{s['id']}", type="primary", icon=":material/check:"):
                set_status(s["id"], status="approved", hook=hook, summary=summary)
            if c2.button("Reject", key=f"r{s['id']}", icon=":material/close:"):
                set_status(s["id"], status="rejected")
            if c3.button("Feature", key=f"f{s['id']}", icon=":material/star:",
                         help="Approve and pin to the top of the feed (unpins the current one)"):
                sb("PATCH", "stories?is_featured=eq.true", json={"is_featured": False})
                set_status(s["id"], status="approved", hook=hook, summary=summary, is_featured=True)

with tab_f:
    flagged = sb("GET", "stories?status=eq.flagged&select=id,headline,source_name,"
                        "raw_ai_error,created_at&order=created_at.desc&limit=30")
    if not flagged:
        st.markdown(pill("nothing flagged"), unsafe_allow_html=True)
    else:
        st.markdown("<div class='fs-muted'>AI failed twice on these. They are retried for 24 h and never publish "
                    "without you. A spike here means a lane problem — see AI.</div>", unsafe_allow_html=True)
        errs = Counter((s["raw_ai_error"] or "?")[:60] for s in flagged)
        if errs:
            section("Error shapes", "first 60 chars of raw_ai_error, newest 30")
            html_bars(dict(errs.most_common(5)), RED)
        for s in flagged:
            with st.container(border=True):
                st.markdown(
                    f"<div class='fs-card-title'><span style='color:{RED}'>Flagged</span> &nbsp; {escape(s['headline'])}</div>"
                    f"<div class='fs-card-meta'>{escape(s['source_name'])} · {ago(s['created_at'])} ago</div>",
                    unsafe_allow_html=True)
                with st.expander("Inspect error"):
                    st.code(s["raw_ai_error"] or "", language=None)
                c1, c2, _ = st.columns([1, 1, 5])
                if c1.button("Discard", key=f"fr{s['id']}", icon=":material/delete:"):
                    set_status(s["id"], status="rejected")
                if c2.button("Retry now", key=f"rt{s['id']}", icon=":material/replay:",
                             help="Back to pending; next run re-runs the AI"):
                    set_status(s["id"], status="pending", raw_ai_error=None)
        b1, b2, _ = st.columns([1, 1, 4])
        if b1.button(f"Retry all {n_flagged}", icon=":material/replay:"):
            sb("PATCH", "stories?status=eq.flagged", json={"status": "pending", "raw_ai_error": None})
            refresh()
        if b2.button(f"Discard all {n_flagged}", icon=":material/delete_sweep:"):
            sb("PATCH", "stories?status=eq.flagged", json={"status": "rejected"})
            refresh()
