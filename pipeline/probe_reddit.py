"""One-shot Reddit probe: does client_credentials OAuth + a multi-sub listing
work from wherever this runs (dev IP and a GitHub runner — reddit.com 403s
anonymous clients everywhere, and cloud IPs are often blocked even with a
token). Needs REDDIT_CLIENT_ID / REDDIT_CLIENT_SECRET in the env (a free
"script" app from reddit.com/prefs/apps). Prints status + 3 titles + the
rate-limit headers. No writes.
"""
import os
import sys

import requests

UA = {"User-Agent": "finswipe/0.1 (by u/finswipe)"}
SUBS = "IndianStreetBets+IndiaInvestments+DalalStreetTalks"


def main():
    cid, sec = os.environ.get("REDDIT_CLIENT_ID", ""), os.environ.get("REDDIT_CLIENT_SECRET", "")
    if not (cid and sec):
        print("[reddit] no REDDIT_CLIENT_ID/SECRET in env — nothing to probe")
        return 0
    r = requests.post("https://www.reddit.com/api/v1/access_token", auth=(cid, sec),
                      data={"grant_type": "client_credentials"}, headers=UA, timeout=20)
    print(f"[reddit token] {r.status_code} {r.text[:200].replace(chr(10), ' ')}")
    if not r.ok:
        return 1
    tok = r.json().get("access_token", "")
    r = requests.get(f"https://oauth.reddit.com/r/{SUBS}/new", params={"limit": 100},
                     headers={**UA, "Authorization": f"bearer {tok}"}, timeout=20)
    print(f"[reddit listing] {r.status_code} ratelimit used/remaining/reset:",
          r.headers.get("x-ratelimit-used"), r.headers.get("x-ratelimit-remaining"),
          r.headers.get("x-ratelimit-reset"))
    if not r.ok:
        print("  ", r.text[:300].replace("\n", " "))
        return 1
    posts = [c.get("data") or {} for c in (r.json().get("data") or {}).get("children") or []]
    print(f"  {len(posts)} posts; oldest created_utc:", min((p.get("created_utc") or 0) for p in posts) if posts else None)
    for p in posts[:3]:
        print("  -", p.get("subreddit"), "|", (p.get("title") or "")[:80], "| score", p.get("score"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
