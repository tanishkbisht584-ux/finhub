"""FinSwipe admin — the same ledger, at desk scale (minimal mockup).
Run: streamlit run admin/app.py  ·  Deploy: Streamlit Community Cloud (free)."""
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


# ---------- header ----------
sources = sb("GET", "sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
last_run = max((s["last_fetched_at"] or "" for s in sources), default="") or None
st.markdown(
    f"### FinSwipe Admin · Review Queue &nbsp;&nbsp;"
    f"<span style='color:{GREEN};font-size:0.8em'>● Pipeline last ran {ago(last_run)} ago</span>&nbsp;&nbsp;"
    f"<span style='color:{GREEN};font-size:0.8em'>● Auto-approve &lt;8 after 2 min · everything by 10</span>",
    unsafe_allow_html=True)

left, right = st.columns([2.2, 1])

# ---------- left: pending review + flagged ----------
with left:
    pending = sb("GET", "stories?status=eq.pending&select=*"
                        "&order=impact_score.desc.nullslast,created_at.desc&limit=50")
    st.markdown(f"**PENDING REVIEW · {len(pending)}**")
    for s in pending:
        with st.container(border=True):
            st.markdown(
                f"{impact_span(s['impact_score'])} &nbsp; **{s['headline']}**<br>"
                f"<span style='color:{DIM};font-size:0.8em'>{s['source_name']} · "
                f"{s['category'] or '—'} · {ago(s['created_at'])} ago · "
                f"held for your approval</span>",
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

# ---------- right: today + source health ----------
with right:
    today = datetime.now(timezone.utc).astimezone().replace(
        hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc)
    tiso = today.strftime("%Y-%m-%dT%H:%M:%SZ")
    new_today = sb("GET", f"stories?select=id&created_at=gte.{tiso}")
    pub_today = sb("GET", f"stories?select=id&status=eq.approved&created_at=gte.{tiso}")
    alerts_today = sb("GET", f"stories?select=id&alerted_at=gte.{tiso}")

    st.markdown("**TODAY**")
    rows = [("New after dedupe", len(new_today)),
            ("Published", len(pub_today)),
            ("Flagged", len(flagged)),
            ("Alerts sent", f"{len(alerts_today)} / 5")]
    st.markdown("<br>".join(
        f"{k} <span style='float:right;font-weight:700'>{v}</span>"
        for k, v in rows), unsafe_allow_html=True)

    st.markdown("---")
    # ---------- M10: reader metrics from the events the app already logs ----
    st.markdown("**READERS · 7 DAYS**")

    def count(path):
        r = requests.get(f"{URL}/rest/v1/{path}",
                         headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                                  "Prefer": "count=exact", "Range": "0-0"},
                         timeout=30)
        try:
            return int(r.headers.get("Content-Range", "/0").split("/")[-1])
        except ValueError:
            return 0

    week = (datetime.now(timezone.utc) - timedelta(days=7)
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
    views = count(f"events?type=eq.view&created_at=gte.{week}")
    saves = count(f"events?type=eq.save&created_at=gte.{week}")
    shares = count(f"events?type=eq.share&created_at=gte.{week}")
    opens = count(f"events?type=eq.alert_open&created_at=gte.{week}")
    # distinct readers: events carry no PII, user ids only
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
    st.markdown("**SOURCE HEALTH**")
    lines = []
    for s in sources:
        stale = not s["is_active"]
        color = RED if stale else GREEN
        label = "off" if stale else ago(s["last_fetched_at"])
        lines.append(f"{s['name']} <span style='float:right;color:{color}'>{label}</span>")
    st.markdown("<br>".join(lines), unsafe_allow_html=True)

    st.markdown("---")
    edited = st.data_editor(
        [{"name": s["name"], "is_active": s["is_active"]} for s in sources],
        disabled=["name"], hide_index=True, key="health", height=250)
    if st.button("Save active flags"):
        for before, after in zip(sources, edited):
            if before["is_active"] != after["is_active"]:
                sb("PATCH", f"sources?id=eq.{before['id']}",
                   json={"is_active": after["is_active"]})
        st.rerun()
