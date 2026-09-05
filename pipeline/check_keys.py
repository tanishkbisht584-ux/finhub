"""Smoke-test every configured key: python check_keys.py  (or from the admin's AI page)

Confirms each key authenticates, and catches the same key pasted twice. It
CANNOT tell you two distinct keys came from the same Google account — those
share one quota pool and look perfectly healthy here, right up until you run
out three times sooner than the key count suggests. Check the account in
AI Studio when you create them; this script can't check it for you.
"""
import os
import sys

import requests

from run import load_env

PROBES = {
    "GEMINI_API_KEY": lambda k: requests.get(
        "https://generativelanguage.googleapis.com/v1beta/models",
        headers={"x-goog-api-key": k}, timeout=30),
    "GROQ_API_KEY": lambda k: requests.get(
        "https://api.groq.com/openai/v1/models",
        headers={"Authorization": f"Bearer {k}"}, timeout=30),
    "OPENROUTER_API_KEY": lambda k: requests.get(
        "https://openrouter.ai/api/v1/key",
        headers={"Authorization": f"Bearer {k}"}, timeout=30),
    # markets upgrade (2026-08-22): each probe spends one request of that day's quota
    "GNEWS_API_KEY": lambda k: requests.get(
        "https://gnews.io/api/v4/search",
        params={"q": "nifty", "max": 1, "apikey": k}, timeout=30),
    "NEWSDATA_API_KEY": lambda k: requests.get(
        "https://newsdata.io/api/1/latest",
        params={"apikey": k, "q": "nifty", "country": "in"}, timeout=30),
    "MARKETAUX_API_KEY": lambda k: requests.get(
        "https://api.marketaux.com/v1/news/all",
        params={"api_token": k, "countries": "in", "limit": 1}, timeout=30),
    "FRED_API_KEY": lambda k: requests.get(
        "https://api.stlouisfed.org/fred/series",
        params={"series_id": "FEDFUNDS", "api_key": k, "file_type": "json"}, timeout=30),
}


def check_keys(probe=None):
    """-> [(label, masked_key, ok, detail)]. ok is None for an unset env,
    False for a failing/duplicate key. `probe(env, key)` is injectable for tests."""
    out = []
    for env, default_probe in PROBES.items():
        keys = [k.strip() for k in os.environ.get(env, "").split(",") if k.strip()]
        if not keys:
            out.append((env, "", None, "unset"))
            continue
        if len(set(keys)) != len(keys):
            out.append((env, "", False, "DUPLICATE key pasted twice — that lane is wasted"))
        for i, k in enumerate(keys, 1):
            masked = f"{k[:8]}...{k[-4:]}"
            try:
                r = probe(env, k) if probe else default_probe(k)
                ok = r.status_code == 200
                out.append((f"{env}#{i}", masked, ok, "ok" if ok else f"FAIL {r.status_code} {r.text[:120]}"))
            except requests.RequestException as e:
                out.append((f"{env}#{i}", masked, False, f"unreachable — {e}"))
    return out


if __name__ == "__main__":
    load_env()
    rows = check_keys()
    for label, masked, ok, detail in rows:
        print(f"{label} {masked}  {detail}")
    sys.exit(1 if any(ok is False for _, _, ok, _ in rows) else 0)
