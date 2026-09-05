"""Ops brain, shared by .github/workflows/watchdog.yml (hourly) and the admin's
Doctor page (on demand): gather facts -> evaluate (pure) -> act.
(Named ops, not watchdog: a pip package called watchdog ships with Streamlit.)

Failure map covered (see evaluate):
  repo gone private (free minutes would die)       -> alert
  pipeline crash-looping (bad secret/dep/commit)   -> alert (restart is useless)
  pipeline dead / cron-lagged                      -> self-heal: dispatch a run
  ingesting but nothing approved (gate stalled)    -> alert
  AI lanes failing (flagged stories piling up)     -> alert (catches PARTIAL outages)
  AI starved (most cycles deferred on quota)       -> alert (2026-08-22: one key per
      provider for 9 days kept every DB check green while 95% went unscored)
  feed ranking frozen (app's own query checked)    -> alert
  last run failed / run stuck open                 -> alert (pipeline_runs log)
  edge functions failing (edge_log error rate)     -> alert
  Supabase unreachable                             -> alert (nothing can heal it)
Alerts = one open `watchdog` issue at a time (GitHub emails the owner) plus a
direct FCM push to the ops users' phones — never the public `alerts` topic.
Healthy passes auto-close the issue so the next incident can alert again."""
import io
import json
import os
import re
import sys
import time
import zipfile
from datetime import datetime, timedelta, timezone

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # run as a script from repo root
from run import iso, load_config, load_env, sb, send_fcm_token  # noqa: E402

INGEST_MAX_H = 3     # no new approved story for this long => frozen
FEED_TOP_MAX_H = 12  # nothing fresh in the feed's visible top => frozen
FLAG_SPIKE = 15      # flagged/hour; normal is ~0-2, 15+ means lanes are dying
RUN_STUCK_MIN = 30   # a pipeline_runs row open this long was killed mid-run
EDGE_MIN_CALLS = 5   # below this an error rate is noise
SLOW_MS = 3000       # median empty-read above this => gateway degraded
# quote freshness ceiling per kind. Interval kinds advance updated_at even
# off-hours, so 4 h just absorbs GitHub's cron lag between resident runs.
# ponytail: flat hours, no market calendar; add trading-day logic only if this false-alarms
MAX_QUOTE_AGE_H = {"fx": 4, "commodity": 4, "crypto": 4, "equity": 4, "index": 4,
                   "mf": 30, "macro": 30}
FUND_MAX_AGE_H = 36  # fundamentals/screener_metrics rebuild daily; 36 h absorbs cron lag
# Blob content-age: the date the data INSIDE the blob claims, not when we wrote
# the row. A frozen upstream keeps answering 200 with old data — row updated_at
# keeps advancing (and with market.write_blobs suppression it stops advancing on
# identical payloads), so only the payload's own dates reveal the freeze.
# Budget = widest routine market gap (long weekend + holiday) + one missed run.
BLOB_CONTENT_MAX_H = {"bonds": 120, "flows": 120,
                      # signal blobs (signals.py) rebuild every lap; 6h absorbs
                      # GitHub's worst observed cron lag between resident runs
                      "trending": 6, "move_context": 6,
                      # World Bank re-cuts WDI a few times a year; `asof` = lastupdated
                      "macro_context": 24 * 120,
                      # context groups stamp asof = fetch date (daily); 48 h = one missed day
                      "cb_rates": 48, "calendar": 48,
                      "participant_oi": 120,  # NSE file date; long weekend + holiday
                      "shipping": 240,  # PortWatch publishes ~5 days behind
                      "freight": 312,  # SCFI/CCFI weekly Friday + lag budget
                      "monsoon": 48}
GROUP_FAILS = 3      # interval group: consecutive failures before it's a problem
                     # (daily groups alert on a single failure — one miss = a lost day)


def ops_push(title, body):
    """Direct push to every ops user's device. Returns the number sent.
    Empty story_id => the app's int.tryParse gives null => no deep-link."""
    load_env()
    ids = load_config().get("ops_user_ids") or []
    if not ids:
        print("ops push skipped: no ops user configured (admin -> Alerts -> ops users)")
        return 0
    quoted = ",".join(f'"{i}"' for i in ids)
    rows = sb("GET", f"profiles?select=id,fcm_token&id=in.({quoted})&fcm_token=not.is.null")
    sent = 0
    for r in rows:
        if send_fcm_token(r["fcm_token"], title, body[:170], "", "") == "sent":
            sent += 1
    print(f"ops push: {sent}/{len(rows)} device(s)")
    return sent


# ---------- gather: every fact the checks need, each probe isolated ----------

def _age_h(ts, now):
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return (now - dt).total_seconds() / 3600


def _parse_obs_date(s):
    """Stooq '2026-09-01' or NSE '01-Sep-2026' -> aware UTC datetime, else None."""
    for fmt in ("%Y-%m-%d", "%d-%b-%Y"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            continue
    return None


def blob_content_age_h(key, payload, now):
    """Hours since the newest observation date inside a blob payload, or None
    when the payload carries no parseable date — unknown must never grade as
    stale (a fabricated clock would hide the very freeze this exists to catch)."""
    if key == "bonds":
        dates = [_parse_obs_date(y.get("date")) for y in (payload or {}).get("yields") or []]
    elif key in ("flows", "participant_oi"):
        dates = [_parse_obs_date((payload or {}).get("date"))]
    elif key in ("macro_context", "cb_rates", "calendar", "shipping", "monsoon",
                 "freight"):
        dates = [_parse_obs_date((payload or {}).get("asof"))]
    elif key in ("trending", "move_context"):  # our own build clock, full ISO
        try:
            dates = [datetime.fromisoformat(str((payload or {}).get("computed_at")))]
        except ValueError:
            dates = []
    else:
        dates = []
    dates = [d for d in dates if d]
    return (now - max(dates)).total_seconds() / 3600 if dates else None


def gather(repo, gh_token, deep=False):
    """-> facts dict. A failed probe records its error under facts['errors'][area]
    and leaves that area's keys absent; evaluate() treats absent as unknown.
    deep=True (Health page only) adds probes the hourly watchdog must not pay
    for or alert on — absent deep facts keep those checks silent."""
    now = datetime.now(timezone.utc)
    f = {"errors": {}, "now": now.isoformat()}

    # platform status (Atlassian Statuspage JSON, unauthenticated); failure = unknown
    try:
        s = requests.get("https://status.supabase.com/api/v2/status.json", timeout=5).json()
        inc = requests.get("https://status.supabase.com/api/v2/incidents/unresolved.json", timeout=5).json()
        f["sb_status"] = {"indicator": s["status"]["indicator"],
                          "incidents": [i["name"] for i in inc.get("incidents", [])]}
    except Exception as e:  # noqa: BLE001
        f["errors"]["platform"] = str(e)
    try:
        f["gh_status"] = requests.get("https://www.githubstatus.com/api/v2/status.json",
                                      timeout=5).json()["status"]["indicator"]
    except Exception:  # noqa: BLE001
        pass  # GitHub's own status being unreachable is not worth a line
    gh = f"https://api.github.com/repos/{repo}"
    hdrs = {"Authorization": f"Bearer {gh_token}", "Accept": "application/vnd.github+json"}

    def call(url, **kw):
        r = requests.request(kw.pop("method", "GET"), url, headers=hdrs, timeout=60, **kw)
        r.raise_for_status()
        return r.json() if r.text else None

    try:
        f["private"] = call(gh)["private"]
        runs = call(gh + "/actions/workflows/pipeline.yml/runs?per_page=10")["workflow_runs"]
        f["gh_active"] = any(r["status"] in ("queued", "in_progress") for r in runs)
        done = [r for r in runs if r["status"] == "completed" and r["conclusion"] != "cancelled"]
        f["crash_loop"] = len(done) >= 3 and all(r["conclusion"] == "failure" for r in done[:3])
        f["last_gh_url"] = done[0]["html_url"] if done else None
        head = call(gh + "/commits?per_page=1")[0]
        f["head_sha"] = head["sha"][:12]
        f["head_at"] = head["commit"]["committer"]["date"]
    except Exception as e:  # noqa: BLE001
        f["errors"]["github"] = str(e)

    try:
        def newest_age(filt):
            rows = sb("GET", f"stories?select=created_at&{filt}order=created_at.desc&limit=1")
            return _age_h(rows[0]["created_at"], now) if rows else 999
        f["approved_age"] = newest_age("status=eq.approved&")
        f["ingested_age"] = newest_age("")
        since = iso(now - timedelta(hours=48))  # Z, not +00:00: "+" is a space in a URL
        top = sb("GET", "stories?select=published_at&status=eq.approved"
                        f"&published_at=gte.{since}&order=is_featured.desc,published_at.desc&limit=10")
        f["top_age"] = min((_age_h(r["published_at"], now) for r in top), default=999)
        hr = iso(now - timedelta(hours=1))
        f["flagged_hour"] = len(sb("GET", f"stories?select=id&status=eq.flagged&created_at=gte.{hr}&limit={FLAG_SPIKE}"))
        c = load_config()
        f["switches"] = c.get("switches") or {}
        f["groups_off"] = c.get("groups_off") or []
    except Exception as e:  # noqa: BLE001
        f["errors"]["supabase"] = str(e)

    # market/fundamentals layer: per-group status written by market.refresh,
    # plus freshness of the two screener tables (absent pre-migration 016/017)
    try:
        rows = sb("GET", "app_config?select=value&key=eq.market_status")
        f["market_status"] = (rows[0]["value"] if rows else {}) or {}
        f["run_sha"] = f["market_status"].get("sha") or None
        ts = [g.get("ts") for g in (f["market_status"].get("groups") or {}).values() if g.get("ts")]
        f["status_age_h"] = _age_h(max(ts), now) if ts else None
        ages = {}
        for t in ("fundamentals", "screener_metrics"):
            r2 = sb("GET", f"{t}?select=updated_at&order=updated_at.desc&limit=1")
            if r2:
                ages[t] = _age_h(r2[0]["updated_at"], now)
        f["fund_age_h"] = ages
    except Exception as e:  # noqa: BLE001
        f["errors"]["fund"] = str(e)

    # our own run log (migration 010) — absent pre-migration, that's fine
    try:
        runs = sb("GET", "pipeline_runs?select=id,started_at,finished_at,ok,counts,errors"
                         "&order=started_at.desc&limit=30")
        done = [r for r in runs if r["finished_at"]]
        if done:
            f["last_run_ok"] = bool(done[0]["ok"])
            f["last_run_age_h"] = _age_h(done[0]["finished_at"], now)
            f["last_run_id"] = done[0]["id"]
            f["last_run_errors"] = done[0].get("errors") or []
            cycles = [r for r in done if r.get("counts")]
            starved = [r for r in cycles if (r["counts"].get("quota_blocked") or 0) > 0]
            f["starved_cycles"] = f"{len(starved)}/{len(cycles)}"
            f["starved"] = bool(cycles) and len(starved) >= len(cycles) / 2
        stuck = [r for r in runs if not r["finished_at"] and _age_h(r["started_at"], now) * 60 > RUN_STUCK_MIN]
        f["stuck_run"] = stuck[0]["id"] if stuck else None
        hr = iso(now - timedelta(hours=1))
        edge = sb("GET", f"edge_log?select=ok&created_at=gte.{hr}")
        f["edge_calls"], f["edge_failed"] = len(edge), sum(1 for e in edge if not e["ok"])
    except Exception as e:  # noqa: BLE001
        f["errors"]["runlog"] = str(e)

    # starvation fallback when there is no run log yet: read the newest successful
    # GitHub run's log for "awaiting quota" on the done: lines
    if "starved" not in f and "github" not in f["errors"]:
        try:
            last = call(gh + "/actions/workflows/pipeline.yml/runs?status=success&per_page=1")["workflow_runs"][0]
            z = zipfile.ZipFile(io.BytesIO(requests.get(last["logs_url"], headers=hdrs, timeout=60).content))
            cycles = [l for n in z.namelist() for l in z.read(n).decode("utf8", "replace").splitlines()
                      if " done: " in l][-30:]
            n_starved = sum("awaiting quota" in l for l in cycles)
            f["starved_cycles"] = f"{n_starved}/{len(cycles)}"
            f["starved"] = bool(cycles) and n_starved >= len(cycles) / 2
        except Exception as e:  # noqa: BLE001
            f["errors"]["starvation"] = str(e)

    if deep:
        url = os.environ["SUPABASE_URL"].rstrip("/")
        hd = {"apikey": os.environ["SUPABASE_SERVICE_KEY"],
              "Authorization": f"Bearer {os.environ['SUPABASE_SERVICE_KEY']}"}
        try:  # gateway latency: median of 3 timed empty reads; a hang counts as 9999
            times = []
            for _ in range(3):
                t0 = time.monotonic()
                try:
                    requests.get(f"{url}/rest/v1/stories?select=id&limit=0", headers=hd, timeout=8)
                    times.append((time.monotonic() - t0) * 1000)
                except requests.exceptions.RequestException:
                    times.append(9999)
            f["sb_latency_ms"] = int(sorted(times)[1])
        except Exception as e:  # noqa: BLE001
            f["errors"]["latency"] = str(e)
        try:  # market data freshness: newest row per quote kind + list blobs
            ages = {}
            for kind in MAX_QUOTE_AGE_H:
                rows = sb("GET", f"quotes?select=updated_at&kind=eq.{kind}&order=updated_at.desc&limit=1")
                if rows:  # a kind with no rows yet (e.g. macro without a FRED key) stays unknown
                    ages[kind] = _age_h(rows[0]["updated_at"], now)
            f["quote_age_h"] = ages
            f["blob_age_h"] = {r["key"]: _age_h(r["updated_at"], now)
                               for r in sb("GET", "market_blobs?select=key,updated_at")}
            keys = ",".join(BLOB_CONTENT_MAX_H)
            f["blob_content_age_h"] = {
                r["key"]: a for r in sb("GET", f"market_blobs?select=key,payload&key=in.({keys})")
                if (a := blob_content_age_h(r["key"], r.get("payload"), now)) is not None}
        except Exception as e:  # noqa: BLE001
            f["errors"]["market"] = str(e)
        try:  # sources: bulk-stale means fetching itself stalled, not one bad feed
            act = [s for s in sb("GET", "sources?select=is_active,last_fetched_at&is_active=eq.true")]
            f["src_active"] = len(act)
            f["src_stale"] = sum(1 for s in act
                                 if not s["last_fetched_at"] or _age_h(s["last_fetched_at"], now) > 3)
        except Exception as e:  # noqa: BLE001
            f["errors"]["sources"] = str(e)
        try:  # edge functions deployed? 404 from the gateway = gone; any other HTTP answer
            # (401 is the expected one) = deployed; no answer at all = unreachable
            f["edge_deploy"] = {}
            for fn in ("qa", "deepread"):
                try:
                    r = requests.get(f"{url}/functions/v1/{fn}", timeout=8)
                    f["edge_deploy"][fn] = r.status_code != 404
                except requests.exceptions.RequestException:
                    f["edge_deploy"][fn] = False
        except Exception as e:  # noqa: BLE001
            f["errors"]["edge"] = str(e)
        try:  # app config + install base
            rows = sb("GET", "app_config?select=value&key=eq.app")
            app = (rows[0].get("value") if rows else {}) or {}
            f["maintenance_on"] = bool(app.get("maintenance"))
            minv = app.get("min_version") or ""
            if minv:
                vt = lambda s: tuple(int(x) for x in re.findall(r"\d+", s or "")[:3])  # noqa: E731
                users = sb("GET", "profiles?select=app_version&app_version=not.is.null")
                f["app_below_min"] = sum(1 for u in users if vt(u["app_version"]) < vt(minv))
            f["analysis_backlog"] = len(sb("GET", "analysis_requests?select=symbol"))
        except Exception as e:  # noqa: BLE001
            f["errors"]["app"] = str(e)
    return f


# ---------- evaluate: pure ----------

def evaluate(f):
    """facts -> {"problems": [{name, msg, fix, area}], "notes": [...], "dispatch": bool}.
    fix names the lever: repo | logs | keys | review | supabase | switch | platform |
    sources | edge | market | None. area groups problems on the Health page.
    dispatch = restarting the pipeline can actually help right now."""
    p, notes = [], []

    def prob(name, msg, fix=None, area="pipeline"):
        p.append({"name": name, "msg": msg, "fix": fix, "area": area})

    if f.get("private"):
        prob("repo private", "Repo is PRIVATE — Actions free minutes will run out within a day; "
             "make it public or the pipeline stops.", "repo")
    if f.get("crash_loop"):
        prob("crash loop", "Pipeline is CRASH-LOOPING (3 straight failed runs) — restarting won't help. "
             f"Likely a broken secret, dependency, or commit. Logs: {f.get('last_gh_url')}", "logs")
    if f.get("starved"):
        prob("ai starved", f"AI STARVED: {f.get('starved_cycles')} recent cycles deferred stories for lack of "
             "quota — keys exhausted or the secrets hold a single key (GEMINI_API_KEY / GROQ_API_KEY are "
             "comma lists). Feed is a trickle.", "keys", "ai")

    # Supabase: separate a platform incident (their side, wait it out) from a
    # project problem (our side, fixable) — today's confusion made this page exist.
    incidents = (f.get("sb_status") or {}).get("incidents") or []
    sb_broken = "supabase" in f["errors"] or f.get("sb_latency_ms", 0) > SLOW_MS
    if incidents and sb_broken:
        prob("supabase incident", f"Supabase platform incident: {'; '.join(incidents[:2])} — this is "
             "Supabase's infrastructure, NOT your project. Nothing to fix; wait it out. "
             "The app serves its offline cache meanwhile.", "platform", "platform")
    elif "supabase" in f["errors"]:
        prob("supabase", f"Supabase unreachable: {f['errors']['supabase']}. If Supabase itself is down, wait "
             "it out — the app serves its offline cache; if the project was paused or the key rotated, fix that.",
             "supabase", "platform")
    elif f.get("sb_latency_ms", 0) > SLOW_MS:
        prob("gateway slow", f"Supabase gateway is slow or hanging ({f['sb_latency_ms']} ms for an empty "
             "read; normal is under 1000) — often a platform incident before the status page admits it. "
             "Not your code; recheck in a while.", "platform", "platform")
    if incidents and not sb_broken:
        notes.append(f"Supabase reports an incident ({incidents[0]}) but your project responded normally")
    # deploy drift (worldmonitor pattern): prod stamps its GITHUB_SHA into
    # market_status; compare against HEAD. A CI process lives ~5.5h, so a
    # young HEAD is normal rollout lag — only a 7h-old HEAD still not running,
    # while the pipeline actively writes status, means the rollout is stuck.
    if (f.get("run_sha") and f.get("head_sha") and f["run_sha"] != f["head_sha"]
            and (f.get("status_age_h") or 99) < 0.5
            and _age_h(f.get("head_at") or f["now"], datetime.fromisoformat(f["now"])) > 7):
        prob("deploy drift", f"Prod is running commit {f['run_sha']} but main's HEAD "
             f"({f['head_sha']}) is over 7h old — the pipeline never picked it up. A run is "
             "stuck on old code past its 5.5h deadline, or the workflow stopped scheduling; "
             "cancel the active run or dispatch a fresh one.", "repo", "platform")
    if f.get("gh_status") not in (None, "none"):
        notes.append(f"GitHub itself reports degraded status ({f['gh_status']}) — Actions may lag")
    if "github" in f["errors"]:
        notes.append(f"GitHub checks skipped: {f['errors']['github']}")

    switches = f.get("switches") or {}
    paused = switches.get("pipeline") is False
    if paused:
        notes.append("pipeline switch is OFF (admin) — ingestion checks below are expected to go red")
    starved_ingest = False
    if "approved_age" in f and not paused:
        if f["approved_age"] > INGEST_MAX_H:
            if f["ingested_age"] <= INGEST_MAX_H:
                prob("gate stalled", f"Stories are ingesting (newest {f['ingested_age']:.1f}h old) but NONE "
                     f"approved in {f['approved_age']:.1f}h — the approval gate or AI scoring is stalled, "
                     "not the sources." + (" auto_approve switch is OFF." if switches.get("auto_approve") is False else ""),
                     "review")
            else:
                starved_ingest = True
        if f["top_age"] > FEED_TOP_MAX_H:
            prob("feed frozen", f"Feed ranking frozen: freshest story in the visible top 10 is "
                 f"{f['top_age']:.1f}h old.", "logs")
        if f.get("flagged_hour", 0) >= FLAG_SPIKE:
            prob("ai lanes failing", f"AI lanes are FAILING: {FLAG_SPIKE}+ stories flagged in the last hour "
                 "(AI errors, not editorial rejections). Check raw_ai_error on recent flagged rows — "
                 "likely a dead model or exhausted keys.", "keys", "ai")

    if f.get("last_run_ok") is False:
        errs = "; ".join(f.get("last_run_errors") or [])[:300]
        prob("last run failed", f"Last pipeline run #{f.get('last_run_id')} FAILED "
             f"{f.get('last_run_age_h', 0):.1f}h ago: {errs or 'see its stdout'}", "logs")
    if f.get("stuck_run"):
        prob("run stuck", f"Run #{f['stuck_run']} has been open for over {RUN_STUCK_MIN} min — killed "
             "mid-run (job timeout or crash before the log PATCH).", "logs")
    if f.get("edge_calls", 0) >= EDGE_MIN_CALLS and f["edge_failed"] * 2 > f["edge_calls"]:
        prob("edge failing", f"Edge functions: {f['edge_failed']}/{f['edge_calls']} AI lane attempts failed "
             "in the last hour (qa/deepread). See the AI page's call log.", "keys", "edge")

    # market refresh groups + fundamentals freshness (market_status row, written
    # by market.refresh each lap). Silent while the market switch is off — an
    # intentional pause must not page anyone.
    market_off = paused or switches.get("market") is False
    if switches.get("market") is False:
        notes.append("market switch is OFF (admin) — market/fundamentals checks below stay silent")
    off = set(f.get("groups_off") or [])
    if off:
        notes.append(f"market group(s) disabled from admin: {', '.join(sorted(off))}")
    if not market_off:
        groups = (f.get("market_status") or {}).get("groups") or {}
        bad = {g: s for g, s in groups.items() if g not in off and not s.get("ok")
               and (s.get("fails", 0) >= GROUP_FAILS or s.get("daily"))}
        if bad:
            lst = "; ".join(f"{g} x{s.get('fails', 1)} ({(s.get('err') or '')[:80]})"
                            for g, s in bad.items())
            prob("market group failing", f"Market refresh group(s) failing: {lst} — the rest of the "
                 "market layer keeps running; this data goes stale until fixed.", "market", "market")
        for t, age in (f.get("fund_age_h") or {}).items():
            if age > FUND_MAX_AGE_H and not ({"deep_warm", "deep_new"} if t == "fundamentals"
                                             else {"screener"}) & off:
                prob(f"{t} stale", f"Newest {t} row is {age:.0f}h old (rebuilds daily) — the screener "
                     "and stock pages are serving stale numbers.", "market", "market")

    # deep-only facts (Health page); absent in the hourly watchdog, so silent there
    stale_kinds = [(k, a) for k, a in (f.get("quote_age_h") or {}).items()
                   if a > MAX_QUOTE_AGE_H.get(k, 999)]
    if stale_kinds:
        lst = ", ".join(f"{k} {a:.0f}h" for k, a in stale_kinds)
        prob("market stale", f"Stale market data: {lst} — the market refresh lane is stalled while the "
             "rest of the pipeline runs; the Markets page shows per-group status.", "market", "market")
    frozen = [(k, a) for k, a in (f.get("blob_content_age_h") or {}).items()
              if a > BLOB_CONTENT_MAX_H.get(k, 999)]
    if frozen:
        lst = ", ".join(f"{k} (data dated {a / 24:.0f}d ago)" for k, a in frozen)
        prob("blob content frozen", f"Upstream content frozen: {lst} — the fetch still succeeds but "
             "the dates inside the payload stopped moving past a long-weekend budget; the upstream "
             "has likely stalled silently.", "market", "market")
    if f.get("src_active") and f.get("src_stale", 0) * 2 > f["src_active"]:
        prob("sources stalled", f"{f['src_stale']}/{f['src_active']} active sources not fetched in 3 h — "
             "fetching itself is stalled, not individual feeds; check whether pipeline runs are alive.",
             "sources", "sources")
    for fn, up in (f.get("edge_deploy") or {}).items():
        if up is False:
            prob("edge down", f"Edge function '{fn}' is unreachable (no HTTP answer or gone from the "
                 "gateway — not an auth error). Deleted, undeployed, or the project is paused. "
                 f"Redeploy: supabase functions deploy {fn}", "edge", "edge")
    if f.get("maintenance_on"):
        notes.append("maintenance banner is ON — every user sees it at boot. Deliberate?")

    dispatch = False
    if starved_ingest:
        msg = f"nothing ingested in {f['ingested_age']:.1f}h"
        if f.get("crash_loop"):
            pass  # already flagged; another dispatch would just crash again
        elif f.get("gh_active"):
            prob("frozen inside run", f"{msg} although a pipeline run is active — the freeze is inside "
                 "the run; check its logs.", "logs")
        else:
            dispatch = True
    return {"problems": p, "notes": notes, "dispatch": dispatch}


# ---------- main: the hourly watchdog ----------

def main():
    load_env()
    repo, token = os.environ["REPO"], os.environ["GH_TOKEN"]
    gh = f"https://api.github.com/repos/{repo}"
    hdrs = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}

    def call(url, method="GET", **kw):
        r = requests.request(method, url, headers=hdrs, timeout=60, **kw)
        r.raise_for_status()
        return r.json() if r.text else None

    f = gather(repo, token)
    v = evaluate(f)
    needs_you = [p["msg"] for p in v["problems"]]
    healed = []
    if v["dispatch"]:
        call(gh + "/actions/workflows/pipeline.yml/dispatches", "POST", json={"ref": "main"})
        healed.append(f"nothing ingested in {f.get('ingested_age', 0):.1f}h and no run was active — "
                      "dispatched a fresh pipeline run.")
    for n in v["notes"]:
        print("note:", n)

    if not needs_you:
        # healthy again: close the alarm so the NEXT incident can raise one
        # (a forgotten open issue used to suppress all future alerts)
        for i in call(gh + "/issues?labels=watchdog&state=open"):
            call(gh + f"/issues/{i['number']}/comments", "POST",
                 json={"body": "Auto-closed: pipeline healthy again on the next watchdog pass."})
            call(gh + f"/issues/{i['number']}", "PATCH", json={"state": "closed"})
            print(f"closed healed watchdog issue #{i['number']}")
        state = healed[0] if healed else (
            f"healthy: approved {f.get('approved_age', 0):.1f}h ago, feed top {f.get('top_age', 0):.1f}h old, "
            f"ai-starved {f.get('starved_cycles', '?')}, last run ok={f.get('last_run_ok')}")
        print("self-healed: " + state if healed else state)
        return 0

    # alert: at most one open watchdog issue; GitHub emails the assignee
    if not call(gh + "/issues?labels=watchdog&state=open"):
        body = "\n".join(["## Needs you", ""] + [f"- {m}" for m in needs_you]
                         + (["", "## Auto-healed", ""] + [f"- {h}" for h in healed] if healed else [])
                         + ["", "_Raised automatically by watchdog.yml (hourly)._"])
        call(gh + "/issues", "POST", json={"title": "Watchdog: pipeline needs attention", "body": body,
                                           "labels": ["watchdog"], "assignees": [repo.split("/")[0]]})
        try:  # only on issue creation, so a long incident pings once, not hourly
            ops_push("FinSwipe pipeline needs attention", needs_you[0])
        except Exception as e:  # noqa: BLE001
            print("ops push failed (issue+email still raised):", e)
    print("NEEDS ATTENTION:", " | ".join(needs_you))
    return 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "push":  # manual test: python pipeline/ops.py push "body"
        print(ops_push("FinSwipe ops test", sys.argv[2] if len(sys.argv) > 2 else "ops pushes work"))
    else:
        sys.exit(main())
