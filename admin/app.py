"""FinSwipe admin — Overview. The same ledger, at desk scale.
Run: admin/launch.bat  ·  pages live in admin/pages/, plumbing in admin/common.py."""
from common import *  # noqa: F401,F403

gate("FinSwipe Admin")

# ---------- header ----------
sources = sb("GET", "sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
last_run = max((s["last_fetched_at"] or "" for s in sources), default="") or None
n_pending = count("stories?status=eq.pending")
n_flagged = count("stories?status=eq.flagged")
st.markdown(
    f"### FinSwipe Admin &nbsp;&nbsp;"
    f"{pill(f'Pipeline last ran {ago(last_run)} ago')}"
    f"{pill(f'{n_pending} pending', True, DIM)}{pill(f'{n_flagged} flagged', n_flagged == 0)}",
    unsafe_allow_html=True)

# ---------- METRICS: publishing + readers ----------
mc1, mc2 = st.columns(2)

with mc1:
    st.markdown("**PUBLISHED PER DAY**")
    days = {}
    for n in range(6, -1, -1):
        d0, d1 = iso_days_ago(n + 1), iso_days_ago(n)
        label = (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%d %b")
        days[label] = count(f"stories?status=eq.approved&created_at=gte.{d0}&created_at=lt.{d1}")
    html_bars(days, GREEN)

    st.markdown("**IMPACT MIX · TODAY**")
    today = iso_days_ago(1)
    bands = {"8-10": count(f"stories?status=eq.approved&impact_score=gte.8&created_at=gte.{today}"),
             "6-7": count(f"stories?status=eq.approved&impact_score=gte.6&impact_score=lte.7&created_at=gte.{today}"),
             "4-5": count(f"stories?status=eq.approved&impact_score=gte.4&impact_score=lte.5&created_at=gte.{today}"),
             "1-3": count(f"stories?status=eq.approved&impact_score=lte.3&created_at=gte.{today}")}
    html_bars(bands, RED)

with mc2:
    st.markdown("**READERS · 7 DAYS**")
    week = iso_days_ago(7)
    views = count(f"events?type=eq.view&created_at=gte.{week}")
    # the app writes a `saves` row, never an events.save — counting events here read 0 forever
    saves = count(f"saves?saved_at=gte.{week}")
    shares = count(f"events?type=eq.share&created_at=gte.{week}")
    opens = count(f"events?type=eq.alert_open&created_at=gte.{week}")
    readers = len({e["user_id"] for e in
                   sb("GET", f"events?select=user_id&created_at=gte.{week}")})
    kv_rows([("Cards read", views),
             ("Readers", readers),
             ("Saved", f"{saves}" + (f" ({saves * 100 // views}%)" if views else "")),
             ("Shared", shares),
             ("Alert opens", opens)])

    st.markdown("---")
    st.markdown("**PIPELINE · TODAY**")
    t = iso_days_ago(1)
    kv_rows([("Ingested (after dedupe)", count(f"stories?created_at=gte.{t}")),
             ("Published", count(f"stories?status=eq.approved&created_at=gte.{t}")),
             ("Rejected (not relevant)", count(f"stories?status=eq.rejected&created_at=gte.{t}")),
             ("Duplicates folded", count(f"stories?status=eq.duplicate&created_at=gte.{t}")),
             ("Videos attached", count("stories?video_url=not.is.null")),
             ("Alerts sent today", f'{count(f"stories?alerted_at=gte.{t}")} / 5')])
