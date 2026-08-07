"""Single AI interface (spec §5): all calls route through here so a provider
swap is a config change, not a rewrite."""
import json
import os
import pathlib
import threading
import time

import requests

PROMPT = (pathlib.Path(__file__).parent / "prompts" / "story_v1.txt").read_text(encoding="utf-8")
EDITOR_PROMPT = (pathlib.Path(__file__).parent / "prompts" / "editor_v1.txt").read_text(encoding="utf-8")

# Requests/minute ceiling shared by every caller, so stories can be processed
# concurrently without tripping the free tier. Replaces the old serial sleep.
GEMINI_RPM = int(os.environ.get("GEMINI_RPM", "24"))
_gate_lock = threading.Lock()
_next_slot = 0.0


def _throttle():
    global _next_slot
    gap = 60.0 / max(GEMINI_RPM, 1)
    with _gate_lock:
        now = time.monotonic()
        slot = max(now, _next_slot)
        _next_slot = slot + gap
    if slot > now:
        time.sleep(slot - now)

DIRECTIONS = {"positive", "negative", "mixed", "neutral"}
HORIZONS = {"short_term", "long_term", "both"}
CATEGORIES = {"Markets", "Economy", "IPO", "Global", "Commodities", "Corporate", "Policy", "Geopolitics"}
CONFIDENCES = {"high", "medium", "low"}


class AIError(Exception):
    pass


class QuotaExhausted(AIError):
    """Every model is rate-limited. Callers should leave the story unprocessed
    for a later run rather than flag it — nothing is wrong with the story."""


# The free tier meters requests per MODEL (measured 2026-08-08: 500/day each),
# so rotating on 429 multiplies daily capacity at zero cost. Order = preference.
MODELS = [m.strip() for m in os.environ.get(
    "GEMINI_MODELS",
    "gemini-3.5-flash-lite,gemini-3.1-flash-lite,gemini-2.0-flash-lite,gemini-3.5-flash"
).split(",") if m.strip()]

_cooldown = {}      # model -> monotonic deadline before we try it again
_cooldown_lock = threading.Lock()


def _live_models():
    now = time.monotonic()
    with _cooldown_lock:
        return [m for m in MODELS if _cooldown.get(m, 0.0) <= now]


def _benched(model, seconds=900):
    with _cooldown_lock:
        _cooldown[model] = time.monotonic() + seconds


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


def _groq(prompt):
    """Free-tier failover (spec §5). Returns None when unconfigured or throttled,
    so the caller can fall through to 'try again next run'."""
    key = os.environ.get("GROQ_API_KEY")
    if not key:
        return None
    r = requests.post(
        "https://api.groq.com/openai/v1/chat/completions",
        headers={"Authorization": f"Bearer {key}"},
        json={"model": os.environ.get("GROQ_MODEL", "llama-3.3-70b-versatile"),
              "messages": [{"role": "user", "content": prompt}],
              "response_format": {"type": "json_object"}, "temperature": 0.2},
        timeout=60)
    if r.status_code in (429, 503):
        return None
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


def _gemini(prompt):
    last = None
    for model in _live_models():
        _throttle()
        r = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"]},
            json={
                "contents": [{"parts": [{"text": prompt}]}],
                "generationConfig": {"response_mime_type": "application/json",
                                     "temperature": 0.2},
            },
            timeout=60,
        )
        if r.status_code in (429, 503):  # quota or model overloaded -> next model
            _benched(model)
            last = f"{r.status_code} on {model}"
            continue
        r.raise_for_status()
        return r.json()["candidates"][0]["content"]["parts"][0]["text"]
    text = _groq(prompt)
    if text is not None:
        return text
    raise QuotaExhausted(last or "all Gemini models rate-limited, no Groq key")


def editor_pass(digest):
    """Chief Editor (spec §5): one comparative call per run over a compact digest.
    Returns {"relevel": [{"id", "score"}], "top_story_id"} or None on any failure —
    the editor is advisory; a bad call must never block the run."""
    try:
        out = json.loads(_gemini(EDITOR_PROMPT.format(digest=digest)))
        relevels = [r for r in out.get("relevel", [])
                    if isinstance(r.get("id"), int) and isinstance(r.get("score"), int)
                    and 1 <= r["score"] <= 10]
        top = out.get("top_story_id")
        return {"relevel": relevels, "top_story_id": top if isinstance(top, int) else None}
    except (AIError, ValueError, KeyError, json.JSONDecodeError, requests.RequestException):
        return None  # advisory pass; never let it break the run


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
