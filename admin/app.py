"""FinSwipe admin — the same ledger, at desk scale.
Run: admin/launch.bat  ·  Deploy: Streamlit Community Cloud (free)."""
from urllib.parse import quote

import hmac
from datetime import datetime, timedelta, timezone

import requests
import streamlit as st

st.set_page_config(page_title="FinSwipe Admin", layout="wide")

if not hmac.compare_digest(st.text_input("Admin password", type="password"),
                           st.secrets["ADMIN_PASSWORD"]):
    st.stop()

URL = st.secrets["SUPABASE_URL"].rstrip("/")
KEY = st.secrets["SUPABASE_SERVICE_KEY"]

GREEN, RED, DIM = "#3ECF8E", "#E5484D", "#9BA09C"


def sb(method, path, **kwargs):
    r = requests.request(
        method, f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", **kwargs.pop("headers", {})},
        timeout=30, **kwargs)
    r.raise_for_status()
    return r.json() if r.text else None


def count(path):
    """Row count without the rows — PostgREST exact count on a 1-row range."""
    r = requests.get(f"{URL}/rest/v1/{path}",
                     headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                              "Prefer": "count=exact", "Range": "0-0"},
                     timeout=30)
    try:
        return int(r.headers.get("Content-Range", "/0").split("/")[-1])
    except ValueError:
        return 0


def set_status(story_id, **fields):
    sb("PATCH", f"stories?id=eq.{story_id}", json=fields)
    st.rerun()


def ago(ts):
    if not ts:
        return "never"
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    mins = int((datetime.now(timezone.utc) - dt).total_seconds() // 60)
    return f"{mins} min" if mins < 120 else f"{mins // 60} h"


def impact_span(score):
    color = RED if (score or 0) >= 8 else DIM
    return f"<span style='color:{color};font-weight:700'>Impact {score if score is not None else '–'}</span>"


def iso_days_ago(n):
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------- header ----------
sources = sb("GET", "sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
last_run = max((s["last_fetched_at"] or "" for s in sources), default="") or None
n_pending = count("stories?status=eq.pending")
n_flagged = count("stories?status=eq.flagged")
st.markdown(
    f"### FinSwipe Admin &nbsp;&nbsp;"
    f"<span style='color:{GREEN};font-size:0.8em'>● Pipeline last ran {ago(last_run)} ago</span>&nbsp;&nbsp;"
    f"<span style='color:{GREEN};font-size:0.8em'>● Auto-approve &lt;8 after 2 min · everything by 10</span>",
    unsafe_allow_html=True)

tab_review, tab_stories, tab_metrics, tab_sources = st.tabs(
    [f"Review · {n_pending + n_flagged}", "Stories", "Metrics", "Sources"])

# ---------- REVIEW: pending + flagged ----------
with tab_review:
    pending = sb("GET", "stories?status=eq.pending&select=*"
                        "&order=impact_score.desc.nullslast,created_at.desc&limit=50")
    st.markdown(f"**PENDING · {len(pending)}** — auto-publishes in minutes; "
                "act only when a card is wrong")
    for s in pending:
        with st.container(border=True):
            st.markdown(
                f"{impact_span(s['impact_score'])} &nbsp; **{s['headline']}**<br>"
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
                set_status(s["id"], status="approved", hook=hook,
                           summary=summary, is_featured=True)

    flagged = sb("GET", "stories?status=eq.flagged&select=id,headline,source_name,"
                        "raw_ai_error,created_at&order=created_at.desc&limit=20")
    if flagged:
        st.markdown(f"**FLAGGED · {len(flagged)}** — AI failed twice; retried for 24 h, "
                    "will not publish without you")
        for s in flagged:
            with st.container(border=True):
                st.markdown(
                    f"<span style='color:{RED};font-weight:700'>Flagged</span> &nbsp; "
                    f"{s['headline']}<br><span style='color:{DIM};font-size:0.8em'>"
                    f"{s['source_name']} · {ago(s['created_at'])} ago</span>",
                    unsafe_allow_html=True)
                with st.expander("Inspect error"):
                    st.code(s["raw_ai_error"] or "", language=None)
                if st.button("Discard", key=f"fr{s['id']}"):
                    set_status(s["id"], status="rejected")
        if st.button(f"Discard all {len(flagged)} flagged"):
            sb("PATCH", "stories?status=eq.flagged", json={"status": "rejected"})
            st.rerun()

# ---------- STORIES: search + act on anything published ----------
with tab_stories:
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
                f"{impact_span(s['impact_score'])} &nbsp; **{s['headline']}**{star}<br>"
                f"<span style='color:{DIM};font-size:0.8em'>{s['status']} · "
                f"{s['source_name']} · {s['category'] or '—'} · {ago(s['created_at'])} ago</span>"
                + (f"<br><span style='font-size:0.85em'>{s['hook']}</span>" if s.get("hook") else ""),
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

# ---------- METRICS: publishing + readers ----------
with tab_metrics:
    mc1, mc2 = st.columns(2)

    with mc1:
        st.markdown("**PUBLISHED PER DAY**")
        days = {}
        for n in range(6, -1, -1):
            d0, d1 = iso_days_ago(n + 1), iso_days_ago(n)
            label = (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%d %b")
            days[label] = count(f"stories?status=eq.approved&created_at=gte.{d0}&created_at=lt.{d1}")
        st.bar_chart(days, height=200, color=GREEN)

        st.markdown("**IMPACT MIX · TODAY**")
        today = iso_days_ago(1)
        bands = {"8-10": count(f"stories?status=eq.approved&impact_score=gte.8&created_at=gte.{today}"),
                 "6-7": count(f"stories?status=eq.approved&impact_score=gte.6&impact_score=lte.7&created_at=gte.{today}"),
                 "4-5": count(f"stories?status=eq.approved&impact_score=gte.4&impact_score=lte.5&created_at=gte.{today}"),
                 "1-3": count(f"stories?status=eq.approved&impact_score=lte.3&created_at=gte.{today}")}
        st.bar_chart(bands, height=180, color=RED)

    with mc2:
        st.markdown("**READERS · 7 DAYS**")
        week = iso_days_ago(7)
        views = count(f"events?type=eq.view&created_at=gte.{week}")
        saves = count(f"events?type=eq.save&created_at=gte.{week}")
        shares = count(f"events?type=eq.share&created_at=gte.{week}")
        opens = count(f"events?type=eq.alert_open&created_at=gte.{week}")
        readers = len({e["user_id"] for e in
                       sb("GET", f"events?select=user_id&created_at=gte.{week}")})
        mrows = [("Cards read", views),
                 ("Readers", readers),
                 ("Saved", f"{saves}" + (f" ({saves * 100 // views}%)" if views else "")),
                 ("Shared", shares),
                 ("Alert opens", opens)]
        st.markdown("<br>".join(
            f"{k} <span style='float:right;font-weight:700'>{v}</span>"
            for k, v in mrows), unsafe_allow_html=True)

        st.markdown("---")
        st.markdown("**PIPELINE · TODAY**")
        t = iso_days_ago(1)
        prows = [("Ingested (after dedupe)", count(f"stories?created_at=gte.{t}")),
                 ("Published", count(f"stories?status=eq.approved&created_at=gte.{t}")),
                 ("Rejected (not relevant)", count(f"stories?status=eq.rejected&created_at=gte.{t}")),
                 ("Duplicates folded", count(f"stories?status=eq.duplicate&created_at=gte.{t}")),
                 ("Videos attached", count("stories?video_url=not.is.null")),
                 ("Alerts sent today", f'{count(f"stories?alerted_at=gte.{t}")} / 5')]
        st.markdown("<br>".join(
            f"{k} <span style='float:right;font-weight:700'>{v}</span>"
            for k, v in prows), unsafe_allow_html=True)

# ---------- SOURCES: health + on/off ----------
with tab_sources:
    sc1, sc2 = st.columns(2)
    with sc1:
        st.markdown("**HEALTH** — last successful fetch")
        lines = []
        for s in sources:
            stale = not s["is_active"]
            color = RED if stale else GREEN
            label = "off" if stale else ago(s["last_fetched_at"])
            lines.append(f"{s['name']} <span style='float:right;color:{color}'>{label}</span>")
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
