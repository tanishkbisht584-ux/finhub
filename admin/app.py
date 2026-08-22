"""FinSwipe admin — Overview: is everything OK, at a glance.
Run: admin/launch.bat  ·  pages in admin/pages/, plumbing in admin/common.py."""
from common import *  # noqa: F401,F403

gate("FinSwipe Admin")
run = pipeline_mod()

sources = sb("GET", "sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
pc = cfg("pipeline")
runs = sb_try("pipeline_runs?select=id,started_at,finished_at,ok,host,counts,ai_usage,errors"
              "&order=started_at.desc&limit=10")
done = [r for r in runs if r.get("finished_at")]
active = [r for r in runs if not r.get("finished_at") and run_age(r) < 900]
n_pending = count("stories?status=eq.pending")
n_flagged = count("stories?status=eq.flagged")
t = iso_days_ago(1)
alerts_today = count(f"stories?alerted_at=gte.{t}")
cap = effective_knob("MAX_ALERTS_PER_DAY")
off = [s for s in run.SWITCHES if (pc.get("switches") or {}).get(s, True) is False]
act = [s for s in sources if s["is_active"]]
stale = [s for s in act if not s["last_fetched_at"] or run_age(s, "last_fetched_at") > 3 * 3600]
edge_total = count(f"edge_log?created_at=gte.{t}")
edge_bad = count(f"edge_log?ok=eq.false&created_at=gte.{t}") if edge_total else 0
versions = Counter(p["app_version"] or "?" for p in
                   sb_try("profiles?select=app_version&app_version=not.is.null"))

# ---------- status strip ----------
pills = []
if done:
    pills.append(pill(f"last run {ago(done[0]['finished_at'])} ago · "
                      f"{'ok' if done[0]['ok'] else 'FAILED'}", done[0]["ok"]))
else:
    last_fetch = max((s["last_fetched_at"] or "" for s in sources), default="") or None
    pills.append(pill(f"pipeline last fetched {ago(last_fetch)} ago",
                      bool(last_fetch) and run_age({"x": last_fetch}, "x") < 1800))
pills.append(pill(f"run #{active[0]['id']} active" if active else "idle", True, GREEN if active else DIM))
pills += [pill(f"{s} OFF", False) for s in off]
pills.append(pill(f"{n_pending} pending", True, DIM))
pills.append(pill(f"{n_flagged} flagged", n_flagged < 15))
pills.append(pill(f"alerts today {alerts_today} / {cap}", True, DIM))
pills.append(pill(f"sources {len(act)}/{len(sources)} on · {len(stale)} stale", not stale))
pills.append(pill(f"edge errors {edge_bad}/{edge_total}", edge_bad * 10 <= edge_total))
if versions:
    pills.append(pill("app " + " · ".join(f"{v}×{n}" for v, n in versions.most_common(3)), True, DIM))
st.markdown("### FinSwipe Admin &nbsp;&nbsp;" + "".join(pills), unsafe_allow_html=True)

# ---------- runs + AI ----------
rc1, rc2 = st.columns(2)
with rc1:
    st.markdown("**RECENT RUNS**")
    if runs:
        runs_table(runs)
    else:
        st.caption("no pipeline_runs rows yet (migration 010 + next pipeline iteration)")
with rc2:
    st.markdown("**AI LANES · TODAY**")
    usage = Counter()
    for r in sb_try(f"pipeline_runs?select=ai_usage&started_at=gte.{t}&ai_usage=not.is.null"):
        usage.update(r["ai_usage"] or {})
    if usage:
        html_bars(dict(usage.most_common(8)), GREEN)
    else:
        st.caption("no attribution yet")
    st.caption(f"pipeline errors today: "
               f"{sum(len(r.get('errors') or []) for r in sb_try(f'pipeline_runs?select=errors&started_at=gte.{t}'))}")

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
    bands = {"8-10": count(f"stories?status=eq.approved&impact_score=gte.8&created_at=gte.{t}"),
             "6-7": count(f"stories?status=eq.approved&impact_score=gte.6&impact_score=lte.7&created_at=gte.{t}"),
             "4-5": count(f"stories?status=eq.approved&impact_score=gte.4&impact_score=lte.5&created_at=gte.{t}"),
             "1-3": count(f"stories?status=eq.approved&impact_score=lte.3&created_at=gte.{t}")}
    html_bars(bands, RED)

with mc2:
    st.markdown("**READERS · 7 DAYS**")
    week = iso_days_ago(7)
    views = count(f"events?type=eq.view&created_at=gte.{week}")
    # the app writes a `saves` row, never an events.save — counting events here read 0 forever
    saves = count(f"saves?saved_at=gte.{week}")
    shares = count(f"events?type=eq.share&created_at=gte.{week}")
    opens = count(f"events?type=eq.alert_open&created_at=gte.{week}")
    deep = count(f"events?type=eq.deep_read&created_at=gte.{week}")
    asks = count(f"events?type=eq.qa_ask&created_at=gte.{week}")
    readers = len({e["user_id"] for e in sb("GET", f"events?select=user_id&created_at=gte.{week}")})
    pct = lambda n: f" ({n * 100 // views}%)" if views else ""  # noqa: E731
    kv_rows([("Cards read", views), ("Readers", readers),
             ("Deep reads", f"{deep}{pct(deep)}"), ("Asks", asks),
             ("Saved", f"{saves}{pct(saves)}"), ("Shared", f"{shares}{pct(shares)}"),
             ("Alert opens", opens)])

    st.markdown("---")
    st.markdown("**PIPELINE · TODAY**")
    kv_rows([("Ingested (after dedupe)", count(f"stories?created_at=gte.{t}")),
             ("Published", count(f"stories?status=eq.approved&created_at=gte.{t}")),
             ("Rejected (not relevant)", count(f"stories?status=eq.rejected&created_at=gte.{t}")),
             ("Duplicates folded", count(f"stories?status=eq.duplicate&created_at=gte.{t}")),
             ("Videos attached", count("stories?video_url=not.is.null")),
             ("Alerts sent today", f"{alerts_today} / {cap}")])
