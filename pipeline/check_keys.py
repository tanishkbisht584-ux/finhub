"""Smoke-test every configured key: python check_keys.py

Confirms each key authenticates, and catches the same key pasted twice. It
CANNOT tell you two distinct keys came from the same Google account — those
share one quota pool and look perfectly healthy here, right up until you run
out three times sooner than the key count suggests. Check the account in
AI Studio when you create them; this script can't check it for you.
"""
import os
import sys

import requests
from dotenv import load_dotenv

load_dotenv()

PROVIDERS = [
    ("GEMINI_API_KEY", lambda k: requests.get(
        "https://generativelanguage.googleapis.com/v1beta/models",
        headers={"x-goog-api-key": k}, timeout=30)),
    ("GROQ_API_KEY", lambda k: requests.get(
        "https://api.groq.com/openai/v1/models",
        headers={"Authorization": f"Bearer {k}"}, timeout=30)),
    ("OPENROUTER_API_KEY", lambda k: requests.get(
        "https://openrouter.ai/api/v1/key",
        headers={"Authorization": f"Bearer {k}"}, timeout=30)),
]

bad = 0
for env, probe in PROVIDERS:
    keys = [k.strip() for k in os.environ.get(env, "").split(",") if k.strip()]
    if not keys:
        print(f"{env}: unset")
        continue
    if len(set(keys)) != len(keys):
        print(f"{env}: DUPLICATE key pasted twice — that lane is wasted")
        bad += 1
    for i, k in enumerate(keys, 1):
        try:
            r = probe(k)
            ok = r.status_code == 200
            print(f"{env}#{i} {k[:8]}...{k[-4:]}  {'ok' if ok else f'FAIL {r.status_code} {r.text[:120]}'}")
            bad += not ok
        except requests.RequestException as e:
            print(f"{env}#{i}: unreachable — {e}")
            bad += 1

sys.exit(1 if bad else 0)
