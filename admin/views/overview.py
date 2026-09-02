"""Overview: is everything OK, at a glance — attention list, KPIs, runs, readers."""
from common import *  # noqa: F401,F403

run = pipeline_mod()
import ops  # noqa: E402  (pipeline/ on sys.path after pipeline_mod)

t, week = iso_days_ago(1), iso_days_ago(7)

# ---------- one parallel burst for every number on the page ----------
day_paths = []
day_labels = []
for n in range(6, -1, -1):
    d0, d1 = iso_days_ago(n + 1), iso_days_ago(n)
    day_paths.append(f"stories?status=eq.approved&created_at=gte.{d0}&created_at=lt.{d1}")
    day_labels.append((datetime.now(timezone.utc) - timedelta(days=n)).strftime("%d %b"))
C = counts(tuple([
    "stories?status=eq.pending", "stories?status=eq.flagged",
    f"stories?alerted_at=gte.{t}", f"edge_log?created_at=gte.{t}", f"edge_log?ok=eq.false&created_at=gte.{t}",
    f"stories?status=eq.approved&impact_score=gte.8&created_at=gte.{t}",
    f"stories?status=eq.approved&impact_score=gte.6&impact_score=lte.7&created_at=gte.{t}",
    f"stories?status=eq.approved&impact_score=gte.4&impact_score=lte.5&created_at=gte.{t}",
    f"stories?status=eq.approved&impact_score=lte.3&created_at=gte.{t}",
    f"events?type=eq.view&created_at=gte.{week}", f"saves?saved_at=gte.{week}",
    f"events?type=eq.share&created_at=gte.{week}", f"events?type=eq.alert_open&created_at=gte.{week}",
    f"events?type=eq.deep_read&created_at=gte.{week}", f"events?type=eq.qa_ask&created_at=gte.{week}",
    f"stories?created_at=gte.{t}", f"stories?status=eq.approved&created_at=gte.{t}",
    f"stories?status=eq.rejected&created_at=gte.{t}", f"stories?status=eq.duplicate&created_at=gte.{t}",
    "stories?video_url=not.is.null", "profiles?select=id", "quotes?select=symbol",
] + day_paths))
n_pending, n_flagged, alerts_today, edge_total, edge_bad = (C["stories?status=eq.pending"], C["stories?status=eq.flagged"],
                                                           C[f"stories?alerted_at=gte.{t}"], C[f"edge_log?created_at=gte.{t}"],
                                                           C[f"edge_log?ok=eq.false&created_at=gte.{t}"])
sources = q("sources?select=id,name,type,authority,is_active,last_fetched_at&order=name")
pc = cfg("pipeline")
runs = q_try("pipeline_runs?select=id,started_at,finished_at,ok,host,counts,ai_usage,errors"
             "&order=started_at.desc&limit=10")
done = [r for r in runs if r.get("finished_at")]
active = [r for r in runs if not r.get("finished_at") and run_age(r) < 900]
cap = effective_knob("MAX_ALERTS_PER_DAY")
off = [s for s in run.SWITCHES if (pc.get("switches") or {}).get(s, True) is False]
act = [s for s in sources if s["is_active"]]
stale = [s for s in act if not s["last_fetched_at"] or run_age(s, "last_fetched_at") > 3 * 3600]
versions = Counter(p["app_version"] or "?" for p in q_try("profiles?select=app_version&app_version=not.is.null"))
views = C[f"events?type=eq.view&created_at=gte.{week}"]
readers = len({e["user_id"] for e in q(f"events?select=user_id&created_at=gte.{week}")})

# ---------- header ----------
pills = []
if done:
    pills.append(pill(f"last run {ago(done[0]['finished_at'])} ago · {'ok' if done[0]['ok'] else 'FAILED'}", done[0]["ok"]))
else:
    last_fetch = max((s["last_fetched_at"] or "" for s in sources), default="") or None
    pills.append(pill(f"last fetch {ago(last_fetch)} ago", bool(last_fetch) and run_age({"x": last_fetch}, "x") < 1800))
pills.append(pill(f"run #{active[0]['id']} active" if active else "idle", True, GREEN if active else DIM))
pills += [pill(f"{s} OFF", False) for s in off]
if versions:
    pills.append(pill("app " + " · ".join(f"{v}×{n}" for v, n in versions.most_common(3)), True, DIM))
header("Overview", "Everything that matters about FinSwipe right now — fix anything from the page it links to.", pills)

# ---------- needs attention ----------
issues = []
if not schema_ok():
    issues.append(("schema", "A migration (010 admin cockpit / 011 markets) is not applied — run log, remote config, "
                             "edge log and quotes are missing.", "doctor"))
if done and not done[0]["ok"]:
    issues.append(("last run failed", f"Run #{done[0]['id']} failed {ago(done[0]['finished_at'])} ago.", "pipeline"))
if done and not active and run_age(done[0], "finished_at") > 1800 and not off:
    issues.append(("pipeline quiet", f"No run finished in {ago(done[0]['finished_at'])} and none active — "
                                     "the resident poller may have stopped.", "pipeline"))
if n_flagged >= 15:
    issues.append(("ai lanes failing", f"{n_flagged} flagged stories — AI errors, not editorial rejections.", "ai"))
if stale:
    issues.append(("stale sources", f"{len(stale)} active source(s) not fetched in 3 h: "
                                    + ", ".join(s["name"] for s in stale[:5]) + (" …" if len(stale) > 5 else ""), "sources"))
if edge_total >= 5 and edge_bad * 2 > edge_total:
    issues.append(("edge failing", f"{edge_bad}/{edge_total} edge-function lane attempts failed today.", "ai"))
groups_off = set(pc.get("groups_off") or [])
mkt_groups = (cfg("market_status").get("groups") or {})
mkt_bad = [g for g, s in mkt_groups.items() if g not in groups_off and not s.get("ok")
           and (s.get("fails", 0) >= ops.GROUP_FAILS or s.get("daily"))]
if mkt_bad and "market" not in off:
    issues.append(("market group failing", "Market refresh group(s) failing: " + ", ".join(sorted(mkt_bad))
                   + " — that data goes stale until fixed.", "market"))
scr_rows = q_try("screener_metrics?select=updated_at&order=updated_at.desc&limit=1")
if scr_rows and run_age(scr_rows[0], "updated_at") > ops.FUND_MAX_AGE_H * 3600 \
        and "market" not in off and "screener" not in groups_off:
    issues.append(("screener stale", f"screener_metrics last rebuilt {ago(scr_rows[0]['updated_at'])} ago "
                                     "(daily 18:00 IST) — the app is screening on stale numbers.", "market"))
if off:
    issues.append(("switched off", "Stages paused by a switch: " + ", ".join(off) + ".", "pipeline"))
if n_pending >= 50:
    issues.append(("review backlog", f"{n_pending} stories waiting — auto-approve may be off or stalled.", "review"))
section("Needs attention", "the watchdog's cheap checks; Health runs the full diagnosis")
page_link("health", "→ Health · every system checked, diagnosis + fix")
if not issues:
    st.markdown(pill("All clear — nothing needs you right now"), unsafe_allow_html=True)
for name, msg, slug in issues:
    c1, c2 = st.columns([6, 1])
    c1.markdown(f"<div class='fs-note' style='border-color:{RED}'><b>{escape(name.upper())}</b> &nbsp; {escape(msg)}</div>",
                unsafe_allow_html=True)
    with c2:
        page_link(slug, "Open →")

# ---------- KPIs ----------
kpis([("Pending", n_pending, "auto-publishes in minutes", AMBER if n_pending >= 50 else GREEN),
      ("Flagged", n_flagged, "AI failed twice", RED if n_flagged >= 15 else GREEN),
      ("Published today", C[f"stories?status=eq.approved&created_at=gte.{t}"], f"of {C[f'stories?created_at=gte.{t}']} ingested", GREEN),
      ("Alerts today", f"{alerts_today} / {cap}", "broadcast pushes", AMBER if alerts_today >= int(cap) else GREEN),
      ("Sources", f"{len(act)}/{len(sources)}", f"{len(stale)} stale", RED if stale else GREEN),
      ("Readers · 7 d", readers, f"{views} cards read", BLUE),
      ("Edge errors", f"{edge_bad}/{edge_total}", "qa + deepread today", RED if edge_total and edge_bad * 10 > edge_total else GREEN),
      ("Quotes", C["quotes?select=symbol"], "instruments cached", BLUE)])

# ---------- runs + AI ----------
rc1, rc2 = st.columns([3, 2])
with rc1:
    section("Recent runs", "one row per pipeline iteration")
    if runs:
        runs_table(runs)
    else:
        st.caption("no pipeline_runs rows yet (migration 010 + next pipeline iteration)")
with rc2:
    section("AI lanes · today", "calls served per model#key")
    usage = Counter()
    for r in q_try(f"pipeline_runs?select=ai_usage&started_at=gte.{t}&ai_usage=not.is.null"):
        usage.update(r["ai_usage"] or {})
    if usage:
        html_bars(dict(usage.most_common(8)), GREEN)
    else:
        st.caption("no attribution yet")
    errs = sum(len(r.get("errors") or []) for r in q_try(f"pipeline_runs?select=errors&started_at=gte.{t}"))
    st.markdown(pill(f"{errs} error line(s) in today's runs", errs == 0, DIM if errs == 0 else RED), unsafe_allow_html=True)

# ---------- publishing + readers ----------
mc1, mc2, mc3 = st.columns(3)
with mc1:
    section("Published per day")
    html_bars(dict(zip(day_labels, (C[p] for p in day_paths))), GREEN)
with mc2:
    section("Impact mix · today")
    html_bars({"8-10": C[f"stories?status=eq.approved&impact_score=gte.8&created_at=gte.{t}"],
               "6-7": C[f"stories?status=eq.approved&impact_score=gte.6&impact_score=lte.7&created_at=gte.{t}"],
               "4-5": C[f"stories?status=eq.approved&impact_score=gte.4&impact_score=lte.5&created_at=gte.{t}"],
               "1-3": C[f"stories?status=eq.approved&impact_score=lte.3&created_at=gte.{t}"]}, RED)
with mc3:
    section("Pipeline · today")
    kv_rows([("Ingested (after dedupe)", C[f"stories?created_at=gte.{t}"]),
             ("Published", C[f"stories?status=eq.approved&created_at=gte.{t}"]),
             ("Rejected (not relevant)", C[f"stories?status=eq.rejected&created_at=gte.{t}"]),
             ("Duplicates folded", C[f"stories?status=eq.duplicate&created_at=gte.{t}"]),
             ("Videos attached (all)", C["stories?video_url=not.is.null"]),
             ("Alerts sent", f"{alerts_today} / {cap}")])

rd1, rd2 = st.columns(2)
with rd1:
    section("Readers · 7 days", "from the events table; saves from the saves table")
    pct = lambda n: f" ({n * 100 // views}%)" if views else ""  # noqa: E731
    deep, asks = C[f"events?type=eq.deep_read&created_at=gte.{week}"], C[f"events?type=eq.qa_ask&created_at=gte.{week}"]
    saves, shares = C[f"saves?saved_at=gte.{week}"], C[f"events?type=eq.share&created_at=gte.{week}"]
    kv_rows([("Cards read", views), ("Readers", readers), ("Profiles (all)", C["profiles?select=id"]),
             ("Deep reads", f"{deep}{pct(deep)}"), ("Asks", asks),
             ("Saved", f"{saves}{pct(saves)}"), ("Shared", f"{shares}{pct(shares)}"),
             ("Alert opens", C[f"events?type=eq.alert_open&created_at=gte.{week}"])])
with rd2:
    section("Shortcuts")
    s1, s2 = st.columns(2)
    with s1:
        page_link("review", "Review queue", icon=":material/rate_review:")
        page_link("pipeline", "Pipeline switches & knobs", icon=":material/conveyor_belt:")
        page_link("doctor", "Run the doctor", icon=":material/stethoscope:")
    with s2:
        page_link("alerts", "Send an alert", icon=":material/notifications_active:")
        page_link("app_config", "Force update / maintenance", icon=":material/tune:")
        page_link("ai", "Keys & lanes", icon=":material/psychology:")

auto_refresh()  # status page: stale data heals itself while the tab is open
