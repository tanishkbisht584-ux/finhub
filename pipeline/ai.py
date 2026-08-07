"""Single AI interface (spec §5): all calls route through here so a provider
swap is a config change, not a rewrite."""
import json
import os
import pathlib

import requests

PROMPT = (pathlib.Path(__file__).parent / "prompts" / "story_v1.txt").read_text(encoding="utf-8")
EDITOR_PROMPT = (pathlib.Path(__file__).parent / "prompts" / "editor_v1.txt").read_text(encoding="utf-8")

DIRECTIONS = {"positive", "negative", "mixed", "neutral"}
HORIZONS = {"short_term", "long_term", "both"}
CATEGORIES = {"Markets", "Economy", "IPO", "Global", "Commodities", "Corporate", "Policy", "Geopolitics"}
CONFIDENCES = {"high", "medium", "low"}


class AIError(Exception):
    pass


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


def _gemini(prompt):
    model = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash-lite")
    r = requests.post(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"]},
        json={
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"response_mime_type": "application/json", "temperature": 0.2},
        },
        timeout=60,
    )
    r.raise_for_status()
    return r.json()["candidates"][0]["content"]["parts"][0]["text"]


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
    except (ValueError, KeyError, json.JSONDecodeError, requests.RequestException):
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
        except (ValueError, KeyError, json.JSONDecodeError, requests.RequestException) as e:
            last_err = str(e)[:500]
    raise AIError(last_err)
