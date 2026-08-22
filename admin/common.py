"""Shared plumbing for every admin page — one password gate, one PostgREST
client, one config reader. Pages start with `from common import *; gate()`.
Run: admin/launch.bat (local only; this holds the service_role key)."""
import hmac
import json
import os
import pathlib
import subprocess
import sys
import time
from collections import Counter  # noqa: F401  (pages use it)
from datetime import datetime, timedelta, timezone
from html import escape  # noqa: F401
from urllib.parse import quote  # noqa: F401

import requests
import streamlit as st

REPO = pathlib.Path(__file__).resolve().parent.parent
URL = st.secrets["SUPABASE_URL"].rstrip("/")
KEY = st.secrets["SUPABASE_SERVICE_KEY"]
GITHUB_REPO = st.secrets.get("GITHUB_REPO", "tanishkbisht584-ux/finhub")

GREEN, RED, AMBER, DIM = "#3ECF8E", "#E5484D", "#E5A84D", "#9BA09C"


def gate(title="FinSwipe Admin"):
    """First call on every page: page config + one password per browser session."""
    st.set_page_config(page_title=title, layout="wide")
    if st.session_state.get("authed"):
        return
    pw = st.text_input("Admin password", type="password")
    if not hmac.compare_digest(pw, st.secrets["ADMIN_PASSWORD"]):
        if pw:  # wrong guess (not the initial empty render): slow brute force
            time.sleep(1)
        st.stop()
    st.session_state["authed"] = True
    st.rerun()


# ---------- Supabase (PostgREST, service_role) ----------

def _headers(extra=None):
    return {"apikey": KEY, "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json", **(extra or {})}


def sb(method, path, **kwargs):
    r = requests.request(method, f"{URL}/rest/v1/{path}",
                         headers=_headers(kwargs.pop("headers", {})), timeout=30, **kwargs)
    if not r.ok:  # PostgREST puts the reason in the body, not the status
        raise requests.HTTPError(f"{r.status_code} {path.split('?')[0]}: {r.text[:300]}",
                                 response=r)
    return r.json() if r.text else None


def count(path):
    """Row count without the rows — PostgREST exact count on a 1-row range."""
    r = requests.get(f"{URL}/rest/v1/{path}",
                     headers=_headers({"Prefer": "count=exact", "Range": "0-0"}), timeout=30)
    try:
        return int(r.headers.get("Content-Range", "/0").split("/")[-1])
    except ValueError:
        return 0


def set_status(story_id, **fields):
    sb("PATCH", f"stories?id=eq.{story_id}", json=fields)
    st.rerun()


# ---------- app_config: three jsonb rows (pipeline / app / edge) ----------

def cfg(key):
    """{} when the row (or the table, pre-migration-010) is missing."""
    try:
        rows = sb("GET", f"app_config?select=value&key=eq.{key}")
        return rows[0]["value"] if rows else {}
    except requests.RequestException:
        return {}


def cfg_save(key, value):
    sb("POST", "app_config", json={"key": key, "value": value,
                                   "updated_at": datetime.now(timezone.utc).isoformat()},
       headers={"Prefer": "resolution=merge-duplicates"})


# ---------- pipeline code reuse (fetchers, FCM senders, constants) ----------

@st.cache_resource
def pipeline_mod():
    """Import pipeline/run.py once per server; env comes from secrets + pipeline/.env."""
    for k in ("SUPABASE_URL", "SUPABASE_SERVICE_KEY", "FIREBASE_SERVICE_ACCOUNT_JSON"):
        if k in st.secrets:
            os.environ.setdefault(k, st.secrets[k])
    sys.path.insert(0, str(REPO / "pipeline"))
    import run
    run.load_env()
    return run


def ai_mod():
    pipeline_mod()
    import ai
    return ai


# ---------- GitHub (workflow runs / dispatch) ----------

def gh_token():
    tok = st.secrets.get("GITHUB_TOKEN") or st.session_state.get("gh_token")
    if tok:
        return tok
    try:  # no gh CLI on this machine; git's credential store has a token
        out = subprocess.run(["git", "credential", "fill"],
                             input="protocol=https\nhost=github.com\n\n",
                             capture_output=True, text=True, timeout=15).stdout
        tok = dict(l.split("=", 1) for l in out.splitlines() if "=" in l).get("password")
    except Exception:
        tok = None
    st.session_state["gh_token"] = tok
    return tok


def gh(method, path, **kwargs):
    r = requests.request(method, f"https://api.github.com/repos/{GITHUB_REPO}{path}",
                         headers={"Authorization": f"Bearer {gh_token()}",
                                  "Accept": "application/vnd.github+json"},
                         timeout=30, **kwargs)
    if not r.ok:
        raise requests.HTTPError(f"GitHub {r.status_code}: {r.text[:300]}", response=r)
    return r.json() if r.text else None


# ---------- display helpers ----------

def ago(ts):
    if not ts:
        return "never"
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    secs = (datetime.now(timezone.utc) - dt).total_seconds()
    mins = int(secs // 60)
    if mins < 2:
        return f"{int(secs)} s"
    return f"{mins} min" if mins < 120 else (f"{mins // 60} h" if mins < 2880 else f"{mins // 1440} d")


def impact_span(score):
    color = RED if (score or 0) >= 8 else DIM
    return f"<span style='color:{color};font-weight:700'>Impact {score if score is not None else '–'}</span>"


def iso_days_ago(n):
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_hours_ago(n):
    return (datetime.now(timezone.utc) - timedelta(hours=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


def pill(label, ok=True, color=None):
    """Inline status pill — GREEN ok / RED not ok unless a color is forced."""
    c = color or (GREEN if ok else RED)
    return (f"<span style='display:inline-block;margin:2px 6px 2px 0;padding:2px 8px;"
            f"border:1px solid {c};border-radius:10px;color:{c};font-size:0.8em'>"
            f"{escape(str(label))}</span>")


def kv_rows(rows):
    """'Label ........ value' lines, the ledger look."""
    st.markdown("<br>".join(
        f"{k} <span style='float:right;font-weight:700'>{v}</span>" for k, v in rows),
        unsafe_allow_html=True)


def html_bars(data, color):
    """Ledger-style bars, no chart library — st.bar_chart drags in altair,
    which is broken on this machine's Python 3.14 (TypedDict closed=)."""
    peak = max(data.values(), default=0) or 1
    rows = []
    for label, v in data.items():
        w = max(2, v * 100 // peak)
        rows.append(
            f"<div style='display:flex;align-items:center;margin:3px 0'>"
            f"<span style='width:140px;color:{DIM};font-size:0.75em;overflow:hidden;"
            f"white-space:nowrap;text-overflow:ellipsis'>{escape(str(label))}</span>"
            f"<div style='background:{color};height:14px;width:{w}%;opacity:0.85'></div>"
            f"<span style='margin-left:8px;font-size:0.8em;font-weight:700'>{v}</span></div>")
    st.markdown("".join(rows), unsafe_allow_html=True)


def jdump(obj):
    return json.dumps(obj, indent=1, ensure_ascii=False)


def sb_try(path, default=None):
    """GET that returns `default` ([] by default) when the table is missing —
    pre-migration-010 pages must still render."""
    try:
        return sb("GET", path)
    except requests.RequestException:
        return [] if default is None else default


def knob_default(key):
    """Code default for a pipeline knob / model env, read off the imported modules."""
    run, ai = pipeline_mod(), ai_mod()
    if key == "AI_RPM_PER_LANE":
        return ai.RPM_PER_LANE
    if key == "GEMINI_MODELS":
        return ai.GEMINI_MODELS
    for _, _, model_env, models in ai.FALLBACKS:
        if model_env == key:
            return models
    return getattr(run, key, "")


def knob_editor(keys, state_key):
    """Override table for pipeline knobs (app_config.pipeline.knobs). Blank
    override = code default. Keys stored upper-case; run.apply_config reads them."""
    pc = cfg("pipeline")
    knobs = {str(k).upper(): v for k, v in (pc.get("knobs") or {}).items()}
    rows = [{"knob": k, "default": str(knob_default(k)), "override": str(knobs.get(k, ""))}
            for k in keys]
    edited = st.data_editor(rows, disabled=["knob", "default"], hide_index=True,
                            key=state_key, width="stretch")
    c1, c2, _ = st.columns([1, 1, 4])
    if c1.button("Save overrides", key=f"{state_key}_save", type="primary"):
        for r in edited:
            v = str(r["override"]).strip()
            if v:
                knobs[r["knob"]] = v
            else:
                knobs.pop(r["knob"], None)
        cfg_save("pipeline", {**pc, "knobs": knobs})
        st.rerun()
    if c2.button("Reset shown", key=f"{state_key}_reset", help="Drop these overrides -> code defaults"):
        for k in keys:
            knobs.pop(k, None)
        cfg_save("pipeline", {**pc, "knobs": knobs})
        st.rerun()
    return knobs


def effective_knob(key):
    """Override if set, else code default (what the pipeline is actually using)."""
    v = {str(k).upper(): v for k, v in (cfg("pipeline").get("knobs") or {}).items()}.get(key)
    return v if v not in (None, "") else knob_default(key)


def run_age(r, field="started_at"):
    return (datetime.now(timezone.utc)
            - datetime.fromisoformat(r[field].replace("Z", "+00:00"))).total_seconds()


def runs_table(runs):
    """Compact pipeline_runs table: one line per run."""
    rows = []
    for r in runs:
        dur = (round((datetime.fromisoformat(r["finished_at"].replace("Z", "+00:00"))
                      - datetime.fromisoformat(r["started_at"].replace("Z", "+00:00"))).total_seconds())
               if r.get("finished_at") else None)
        c = r.get("counts") or {}
        rows.append({"started": ago(r["started_at"]) + " ago",
                     "ok": "ok" if r.get("ok") else ("..." if r.get("ok") is None else "FAIL"),
                     "secs": dur, "fetched": c.get("fetched"), "new": c.get("new"),
                     "processed": c.get("processed"), "flagged": c.get("flagged"),
                     "alerted": c.get("alerted"), "approved": c.get("approved"),
                     "errors": len(r.get("errors") or []), "host": r.get("host")})
    st.dataframe(rows, hide_index=True, width="stretch")
