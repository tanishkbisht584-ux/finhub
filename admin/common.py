"""Shared plumbing + UI kit for every admin view.

Entry is admin/app.py (gate, theme, navigation); views live in admin/views/
and start with `from common import *`. Run: admin/launch.bat (local only —
this process holds the service_role key)."""
import hmac
import json
import os
import pathlib
import subprocess
import sys
import time
import traceback
from collections import Counter  # noqa: F401  (views use it)
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from html import escape  # noqa: F401
from urllib.parse import quote  # noqa: F401

import requests
import streamlit as st

REPO = pathlib.Path(__file__).resolve().parent.parent
URL = st.secrets["SUPABASE_URL"].rstrip("/")
KEY = st.secrets["SUPABASE_SERVICE_KEY"]
GITHUB_REPO = st.secrets.get("GITHUB_REPO", "tanishkbisht584-ux/finhub")
PROJECT_REF = URL.split("//")[-1].split(".")[0]  # hdgfdswzymfqgjqzqqve

# palette — mirrors .streamlit/config.toml
GREEN, RED, AMBER, BLUE, VIOLET, DIM = "#3ECF8E", "#F2555A", "#F0B429", "#5B9CF6", "#A78BFA", "#8E9792"
SURFACE, BORDER, TEXT = "#141817", "#262C2A", "#E7EAE8"

# ---------- navigation registry (one place; app.py + page_link use it) ----------

NAV = {
    "": [("overview", "Overview", ":material/space_dashboard:")],
    "Content": [("review", "Review", ":material/rate_review:"),
                ("stories", "Stories", ":material/article:"),
                ("sources", "Sources", ":material/rss_feed:")],
    "Operations": [("pipeline", "Pipeline", ":material/conveyor_belt:"),
                   ("alerts", "Alerts", ":material/notifications_active:"),
                   ("ai", "AI", ":material/psychology:"),
                   ("doctor", "Doctor", ":material/stethoscope:")],
    "People & app": [("users", "Users", ":material/group:"),
                     ("app_config", "App Config", ":material/tune:")],
}


def pages():
    """{slug: st.Page} — paths are relative to app.py's directory."""
    out = {}
    for _, items in NAV.items():
        for slug, title, icon in items:
            out[slug] = st.Page(f"views/{slug}.py", title=title, icon=icon,
                                url_path=slug, default=slug == "overview")
    return out


def page_link(slug, label=None, icon=None):
    st.page_link(pages()[slug], label=label or dict(
        (s, t) for items in NAV.values() for s, t, _ in items)[slug], icon=icon)


# ---------- Supabase (PostgREST, service_role) ----------

# one keep-alive pool for the whole server: Supabase sits in ap-northeast-1 and a
# cold TLS handshake per request was most of every page's latency
HTTP = requests.Session()
HTTP.mount("https://", requests.adapters.HTTPAdapter(pool_connections=12, pool_maxsize=12))


def sb_headers(extra=None):
    return {"apikey": KEY, "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json", **(extra or {})}


def sb(method, path, **kwargs):
    r = HTTP.request(method, f"{URL}/rest/v1/{path}",
                     headers=sb_headers(kwargs.pop("headers", {})), timeout=30, **kwargs)
    if not r.ok:  # PostgREST puts the reason in the body, not the status
        raise requests.HTTPError(f"{r.status_code} {path.split('?')[0]}: {r.text[:300]}",
                                 response=r)
    return r.json() if r.text else None


def count(path):
    """Row count without the rows — PostgREST exact count on a 1-row range.
    0 when the table is missing (schema gaps surface on Doctor > Schema)."""
    r = HTTP.get(f"{URL}/rest/v1/{path}",
                 headers=sb_headers({"Prefer": "count=exact", "Range": "0-0"}), timeout=30)
    try:
        return int(r.headers.get("Content-Range", "/0").split("/")[-1])
    except ValueError:
        return 0


@st.cache_data(ttl=20, show_spinner=False)
def counts(paths):
    """Many counts at once, in parallel, cached 20 s — the Overview used to make
    ~25 sequential round-trips (~10 s); this is one ~1 s burst."""
    with ThreadPoolExecutor(12) as ex:
        return dict(zip(paths, ex.map(count, paths)))


@st.cache_data(ttl=20, show_spinner=False)
def q(path):
    """Cached GET for aggregates/status reads. Lists a user edits stay on sb()."""
    return sb("GET", path)


@st.cache_data(ttl=20, show_spinner=False)
def q_try(path):
    """Cached sb_try — [] when the table is missing."""
    return sb_try(path)


@st.cache_data(ttl=60, show_spinner=False)
def schema_ok():
    """True when every table the cockpit reads exists (010 + 011 applied)."""
    with ThreadPoolExecutor(4) as ex:
        return all(ex.map(table_exists, ("app_config", "pipeline_runs", "edge_log", "quotes")))


def sb_all(path, page=1000):
    """GET past PostgREST's silent 1000-row cap (paginate every reader)."""
    rows, start = [], 0
    while True:
        chunk = HTTP.get(f"{URL}/rest/v1/{path}",
                         headers=sb_headers({"Range": f"{start}-{start + page - 1}"}), timeout=60)
        chunk.raise_for_status()
        got = chunk.json() if chunk.text else []
        rows += got
        if len(got) < page:
            return rows
        start += page


def sb_try(path, default=None):
    """GET that returns `default` ([] by default) when the table is missing —
    pages must render before a migration lands (Doctor > Schema shows the gap)."""
    try:
        return sb("GET", path)
    except requests.RequestException:
        return [] if default is None else default


def set_status(story_id, **fields):
    sb("PATCH", f"stories?id=eq.{story_id}", json=fields)
    refresh()


def refresh():
    """Drop every cached read and rerun — after any write."""
    st.cache_data.clear()
    st.rerun()


# ---------- app_config: three jsonb rows (pipeline / app / edge) ----------

@st.cache_data(ttl=10, show_spinner=False)
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
    cfg.clear()


def table_exists(name):
    """Schema probe: PostgREST answers 404 PGRST205 for a table it can't see."""
    return HTTP.get(f"{URL}/rest/v1/{name}?select=*&limit=0", headers=sb_headers(), timeout=30).ok


# ---------- pipeline code reuse (fetchers, FCM senders, constants) ----------

@st.cache_resource(show_spinner="loading pipeline modules …")
def pipeline_mod():
    """Import pipeline/run.py once per server; env comes from secrets + pipeline/.env."""
    for k in ("SUPABASE_URL", "SUPABASE_SERVICE_KEY", "FIREBASE_SERVICE_ACCOUNT_JSON",
              "SUPABASE_ACCESS_TOKEN"):
        if k in st.secrets:
            os.environ.setdefault(k, st.secrets[k])
    if str(REPO / "pipeline") not in sys.path:
        sys.path.insert(0, str(REPO / "pipeline"))
    import run
    run.load_env()
    return run


def ai_mod():
    pipeline_mod()
    import ai
    return ai


# ---------- Supabase Management API (migrations from the Doctor page) ----------

def mgmt_token():
    pipeline_mod()  # loads pipeline/.env into os.environ
    return st.secrets.get("SUPABASE_ACCESS_TOKEN") or os.environ.get("SUPABASE_ACCESS_TOKEN")


def run_sql(sql):
    """Execute SQL on the linked project via the Management API (needs an sbp_
    token). Returns the API's JSON (rows for SELECTs, [] for DDL)."""
    tok = mgmt_token()
    if not tok:
        raise RuntimeError("SUPABASE_ACCESS_TOKEN missing — add it to .streamlit/secrets.toml "
                           "or pipeline/.env (Supabase dashboard -> Account -> Access tokens)")
    r = requests.post(f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query",
                      headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
                      json={"query": sql}, timeout=180)
    if not r.ok:
        raise requests.HTTPError(f"Management API {r.status_code}: {r.text[:400]}", response=r)
    return r.json() if r.text else []


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


# ---------- time helpers ----------

def ago(ts):
    if not ts:
        return "never"
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    secs = (datetime.now(timezone.utc) - dt).total_seconds()
    mins = int(secs // 60)
    if mins < 2:
        return f"{int(secs)} s"
    return f"{mins} min" if mins < 120 else (f"{mins // 60} h" if mins < 2880 else f"{mins // 1440} d")


def iso_days_ago(n):
    return (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_hours_ago(n):
    return (datetime.now(timezone.utc) - timedelta(hours=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_age(r, field="started_at"):
    return (datetime.now(timezone.utc)
            - datetime.fromisoformat(r[field].replace("Z", "+00:00"))).total_seconds()


def jdump(obj):
    return json.dumps(obj, indent=1, ensure_ascii=False)


# ---------- UI kit ----------

CSS = f"""
<style>
.block-container {{ padding: 1.3rem 2.2rem 4rem 2.2rem; max-width: 1440px; }}
[data-testid="stSidebar"] {{ min-width: 248px; max-width: 248px; }}
[data-testid="stSidebarNav"] a {{ font-size: 0.93rem; padding: 0.3rem 0.6rem; }}
[data-testid="stSidebarNavSeparator"] {{ display: none; }}
[data-testid="stSidebarNav"] [data-testid="stSidebarNavSectionHeader"],
[data-testid="stSidebarNav"] header {{ font-size: 0.7rem; letter-spacing: .09em; text-transform: uppercase;
  color: {DIM}; font-weight: 600; margin-top: .6rem; }}
h1, h2, h3 {{ letter-spacing: -0.01em; }}
div[data-testid="stExpander"] details {{ border-radius: 10px; }}
div[data-testid="stExpander"] summary {{ font-size: 0.92rem; }}
[data-testid="stMetric"] {{ background: {SURFACE}; border: 1px solid {BORDER}; border-radius: 10px; padding: 10px 14px; }}
.fs-head {{ display:flex; align-items:flex-end; justify-content:space-between; gap:16px; flex-wrap:wrap;
  padding-bottom: 12px; margin-bottom: 8px; border-bottom: 1px solid {BORDER}; }}
.fs-title {{ font-size: 1.45rem; font-weight: 700; line-height: 1.2; letter-spacing: -0.015em; }}
.fs-sub {{ color: {DIM}; font-size: 0.88rem; margin-top: 3px; }}
.fs-pills {{ display:flex; flex-wrap:wrap; gap:6px; justify-content:flex-end; align-items:center; }}
.fs-pill {{ display:inline-flex; align-items:center; gap:6px; padding: 2px 10px; border-radius: 999px;
  font-size: 0.78rem; font-weight: 600; line-height: 1.5; white-space: nowrap; border: 1px solid; }}
.fs-dot {{ width:7px; height:7px; border-radius:50%; display:inline-block; }}
.fs-kpis {{ display:grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 12px 0 6px; }}
.fs-kpi {{ background: {SURFACE}; border: 1px solid {BORDER}; border-radius: 10px; padding: 11px 14px 10px; min-width: 0;
  border-left-width: 3px; }}
.fs-kpi .l {{ font-size: 0.7rem; text-transform: uppercase; letter-spacing: .08em; color: {DIM}; font-weight: 600; }}
.fs-kpi .v {{ font-size: 1.5rem; font-weight: 700; line-height: 1.25; margin-top: 2px; font-variant-numeric: tabular-nums;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.fs-kpi .s {{ font-size: 0.76rem; color: {DIM}; margin-top: 1px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.fs-sec {{ display:flex; align-items:baseline; gap:10px; margin: 22px 0 6px; }}
.fs-sec .t {{ font-size: 0.74rem; text-transform: uppercase; letter-spacing: .1em; font-weight: 700; color: {TEXT}; }}
.fs-sec .h {{ font-size: 0.82rem; color: {DIM}; }}
.fs-kv {{ font-size: 0.9rem; }}
.fs-kv div {{ display:flex; align-items:baseline; gap:8px; padding: 3px 0; }}
.fs-kv .k {{ color: {DIM}; white-space: nowrap; }}
.fs-kv .dots {{ flex:1; border-bottom: 1px dotted {BORDER}; transform: translateY(-4px); }}
.fs-kv .v {{ font-weight: 600; font-variant-numeric: tabular-nums; white-space: nowrap; }}
.fs-bars div.row {{ display:flex; align-items:center; margin: 3px 0; gap: 8px; }}
.fs-bars .l {{ width: 150px; color: {DIM}; font-size: 0.78rem; overflow:hidden; white-space:nowrap; text-overflow:ellipsis; flex: none; }}
.fs-bars .b {{ height: 12px; border-radius: 3px; opacity: .9; }}
.fs-bars .n {{ font-size: 0.8rem; font-weight: 600; font-variant-numeric: tabular-nums; }}
.fs-note {{ border-left: 3px solid; padding: 8px 12px; border-radius: 6px; margin: 6px 0; font-size: 0.88rem;
  background: {SURFACE}; }}
.fs-muted {{ color: {DIM}; font-size: 0.85rem; }}
.fs-card-title {{ font-weight: 600; font-size: 0.98rem; line-height: 1.35; }}
.fs-card-meta {{ color: {DIM}; font-size: 0.8rem; margin-top: 2px; }}
</style>
"""


def inject_css():
    st.markdown(CSS, unsafe_allow_html=True)


def _tint(c):
    return f"color-mix(in srgb, {c} 14%, transparent)"


def pill(label, ok=True, color=None):
    """Inline status pill — GREEN ok / RED not ok unless a color is forced."""
    c = color or (GREEN if ok else RED)
    return (f"<span class='fs-pill' style='color:{c};border-color:color-mix(in srgb,{c} 45%,transparent);"
            f"background:{_tint(c)}'><span class='fs-dot' style='background:{c}'></span>"
            f"{escape(str(label))}</span>")


def header(title, subtitle="", pills=()):
    """Page header: title + one-line purpose on the left, status pills on the right."""
    st.markdown(
        f"<div class='fs-head'><div><div class='fs-title'>{escape(title)}</div>"
        f"<div class='fs-sub'>{escape(subtitle)}</div></div>"
        f"<div class='fs-pills'>{''.join(pills)}</div></div>", unsafe_allow_html=True)


def section(title, hint=""):
    st.markdown(f"<div class='fs-sec'><span class='t'>{escape(title)}</span>"
                f"<span class='h'>{escape(hint)}</span></div>", unsafe_allow_html=True)


def kpis(items):
    """items: (label, value, sub, color) — a row of stat tiles."""
    cells = []
    for label, value, *rest in items:
        sub = rest[0] if rest else ""
        color = rest[1] if len(rest) > 1 and rest[1] else BORDER
        cells.append(f"<div class='fs-kpi' style='border-left-color:{color}'><div class='l'>{escape(str(label))}</div>"
                     f"<div class='v'>{escape(str(value))}</div><div class='s'>{escape(str(sub))}</div></div>")
    st.markdown(f"<div class='fs-kpis'>{''.join(cells)}</div>", unsafe_allow_html=True)


def note(text, color=AMBER, html=False):
    body = text if html else escape(str(text))
    st.markdown(f"<div class='fs-note' style='border-color:{color}'>{body}</div>", unsafe_allow_html=True)


def kv_rows(rows):
    """'Label ........ value' ledger lines."""
    st.markdown("<div class='fs-kv'>" + "".join(
        f"<div><span class='k'>{escape(str(k))}</span><span class='dots'></span>"
        f"<span class='v'>{escape(str(v))}</span></div>" for k, v in rows) + "</div>",
        unsafe_allow_html=True)


def html_bars(data, color):
    """Ledger-style bars, no chart library — st.bar_chart drags in altair,
    which is broken on this machine's Python 3.14 (TypedDict closed=)."""
    peak = max(data.values(), default=0) or 1
    rows = "".join(
        f"<div class='row'><span class='l' title='{escape(str(label))}'>{escape(str(label))}</span>"
        f"<div class='b' style='background:{color};width:{max(2, v * 100 // peak)}%'></div>"
        f"<span class='n'>{v}</span></div>" for label, v in data.items())
    st.markdown(f"<div class='fs-bars'>{rows}</div>", unsafe_allow_html=True)


def impact_span(score):
    color = RED if (score or 0) >= 8 else DIM
    return f"<span style='color:{color};font-weight:700'>Impact {score if score is not None else '–'}</span>"


def error_card(exc):
    """Friendly failure block with the most likely cause + the traceback."""
    msg = str(exc)
    hint = ""
    if "PGRST205" in msg or "does not exist" in msg or "42703" in msg or "42P01" in msg:
        hint = "A table or column is missing — a migration has not been applied. Open Doctor › Schema."
    elif "GitHub 401" in msg or "GitHub 403" in msg:
        hint = "GitHub token rejected — set GITHUB_TOKEN in .streamlit/secrets.toml."
    elif "Management API" in msg:
        hint = "Supabase Management API refused the call — check SUPABASE_ACCESS_TOKEN."
    elif "ConnectionError" in type(exc).__name__ or "Max retries" in msg:
        hint = "Network: Supabase / GitHub unreachable from this machine."
    st.markdown(f"<div class='fs-note' style='border-color:{RED}'><b>This page hit an error.</b> "
                f"{escape(hint)}<br><code>{escape(type(exc).__name__)}: {escape(msg[:400])}</code></div>",
                unsafe_allow_html=True)
    if hint.startswith("A table"):
        page_link("doctor", "→ Doctor › Schema", icon=":material/stethoscope:")
    with st.expander("traceback"):
        st.code("".join(traceback.format_exception(exc)), language=None)


# ---------- knobs (pipeline constants overridable from the admin) ----------

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
                            key=state_key, width="stretch",
                            column_config={"knob": st.column_config.TextColumn(width="medium"),
                                           "default": st.column_config.TextColumn(width="large"),
                                           "override": st.column_config.TextColumn(width="large")})
    c1, c2, _ = st.columns([1, 1, 4])
    if c1.button("Save overrides", key=f"{state_key}_save", type="primary"):
        for r in edited:
            v = str(r["override"]).strip()
            if v:
                knobs[r["knob"]] = v
            else:
                knobs.pop(r["knob"], None)
        cfg_save("pipeline", {**pc, "knobs": knobs})
        refresh()
    if c2.button("Reset shown", key=f"{state_key}_reset", help="Drop these overrides → code defaults"):
        for k in keys:
            knobs.pop(k, None)
        cfg_save("pipeline", {**pc, "knobs": knobs})
        refresh()
    return knobs


def effective_knob(key):
    """Override if set, else code default (what the pipeline is actually using)."""
    v = {str(k).upper(): v for k, v in (cfg("pipeline").get("knobs") or {}).items()}.get(key)
    return v if v not in (None, "") else knob_default(key)


def runs_table(runs, height="auto"):
    """Compact pipeline_runs table: one line per run."""
    rows = []
    for r in runs:
        dur = (round((datetime.fromisoformat(r["finished_at"].replace("Z", "+00:00"))
                      - datetime.fromisoformat(r["started_at"].replace("Z", "+00:00"))).total_seconds())
               if r.get("finished_at") else None)
        c = r.get("counts") or {}
        rows.append({"run": r["id"], "started": ago(r["started_at"]) + " ago",
                     "result": "ok" if r.get("ok") else ("running" if r.get("ok") is None else "FAIL"),
                     "secs": dur, "fetched": c.get("fetched"), "new": c.get("new"),
                     "processed": c.get("processed"), "flagged": c.get("flagged"),
                     "alerted": c.get("alerted"), "approved": c.get("approved"),
                     "errors": len(r.get("errors") or []), "host": r.get("host")})
    st.dataframe(rows, hide_index=True, width="stretch", height=height)


def edge_table(rows, height=320):
    st.dataframe([{"when": ago(r["created_at"]) + " ago", "fn": r["fn"], "lane": r["lane"],
                   "ok": "ok" if r["ok"] else "FAIL", "status": r["status"], "ms": r["ms"],
                   "error": (r["error"] or "")[:160]} for r in rows],
                 hide_index=True, width="stretch", height=height)


def keys_table(rows):
    st.dataframe([{"key": l, "id": m, "status": "unset" if ok is None else ("ok" if ok else "FAIL"),
                   "detail": d} for l, m, ok, d in rows], hide_index=True, width="stretch")
