"""Integrations: the registry of every external secret FinSwipe depends on and
the adapters for the stores that hold them. Pure Python (no Streamlit) so it
is unit-testable — admin/views/integrations.py is the UI on top.

Stores:  EnvFile (pipeline/.env)  ·  TomlFile (.streamlit/secrets.toml)
         GitHubSecrets (Actions secrets = what CI runs with)
         EdgeSecrets (Supabase edge-function secrets = what qa/deepread read)
None of the remote stores can be read back — we only ever see names + dates.
Values are never logged; the change log keeps fingerprints."""
import base64
import json
import pathlib
import re
from datetime import datetime, timezone

import requests

# ---------- registry ----------
# shape: single | list (comma) | json.  targets: env (pipeline/.env), gh (Actions
# secret), edge (edge-function secret, possibly under a different name), toml
# (.streamlit/secrets.toml — what this admin itself reads).
SECRETS = [
    dict(name="SUPABASE_URL", group="Supabase", shape="single", probe=None,
         targets={"env": True, "gh": True, "toml": True},
         readers="pipeline (CI), admin, watchdog; edge functions get it built in",
         console="https://supabase.com/dashboard/project/{ref}/settings/api",
         note="Project URL. Changing it = moving to another Supabase project (new DB)."),
    dict(name="SUPABASE_SERVICE_KEY", group="Supabase", shape="single", probe="supabase",
         targets={"env": True, "gh": True, "toml": True},
         readers="pipeline (CI), admin, watchdog (service_role, bypasses RLS)",
         console="https://supabase.com/dashboard/project/{ref}/settings/api-keys",
         note="service_role key. Rotate in the dashboard, then paste the new one here — every store at once."),
    dict(name="SUPABASE_ACCESS_TOKEN", group="Supabase", shape="single", probe="mgmt",
         targets={"env": True, "toml": True},
         readers="admin only (Doctor › Schema migrations, this page's edge-secret sync)",
         console="https://supabase.com/dashboard/account/tokens",
         note="Personal access token (sbp_…). Management API; never leaves this machine."),
    dict(name="GEMINI_API_KEY", group="Gemini", shape="list", probe="GEMINI_API_KEY",
         targets={"env": True, "gh": True, "edge": "GEMINI_API_KEYS"},
         readers="pipeline summariser + chief editor (CI); edge qa/deepread (as GEMINI_API_KEYS)",
         console="https://aistudio.google.com/apikey",
         note="Free tier is metered PER GOOGLE ACCOUNT (~15 RPM, daily cap per model). "
              "Add one key from each Google account you own; two keys from the same account share one pool."),
    dict(name="GROQ_API_KEY", group="Groq", shape="list", probe="GROQ_API_KEY",
         targets={"env": True, "gh": True, "edge": "GROQ_API_KEYS"},
         readers="pipeline failover lanes (CI); edge qa planner/fast lane (as GROQ_API_KEYS)",
         console="https://console.groq.com/keys",
         note="Free daily token budget per account. Groq is Cloudflare-blocked from this PC — local probes "
              "say 'unreachable'; CI usage on the Matrix tab is the real check."),
    dict(name="OPENROUTER_API_KEY", group="OpenRouter", shape="list", probe="OPENROUTER_API_KEY",
         targets={"env": True, "gh": True},
         readers="pipeline last-resort lane (CI)",
         console="https://openrouter.ai/settings/keys",
         note="Free :free models only; rate-limited per account."),
    dict(name="TAVILY_API_KEY", group="Tavily", shape="single", probe="tavily",
         targets={"edge": "TAVILY_API_KEY", "env": True},
         readers="edge qa tier-2 web search only",
         console="https://app.tavily.com/home",
         note="1,000 searches/month free. Unset = Ask answers from our own stories only."),
    dict(name="FIREBASE_SERVICE_ACCOUNT_JSON", group="Firebase", shape="json", probe="firebase",
         targets={"gh": True, "toml": True, "env": True},
         readers="pipeline alerts + personal pushes (CI), watchdog ops pushes, admin manual sends",
         console="https://console.firebase.google.com/project/_/settings/serviceaccounts/adminsdk",
         note="Service-account JSON (Project settings → Service accounts → Generate new private key). "
              "Upload the file; it is stored as one line."),
    dict(name="GITHUB_TOKEN", group="GitHub", shape="single", probe="github",
         targets={"toml": True},
         readers="admin only (Run now, Doctor dispatch, this page's GitHub-secret writes)",
         console="https://github.com/settings/tokens",
         note="Classic PAT with `repo` + `workflow`, or fine-grained with Actions + Secrets read/write. "
              "Falls back to `git credential fill` when unset."),
    dict(name="GNEWS_API_KEY", group="News APIs", shape="list", probe="GNEWS_API_KEY",
         targets={"env": True, "gh": True}, readers="pipeline gnews_api sources (CI), round-robin",
         console="https://gnews.io/dashboard", note="100 requests/day per account; each probe spends one."),
    dict(name="NEWSDATA_API_KEY", group="News APIs", shape="list", probe="NEWSDATA_API_KEY",
         targets={"env": True, "gh": True}, readers="pipeline newsdata sources (CI), round-robin",
         console="https://newsdata.io/dashboard", note="200 requests/day per account; each probe spends one."),
    dict(name="MARKETAUX_API_KEY", group="News APIs", shape="list", probe="MARKETAUX_API_KEY",
         targets={"env": True, "gh": True}, readers="pipeline marketaux sources (CI), round-robin",
         console="https://www.marketaux.com/account/dashboard", note="100 requests/day; each probe spends one."),
    dict(name="FRED_API_KEY", group="FRED", shape="list", probe="FRED_API_KEY",
         targets={"env": True, "gh": True}, readers="pipeline market.py macro series (CI) — first key only",
         console="https://fredaccount.stlouisfed.org/apikeys", note="Free, generous; one key is plenty."),
    dict(name="REDDIT_CLIENT_ID", group="Reddit", shape="single", probe=None,
         targets={"env": True, "gh": True}, readers="pipeline market.py reddit group (CI) + probe workflow",
         console="https://www.reddit.com/prefs/apps",
         note="Create a 'script' app; the id is the short string under the app name. Free, 100 req/10 min."),
    dict(name="REDDIT_CLIENT_SECRET", group="Reddit", shape="single", probe="REDDIT_CLIENT_SECRET",
         targets={"env": True, "gh": True}, readers="pipeline market.py reddit group (CI) + probe workflow",
         console="https://www.reddit.com/prefs/apps",
         note="The app's secret; the probe does a client_credentials token call with id + secret."),
]
# build-time only — shown for completeness, not editable here
BUILD_TIME = [
    ("SUPABASE_PUBLISHABLE_KEY", "app (dart-define at build)", "app/lib/main.dart"),
    ("POSTHOG project token", "app (const in source)", "app/lib/analytics.dart"),
    ("APP_VERSION", "app (dart-define at build)", "app/lib/theme.dart"),
]
MODEL_KNOBS = ("GEMINI_MODELS", "GROQ_MODEL", "OPENROUTER_MODEL", "AI_RPM_PER_LANE")
PLURAL = {"GEMINI_API_KEY": "GEMINI_API_KEYS", "GROQ_API_KEY": "GROQ_API_KEYS"}
GROUP_ORDER = ["Supabase", "Gemini", "Groq", "OpenRouter", "Tavily", "Firebase", "GitHub", "News APIs", "FRED", "Custom"]


def registry(custom=None):
    """Built-in entries + custom ones (from app_config.integrations.custom)."""
    out = list(SECRETS)
    for c in custom or []:
        if c.get("name") and c["name"] not in {s["name"] for s in out}:
            out.append({"group": "Custom", "shape": "single", "probe": None, "targets": {"env": True},
                        "readers": "", "console": "", "note": "", **c})
    return out


def by_name(name, custom=None):
    return next((s for s in registry(custom) if s["name"] == name), None)


def edge_name(entry):
    t = entry["targets"].get("edge")
    return t if isinstance(t, str) else (entry["name"] if t else None)


# ---------- value helpers ----------

def fingerprint(value):
    v = (value or "").strip()
    if len(v) <= 12:
        return "•" * len(v)
    return f"{v[:8]}…{v[-4:]}"


def split_list(value):
    return [k.strip() for k in (value or "").split(",") if k.strip()]


def join_list(keys):
    return ",".join(k.strip() for k in keys if k and k.strip())


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------- local file stores ----------

class EnvFile:
    """KEY=VALUE lines (pipeline/.env). put() rewrites in place: comments and
    order kept, first occurrence replaced, later duplicates dropped, new keys
    appended. Matches run.load_env()'s first-wins parse."""

    def __init__(self, path):
        self.path = pathlib.Path(path)

    def _lines(self):
        return self.path.read_text(encoding="utf8").splitlines() if self.path.exists() else []

    def read(self):
        out = {}
        for line in self._lines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, _, v = line.partition("=")
                out.setdefault(k.strip(), v.strip())
        return out

    def duplicates(self):
        seen, dup = set(), []
        for line in self._lines():
            if "=" in line and not line.lstrip().startswith("#"):
                k = line.partition("=")[0].strip()
                if k in seen and k not in dup:
                    dup.append(k)
                seen.add(k)
        return dup

    def list(self):
        return {k: {"set": bool(v), "updated": None} for k, v in self.read().items()}

    def put(self, name, value):
        value = str(value).replace("\n", " ").strip()  # one line, like load_env expects
        out, done = [], False
        for line in self._lines():
            if "=" in line and not line.lstrip().startswith("#") and line.partition("=")[0].strip() == name:
                if not done:
                    out.append(f"{name}={value}")
                    done = True
                continue  # drop duplicates
            out.append(line)
        if not done:
            out.append(f"{name}={value}")
        self.path.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf8")

    def delete(self, name):
        out = [l for l in self._lines()
               if not ("=" in l and not l.lstrip().startswith("#") and l.partition("=")[0].strip() == name)]
        self.path.write_text("\n".join(out).rstrip("\n") + "\n" if out else "", encoding="utf8")


class TomlFile:
    """Flat `KEY = "value"` lines (.streamlit/secrets.toml). Values are written
    as json.dumps(value) — a valid TOML basic string, including for JSON blobs."""
    _line = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=')

    def __init__(self, path):
        self.path = pathlib.Path(path)

    def _lines(self):
        return self.path.read_text(encoding="utf8").splitlines() if self.path.exists() else []

    def names(self):
        return [m.group(1) for l in self._lines() if (m := self._line.match(l)) and not l.lstrip().startswith("#")]

    def list(self):
        return {n: {"set": True, "updated": None} for n in self.names()}

    def put(self, name, value):
        new = f"{name} = {json.dumps(str(value), ensure_ascii=True)}"
        out, done = [], False
        for line in self._lines():
            m = self._line.match(line)
            if m and not line.lstrip().startswith("#") and m.group(1) == name:
                if not done:
                    out.append(new)
                    done = True
                continue
            out.append(line)
        if not done:
            out.append(new)
        self.path.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf8")

    def delete(self, name):
        out = [l for l in self._lines()
               if not ((m := self._line.match(l)) and not l.lstrip().startswith("#") and m.group(1) == name)]
        self.path.write_text("\n".join(out).rstrip("\n") + "\n" if out else "", encoding="utf8")


# ---------- GitHub Actions secrets ----------

class GitHubSecrets:
    def __init__(self, repo, token, session=None):
        self.repo, self.token = repo, token
        self.http = session or requests.Session()

    def _call(self, method, path, **kw):
        r = self.http.request(method, f"https://api.github.com/repos/{self.repo}{path}",
                              headers={"Authorization": f"Bearer {self.token}",
                                       "Accept": "application/vnd.github+json"}, timeout=30, **kw)
        if not r.ok:
            raise requests.HTTPError(f"GitHub {r.status_code} {path}: {r.text[:200]}", response=r)
        return r

    def scopes(self):
        """Classic-token scopes header ('' for fine-grained tokens)."""
        r = self.http.get("https://api.github.com/user", headers={"Authorization": f"Bearer {self.token}"}, timeout=30)
        r.raise_for_status()
        return r.headers.get("X-OAuth-Scopes", ""), r.json().get("login")

    def list(self):
        out, page = {}, 1
        while True:
            j = self._call("GET", f"/actions/secrets?per_page=100&page={page}").json()
            for s in j.get("secrets", []):
                out[s["name"]] = {"set": True, "updated": s.get("updated_at")}
            if len(j.get("secrets", [])) < 100:
                return out
            page += 1

    def put(self, name, value):
        from nacl import encoding, public  # pynacl — only needed for writes
        pk = self._call("GET", "/actions/secrets/public-key").json()
        sealed = public.SealedBox(public.PublicKey(pk["key"].encode(), encoding.Base64Encoder()))
        enc = base64.b64encode(sealed.encrypt(str(value).encode())).decode()
        self._call("PUT", f"/actions/secrets/{name}", json={"encrypted_value": enc, "key_id": pk["key_id"]})

    def delete(self, name):
        self._call("DELETE", f"/actions/secrets/{name}")

    # pipeline restart: a queued/running job keeps the secrets it started with
    def restart_pipeline(self, workflow="pipeline.yml"):
        runs = self._call("GET", f"/actions/workflows/{workflow}/runs?per_page=10").json()["workflow_runs"]
        cancelled = 0
        for r in runs:
            if r["status"] in ("queued", "in_progress", "waiting"):
                self._call("POST", f"/actions/runs/{r['id']}/cancel")
                cancelled += 1
        self._call("POST", f"/actions/workflows/{workflow}/dispatches", json={"ref": "main"})
        return cancelled


# ---------- Supabase edge-function secrets (Management API) ----------

class EdgeSecrets:
    def __init__(self, ref, token, session=None):
        self.ref, self.token = ref, token
        self.http = session or requests.Session()

    def _call(self, method, path="", **kw):
        r = self.http.request(method, f"https://api.supabase.com/v1/projects/{self.ref}/secrets{path}",
                              headers={"Authorization": f"Bearer {self.token}",
                                       "Content-Type": "application/json"}, timeout=60, **kw)
        if not r.ok:
            raise requests.HTTPError(f"Management API {r.status_code} secrets: {r.text[:200]}", response=r)
        return r

    def list(self):
        return {s["name"]: {"set": True, "updated": s.get("updated_at")} for s in self._call("GET").json()}

    def put(self, name, value):
        self._call("POST", json=[{"name": name, "value": str(value)}])

    def delete(self, name):
        self._call("DELETE", json=[name])


# ---------- probes: is this value alive? ----------

def probe(entry, value, supabase_url=None, project_ref=None):
    """-> (ok: bool|None, detail). None = no probe for this entry."""
    kind, v = entry.get("probe") or ("url" if entry.get("probe_url") else None), (value or "").strip()
    if not kind or not v:
        return None, "no probe" if not kind else "empty"
    try:
        if kind == "supabase":
            r = requests.get(f"{(supabase_url or '').rstrip('/')}/rest/v1/sources?select=id&limit=1",
                             headers={"apikey": v, "Authorization": f"Bearer {v}"}, timeout=30)
        elif kind == "mgmt":
            r = requests.get(f"https://api.supabase.com/v1/projects/{project_ref}",
                             headers={"Authorization": f"Bearer {v}"}, timeout=30)
        elif kind == "tavily":
            r = requests.post("https://api.tavily.com/search", json={"api_key": v, "query": "nifty", "max_results": 1},
                              timeout=30)
        elif kind == "github":
            r = requests.get("https://api.github.com/user", headers={"Authorization": f"Bearer {v}"}, timeout=30)
        elif kind == "firebase":
            import google.auth.transport.requests
            from google.oauth2 import service_account
            info = json.loads(v)
            creds = service_account.Credentials.from_service_account_info(
                info, scopes=["https://www.googleapis.com/auth/firebase.messaging"])
            creds.refresh(google.auth.transport.requests.Request())
            return bool(creds.token), f"token minted for project {info.get('project_id')}"
        elif kind == "url":  # custom provider: GET template with {key}
            r = requests.get(entry["probe_url"].replace("{key}", v), timeout=30)
        else:  # a check_keys probe name
            import check_keys
            fn = check_keys.PROBES.get(kind)
            if not fn:
                return None, "no probe"
            r = fn(v)
        return r.status_code == 200, "ok" if r.status_code == 200 else f"FAIL {r.status_code} {r.text[:120]}"
    except Exception as e:  # noqa: BLE001  (network, bad JSON, bad key — all 'not ok')
        return False, f"{type(e).__name__}: {str(e)[:160]}"


# ---------- lint: things in .env the code doesn't read ----------

KNOWN_ENV = {s["name"] for s in SECRETS} | set(MODEL_KNOBS) | {
    "MAX_AI_CALLS_PER_RUN", "AI_CONCURRENCY", "AI_PHASE_SECONDS", "DAILY_AI_BUDGET", "LOOP_SECONDS", "LOOP_MAX_SECONDS"}
DEAD_RENAMES = {"GEMINI_MODEL": "GEMINI_MODELS"}


def lint_env(envfile):
    """-> [(kind, name, advice)] for duplicates / dead / unknown keys."""
    issues = []
    for d in envfile.duplicates():
        issues.append(("duplicate", d, "defined twice — the first wins; Fix .env keeps the first"))
    for k in envfile.read():
        if k in DEAD_RENAMES:
            issues.append(("dead", k, f"the code reads {DEAD_RENAMES[k]} — rename"))
        elif k not in KNOWN_ENV:
            issues.append(("unknown", k, "nothing in pipeline/ reads this"))
    return issues


def yaml_snippet(name):
    return f"          {name}: ${{{{ secrets.{name} }}}}"
