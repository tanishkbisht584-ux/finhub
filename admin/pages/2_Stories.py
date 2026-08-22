"""Stories: find anything, edit everything, fix clusters, bulk-act."""
import uuid

from common import *  # noqa: F401,F403

gate("Stories")
ai = ai_mod()
st.markdown("### Stories")

STATUSES = ["approved", "pending", "flagged", "rejected", "duplicate"]
CATS = sorted(ai.CATEGORIES)
DIRS, STRENGTHS, HORIZONS = ["positive", "negative", "mixed", "neutral"], ["high", "medium", "low"], \
    ["short_term", "long_term", "both"]
source_names = [s["name"] for s in sb("GET", "sources?select=name&order=name")]

# ---------- filters ----------
f1, f2, f3 = st.columns([3, 2, 2])
q = f1.text_input("Search headline / hook", placeholder="tata, repo rate, ipo …")
statuses = f2.multiselect("Status", STATUSES, default=["approved"])
src = f3.selectbox("Source", ["any"] + source_names)
f4, f5, f6, f7 = st.columns(4)
cat = f4.selectbox("Category", ["any"] + CATS)
imp_min = f5.slider("Impact ≥", 0, 10, 0)
days = f6.number_input("Last N days", 1, 60, 7)
story_id = f7.text_input("Story id", placeholder="jump to #")

if story_id.strip().isdigit():
    path = f"stories?select=*&id=eq.{story_id.strip()}"
else:
    path = f"stories?select=*&created_at=gte.{iso_days_ago(int(days))}"
    if statuses:
        path += f"&status=in.({','.join(statuses)})"
    if q.strip():
        path += f"&or=(headline.ilike.{quote('*' + q.strip() + '*')},hook.ilike.{quote('*' + q.strip() + '*')})"
    if src != "any":
        path += f"&source_name=eq.{quote(src)}"
    if cat != "any":
        path += f"&category=eq.{cat}"
    if imp_min:
        path += f"&impact_score=gte.{imp_min}"
rows = sb("GET", path + "&order=created_at.desc&limit=50")
st.markdown(f"<span style='color:{DIM}'>{len(rows)} shown (newest first, max 50)</span>",
            unsafe_allow_html=True)
if not rows:
    st.stop()

# one query for every shown cluster, not one per row
cids = ",".join(sorted({r["cluster_id"] for r in rows if r.get("cluster_id")}))
members = {}
for m in sb("GET", f"stories?select=id,cluster_id,status,source_name,headline,created_at,is_featured"
                   f"&cluster_id=in.({cids})&order=created_at.asc") if cids else []:
    members.setdefault(m["cluster_id"], []).append(m)

# ---------- bulk ----------
with st.expander("Bulk action on shown stories"):
    label = {r["id"]: f"#{r['id']} · {r['headline'][:70]}" for r in rows}
    picked = st.multiselect("Stories", list(label), format_func=label.get, key="bulk_ids")
    action = st.selectbox("Action", ["approve", "reject", "re-queue to pending",
                                     "mark duplicate", "unfeature", "regenerate deep read"])
    if st.button("Apply to selected", type="primary", disabled=not picked):
        patch = {"approve": {"status": "approved"}, "reject": {"status": "rejected", "is_featured": False},
                 "re-queue to pending": {"status": "pending", "raw_ai_error": None},
                 "mark duplicate": {"status": "duplicate", "is_featured": False},
                 "unfeature": {"is_featured": False},
                 "regenerate deep read": {"deep_read": None}}[action]
        sb("PATCH", f"stories?id=in.({','.join(map(str, picked))})", json=patch)
        st.rerun()


def feature(sid):
    sb("PATCH", "stories?is_featured=eq.true", json={"is_featured": False})
    sb("PATCH", f"stories?id=eq.{sid}", json={"is_featured": True, "status": "approved"})


# ---------- rows ----------
for s in rows:
    sid = s["id"]
    star = " ⭐" if s.get("is_featured") else ""
    title = (f"#{sid} · [{s['impact_score'] if s['impact_score'] is not None else '–'}] "
             f"{s['headline'][:90]}{star} · {s['status']} · {s['source_name']} · {ago(s['created_at'])} ago")
    with st.expander(title):
        with st.form(f"edit{sid}", border=False):
            c1, c2 = st.columns([3, 1])
            hook = c1.text_input("Hook", s["hook"] or "")
            headline = c1.text_input("Headline", s["headline"] or "")
            summary = c1.text_area("Summary", s["summary"] or "", height=110)
            status = c2.selectbox("Status", STATUSES, index=STATUSES.index(s["status"]))
            impact = c2.number_input("Impact", 0, 10, int(s["impact_score"] or 0))
            category = c2.selectbox("Category", CATS, index=CATS.index(s["category"])
                                    if s.get("category") in CATS else 0)
            c3, c4, c5, c6 = st.columns(4)
            direction = c3.selectbox("Direction", DIRS, index=DIRS.index(s["impact_direction"])
                                     if s.get("impact_direction") in DIRS else 3)
            strength = c4.selectbox("Strength", STRENGTHS, index=STRENGTHS.index(s["impact_strength"])
                                    if s.get("impact_strength") in STRENGTHS else 1)
            horizon = c5.selectbox("Horizon", HORIZONS, index=HORIZONS.index(s["impact_horizon"])
                                   if s.get("impact_horizon") in HORIZONS else 2)
            sectors = c6.text_input("Sectors (comma)", ", ".join(s.get("sectors") or []))
            featured = st.checkbox("Featured (pins to the top of the feed; unpins the current one)",
                                   bool(s.get("is_featured")))
            if st.form_submit_button("Save", type="primary"):
                if featured and not s.get("is_featured"):
                    sb("PATCH", "stories?is_featured=eq.true", json={"is_featured": False})
                sb("PATCH", f"stories?id=eq.{sid}", json={
                    "hook": hook, "headline": headline, "summary": summary, "status": status,
                    "impact_score": int(impact), "category": category,
                    "impact_direction": direction, "impact_strength": strength,
                    "impact_horizon": horizon,
                    "sectors": [x.strip() for x in sectors.split(",") if x.strip()],
                    "is_featured": featured})
                st.rerun()

        meta = [f"url: {s.get('source_url') or s.get('url') or '—'}",
                f"published {ago(s.get('published_at'))} ago", f"confidence {s.get('confidence') or '—'}",
                f"image {'yes' if s.get('image_url') else 'no'}", f"video {'yes' if s.get('video_url') else 'no'}",
                f"deep read {'cached' if s.get('deep_read') else 'none'}",
                f"alerted {ago(s['alerted_at']) + ' ago' if s.get('alerted_at') else 'no'}"]
        st.caption(" · ".join(meta))
        if s.get("raw_ai_error"):
            st.code(s["raw_ai_error"], language=None)

        b1, b2, b3, b4, _ = st.columns([1, 1, 1, 1, 2])
        if b1.button("Regenerate deep read", key=f"dr{sid}", disabled=not s.get("deep_read"),
                     help="Null the cached pages; the next reader triggers a fresh generation"):
            set_status(sid, deep_read=None)
        if b2.button("Re-queue (pending)", key=f"rq{sid}"):
            set_status(sid, status="pending", raw_ai_error=None)
        if b3.button("Feature", key=f"ft{sid}", disabled=bool(s.get("is_featured"))):
            feature(sid)
            st.rerun()
        if b4.button("Open link", key=f"ol{sid}") and (s.get("source_url") or s.get("url")):
            st.link_button("article", s.get("source_url") or s.get("url"))

        # ---------- cluster ----------
        mem = members.get(s.get("cluster_id"), [])
        st.markdown(f"**CLUSTER** · {len(mem)} member(s) · `{(s.get('cluster_id') or '')[:8]}`")
        for m in mem:
            me = " ← this" if m["id"] == sid else ""
            color = GREEN if m["status"] in ("approved", "pending") else DIM
            st.markdown(f"<span style='color:{color};font-size:0.85em'>#{m['id']} · {m['status']} · "
                        f"{escape(m['source_name'])} · {escape(m['headline'][:100])}{me}</span>",
                        unsafe_allow_html=True)
        k1, k2, k3, k4 = st.columns([1, 1, 2, 1])
        if k1.button("Make keeper", key=f"mk{sid}", disabled=len(mem) < 2,
                     help="This card is the one shown; every other member becomes a duplicate"):
            others = [m["id"] for m in mem if m["id"] != sid]
            sb("PATCH", f"stories?id=in.({','.join(map(str, others))})",
               json={"status": "duplicate", "is_featured": False})
            set_status(sid, status="approved")
        if k2.button("Split out", key=f"sp{sid}", disabled=len(mem) < 2,
                     help="Not the same event: give this story its own cluster and publish it"):
            set_status(sid, cluster_id=str(uuid.uuid4()), status="approved")
        target = k3.number_input("Merge into story #", 0, key=f"mt{sid}", label_visibility="collapsed")
        if k4.button("Merge", key=f"mg{sid}", disabled=not target or target == sid,
                     help="Same event told twice: this joins the target's cluster as a duplicate"):
            tgt = sb("GET", f"stories?select=cluster_id&id=eq.{int(target)}")
            if not tgt:
                st.error(f"no story #{int(target)}")
            else:
                set_status(sid, cluster_id=tgt[0]["cluster_id"], status="duplicate", is_featured=False)
