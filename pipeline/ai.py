"""Single AI interface (spec §5): all calls route through here so a provider
swap is a config change, not a rewrite."""
import json
import os
import pathlib
import re
import threading
import time
from collections import Counter

import requests

PROMPT = (pathlib.Path(__file__).parent / "prompts" / "story_v1.txt").read_text(encoding="utf-8")
EDITOR_PROMPT = (pathlib.Path(__file__).parent / "prompts" / "editor_v1.txt").read_text(encoding="utf-8")

# Rate limits are metered per model/provider, so the throttle is too: one global
# gate made 4 models queue behind each other and capped the whole pipeline at one
# model's speed. Each lane now paces itself, and the fallbacks are paced as well
# instead of running wide open into their own 429s.
RPM_PER_LANE = int(os.environ.get("AI_RPM_PER_LANE", "15"))
_gate_lock = threading.Lock()
_next_slot = {}          # lane -> monotonic time its next call may start
_usage = Counter()       # lane -> successful calls this process (attribution)


def _throttle(lane):
    gap = 60.0 / max(RPM_PER_LANE, 1)
    with _gate_lock:
        now = time.monotonic()
        slot = max(now, _next_slot.get(lane, 0.0))
        _next_slot[lane] = slot + gap
    if slot > now:
        time.sleep(slot - now)


def usage_report():
    """Which model actually served this run — printed by the caller so a silent
    failover (or one model carrying everything) is visible in the logs."""
    with _gate_lock:
        return dict(_usage)

DIRECTIONS = {"positive", "negative", "mixed", "neutral"}
HORIZONS = {"short_term", "long_term", "both"}
CATEGORIES = {"Markets", "Economy", "IPO", "Global", "Commodities", "Corporate", "Policy", "Geopolitics"}
CONFIDENCES = {"high", "medium", "low"}


class AIError(Exception):
    pass


class QuotaExhausted(AIError):
    """Every model is rate-limited. Callers should leave the story unprocessed
    for a later run rather than flag it — nothing is wrong with the story."""


def _split(env, default=""):
    """Every key/model env is a comma-separated list; blanks and stray spaces are
    the normal result of pasting keys in, so drop them rather than build a lane
    that 401s on every call."""
    return [v.strip() for v in os.environ.get(env, default).split(",") if v.strip()]


# The free tier meters requests per MODEL (measured 2026-08-08: 500/day each),
# so rotating on 429 multiplies daily capacity at zero cost. Order = preference.
# gemini-2.0-flash-lite retired by Google (404 as of 2026-08-11); 2.5-flash-lite
# verified live against our keys the same day and keeps the fourth quota pool.
# The two -latest aliases are Google-maintained pointers to the current
# generation: if every named model above is ever retired, they keep the
# pipeline alive with no code change — retirement insurance, not extra quota.
GEMINI_MODELS = ("gemini-3.5-flash-lite,gemini-3.1-flash-lite,"
                 "gemini-2.5-flash-lite,gemini-3.5-flash,"
                 "gemini-flash-lite-latest,gemini-flash-latest")

_cooldown = {}      # lane -> monotonic deadline before we try it again
_cooldown_lock = threading.Lock()

# provider -> set of live model names, or None when discovery failed. Fetched
# once per process (CI restarts the poller every few hours, so this refreshes
# at least that often); a mid-process retirement is carried by the dead-lane
# bench until the next restart.
_discovered = {}


def _list_models(provider, url, headers, extract):
    if provider not in _discovered:
        try:
            r = requests.get(url, headers=headers, timeout=10)
            r.raise_for_status()
            _discovered[provider] = extract(r.json())
        except Exception as e:
            # Advisory only: if we can't ask what exists, trust the configured
            # list — discovery must never be the thing that stalls the pipeline.
            print(f"MODEL DISCOVERY FAILED ({provider}, {type(e).__name__}): {str(e)[:120]}")
            _discovered[provider] = None
    return _discovered[provider]


def _available_models():
    keys = _split("GEMINI_API_KEY")
    if not keys:
        return None
    return _list_models(
        "gemini", "https://generativelanguage.googleapis.com/v1beta/models",
        {"x-goog-api-key": keys[0]},
        lambda j: {m["name"].split("/")[-1] for m in j.get("models", [])
                   if "generateContent" in m.get("supportedGenerationMethods", [])})


def _groq_models():
    keys = _split("GROQ_API_KEY")
    if not keys:
        return None
    return _list_models(
        "groq", "https://api.groq.com/openai/v1/models",
        {"Authorization": f"Bearer {keys[0]}"},
        lambda j: {m["id"] for m in j.get("data", [])})


_FLASH_LITE = re.compile(r"^gemini-(\d+\.\d+)-flash-lite$")


def _current_models():
    """The configured Gemini list with retired names swapped out live.

    Google retires models in place (2026-08-11: gemini-2.0-flash-lite began
    404ing overnight); this drops anything the API no longer serves and fills
    each empty slot with the newest live flash-lite model, so a retirement
    costs nothing until someone updates the list at leisure. Substitution is
    Gemini-only: its version-in-the-name convention makes 'newest lite' a safe
    pick, which no such convention makes true for Groq."""
    configured = _split("GEMINI_MODELS", GEMINI_MODELS)
    live = _available_models()
    if live is None:
        return configured
    kept = [m for m in configured if m in live]
    retired = [m for m in configured if m not in live]
    if retired:
        spares = sorted((m for m in live if _FLASH_LITE.match(m) and m not in kept),
                        key=lambda m: float(_FLASH_LITE.match(m).group(1)),
                        reverse=True)[:len(retired)]
        print(f"MODEL SWAP: retired {retired} -> substituting {spares}")
        kept += spares
    return kept


def _gemini_lanes():
    """Quota is metered per ACCOUNT as well as per model, so GEMINI_API_KEY takes
    a comma-separated list: N keys from N Google accounts multiply the daily pool
    by N. A lane is one (key, model) pair — the unit quota, throttling and
    cooldown are all metered on. Ordered model-major: we exhaust the preferred
    model across every key before dropping to the next model, so a 429 costs us
    an account and not the answer quality."""
    keys = _split("GEMINI_API_KEY")
    return [(k, m, f"{m}#{i}")
            for m in _current_models()
            for i, k in enumerate(keys, 1)]


def _live_lanes():
    now = time.monotonic()
    with _cooldown_lock:
        return [l for l in _gemini_lanes() if _cooldown.get(l[2], 0.0) <= now]


def _benched(lane, seconds):
    with _cooldown_lock:
        _cooldown[lane] = time.monotonic() + seconds


def _retry_after(resp, default=60.0):
    """A 429 is usually a per-minute trip, not a spent day — benching for 15 min
    threw away a model for three runs. Google states the real wait in RetryInfo;
    honour it, and fall back to a minute rather than assuming the worst."""
    try:
        for d in resp.json()["error"]["details"]:
            if str(d.get("@type", "")).endswith("RetryInfo"):
                return min(float(str(d["retryDelay"]).rstrip("s")), 900.0)
    except (ValueError, KeyError, TypeError):
        pass
    return default


def validate(card):
    """Raise ValueError describing the first schema problem, else return card."""
    if not isinstance(card, dict):
        raise ValueError("not a JSON object")
    for key in ("hook", "headline_rewrite", "summary", "impact", "companies",
                "sectors", "category", "is_india_relevant", "confidence"):
        if key not in card:
            raise ValueError(f"missing field {key}")
    imp = card["impact"]
    if imp.get("direction") not in DIRECTIONS:
        raise ValueError(f"bad impact.direction {imp.get('direction')!r}")
    if imp.get("strength") not in (1, 2, 3):
        raise ValueError(f"bad impact.strength {imp.get('strength')!r}")
    if imp.get("horizon") not in HORIZONS:
        raise ValueError(f"bad impact.horizon {imp.get('horizon')!r}")
    if not isinstance(imp.get("score"), int) or not 1 <= imp["score"] <= 10:
        raise ValueError(f"bad impact.score {imp.get('score')!r}")
    if card["category"] not in CATEGORIES:
        raise ValueError(f"bad category {card['category']!r}")
    if card["confidence"] not in CONFIDENCES:
        raise ValueError(f"bad confidence {card['confidence']!r}")
    if not isinstance(card["companies"], list) or not isinstance(card["sectors"], list):
        raise ValueError("companies/sectors must be lists")
    if not isinstance(card["is_india_relevant"], bool):
        raise ValueError("is_india_relevant must be boolean")
    return card


# Free-tier failovers, tried in order after Gemini (spec §5). All are
# OpenAI-compatible, so one function covers them; a provider is skipped when its
# key is unset. Groq: ~1000 req/day, no card. OpenRouter: 50/day free, 1000/day
# once you've ever bought $10 of credit — so it earns its place as depth, not
# as the main lane. Models are overridable per provider via env.
FALLBACKS = [
    ("GROQ_API_KEY", "https://api.groq.com/openai/v1/chat/completions",
     "GROQ_MODEL", "openai/gpt-oss-120b,qwen/qwen3.6-27b,openai/gpt-oss-20b"),
    # Deliberately NOT a google/* free model: those route to Google AI Studio's
    # shared pool, i.e. the same upstream our own Gemini key already exhausted.
    ("OPENROUTER_API_KEY", "https://openrouter.ai/api/v1/chat/completions",
     "OPENROUTER_MODEL", "nvidia/nemotron-3-super-120b-a12b:free"),
]


def _fallback_lanes():
    """One lane per (key, model) pair, same as Gemini: these providers meter per
    account AND per model, so both envs take comma-separated lists and the two
    multiply. Model-major, so the preferred model is tried on every key first."""
    lanes = []
    for key_env, url, model_env, default_models in FALLBACKS:
        keys = _split(key_env)
        models = _split(model_env, default_models)
        if key_env == "GROQ_API_KEY":
            # Groq retires models too (deprecations land monthly); drop what
            # its catalog no longer lists rather than probe a dead lane all
            # run. No substitution here — unlike Gemini there's no naming
            # convention that makes an automatic replacement a safe pick.
            live = _groq_models()
            if live is not None:
                gone = [m for m in models if m not in live]
                if gone:
                    print(f"MODEL DISCOVERY: groq retired {gone}; lanes dropped")
                models = [m for m in models if m in live]
        for model in models:
            for i, key in enumerate(keys, 1):
                lanes.append((key, url, model, f"{model}#{i}"))
    return lanes


def _fallback_chat(prompt):
    """Returns None when every configured provider is unset or throttled, so the
    caller can fall through to 'try again next run'."""
    for key, url, model, lane in _fallback_lanes():
        with _cooldown_lock:
            if _cooldown.get(lane, 0.0) > time.monotonic():
                continue  # still benched from an earlier 429 this run
        try:
            _throttle(lane)  # fallbacks have their own limits; pace them too
            r = requests.post(
                url, headers={"Authorization": f"Bearer {key}"},
                json={"model": model,
                      "messages": [{"role": "user", "content": prompt}],
                      "response_format": {"type": "json_object"}, "temperature": 0.2},
                timeout=60)
            if r.status_code in (429, 503):
                _benched(lane, _retry_after(r))  # don't re-probe a dead key all run
                continue                         # this lane is tapped out; next one
            r.raise_for_status()
            with _gate_lock:
                _usage[lane] += 1
            return r.json()["choices"][0]["message"]["content"]
        except requests.RequestException:
            continue  # a dead provider must never stall the pipeline
    return None


def _gemini(prompt):
    last = None
    for key, model, lane in _live_lanes():
        _throttle(lane)
        r = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            headers={"x-goog-api-key": key},
            json={
                "contents": [{"parts": [{"text": prompt}]}],
                "generationConfig": {"response_mime_type": "application/json",
                                     "temperature": 0.2},
            },
            timeout=60,
        )
        if r.status_code in (429, 503):  # quota or model overloaded -> next lane
            wait = _retry_after(r)
            _benched(lane, wait)
            last = f"{r.status_code} on {lane} (benched {wait:.0f}s)"
            continue
        if not r.ok:
            # Structurally dead lane — a retired model (2026-08-11: Google
            # 404'd gemini-2.0-flash-lite) or a revoked key. raise_for_status
            # here escaped _gemini before the next lane or the fallback chain
            # ever ran, so one dead endpoint flagged every story after the
            # preferred lanes hit quota. Bench it for an hour and move on.
            _benched(lane, 3600.0)
            last = f"{r.status_code} on {lane} (benched 1h)"
            continue
        with _gate_lock:
            _usage[lane] += 1
        return r.json()["candidates"][0]["content"]["parts"][0]["text"]
    text = _fallback_chat(prompt)
    if text is not None:
        return text
    raise QuotaExhausted(last or "every provider rate-limited or unconfigured")


def editor_pass(digest):
    """Chief Editor (spec §5): one comparative call per run over a compact digest.
    Returns {"relevel": [{"id", "score"}], "top_story_id", "merge": [[keep, dup]]}
    or None on any failure —
    the editor is advisory; a bad call must never block the run."""
    try:
        out = json.loads(_gemini(EDITOR_PROMPT.format(digest=digest)))
        relevels = [r for r in (out.get("relevel") or [])
                    if isinstance(r.get("id"), int) and isinstance(r.get("score"), int)
                    and 1 <= r["score"] <= 10]
        top = out.get("top_story_id")
        # Same-event pairs the clustering missed (spec §5): [keep, duplicate].
        # Validated hard — a malformed pair must never demote a story.
        merges = [p for p in (out.get("merge") or [])
                  if isinstance(p, list) and len(p) == 2
                  and all(isinstance(i, int) for i in p) and p[0] != p[1]]
        return {"relevel": relevels, "merge": merges,
                "top_story_id": top if isinstance(top, int) else None}
    except (AIError, ValueError, KeyError, json.JSONDecodeError,
            requests.RequestException) as e:
        # Advisory pass: never break the run — but never fail silently either.
        # Returning None quietly meant a permanently broken editor looked
        # identical to "nothing needed re-levelling".
        print(f"EDITOR PASS FAILED ({type(e).__name__}): {str(e)[:200]}")
        return None


def process_story(source_name, headline, body):
    """One structured call per story; 1 retry with the error appended (spec §5),
    then AIError — caller flags the story, never publishes it."""
    prompt = PROMPT.format(source_name=source_name, headline=headline, body=body[:8000])
    last_err = None
    for attempt in range(2):
        try:
            raw = _gemini(prompt if attempt == 0 else
                          f"{prompt}\n\nYour previous answer was invalid: {last_err}. Return corrected JSON only.")
            return validate(json.loads(raw))
        except QuotaExhausted:
            raise  # not the story's fault — let the caller retry it next run
        except (ValueError, KeyError, json.JSONDecodeError, requests.RequestException) as e:
            last_err = str(e)[:500]
    raise AIError(last_err)
