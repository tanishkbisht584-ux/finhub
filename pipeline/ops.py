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
import sys
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


def gather(repo, gh_token):
    """-> facts dict. A failed probe records its error under facts['errors'][area]
    and leaves that area's keys absent; evaluate() treats absent as unknown."""
    now = datetime.now(timezone.utc)
    f = {"errors": {}, "now": now.isoformat()}
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
        f["switches"] = load_config().get("switches") or {}
    except Exception as e:  # noqa: BLE001
        f["errors"]["supabase"] = str(e)

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
    return f


# ---------- evaluate: pure ----------

def evaluate(f):
    """facts -> {"problems": [{name, msg, fix}], "notes": [...], "dispatch": bool}.
    fix names the lever: repo | logs | keys | review | supabase | switch | None.
    dispatch = restarting the pipeline can actually help right now."""
    p, notes = [], []

    def prob(name, msg, fix=None):
        p.append({"name": name, "msg": msg, "fix": fix})

    if f.get("private"):
        prob("repo private", "Repo is PRIVATE — Actions free minutes will run out within a day; "
             "make it public or the pipeline stops.", "repo")
    if f.get("crash_loop"):
        prob("crash loop", "Pipeline is CRASH-LOOPING (3 straight failed runs) — restarting won't help. "
             f"Likely a broken secret, dependency, or commit. Logs: {f.get('last_gh_url')}", "logs")
    if f.get("starved"):
        prob("ai starved", f"AI STARVED: {f.get('starved_cycles')} recent cycles deferred stories for lack of "
             "quota — keys exhausted or the secrets hold a single key (GEMINI_API_KEY / GROQ_API_KEY are "
             "comma lists). Feed is a trickle.", "keys")
    if "supabase" in f["errors"]:
        prob("supabase", f"Supabase unreachable: {f['errors']['supabase']}. If Supabase itself is down, wait "
             "it out — the app serves its offline cache; if the project was paused or the key rotated, fix that.",
             "supabase")
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
                 "likely a dead model or exhausted keys.", "keys")

    if f.get("last_run_ok") is False:
        errs = "; ".join(f.get("last_run_errors") or [])[:300]
        prob("last run failed", f"Last pipeline run #{f.get('last_run_id')} FAILED "
             f"{f.get('last_run_age_h', 0):.1f}h ago: {errs or 'see its stdout'}", "logs")
    if f.get("stuck_run"):
        prob("run stuck", f"Run #{f['stuck_run']} has been open for over {RUN_STUCK_MIN} min — killed "
             "mid-run (job timeout or crash before the log PATCH).", "logs")
    if f.get("edge_calls", 0) >= EDGE_MIN_CALLS and f["edge_failed"] * 2 > f["edge_calls"]:
        prob("edge failing", f"Edge functions: {f['edge_failed']}/{f['edge_calls']} AI lane attempts failed "
             "in the last hour (qa/deepread). See the AI page's call log.", "keys")

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
