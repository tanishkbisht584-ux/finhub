"""Ops-side helpers shared by .github/workflows/watchdog.yml and the admin.
(Named ops, not watchdog: a pip package called watchdog ships with Streamlit.)

ops_push: buzz the operator's phone(s) — NOT the public `alerts` topic, which
reaches every install. Who counts as an operator is app_config.pipeline
.ops_user_ids (set from the admin's Alerts page: "Make me the ops user")."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # run as a script from repo root
from run import load_config, load_env, sb, send_fcm_token  # noqa: E402


def ops_push(title, body):
    """Direct push to every ops user's device. Returns the number sent.
    Empty story_id => the app's int.tryParse gives null => no deep-link."""
    load_env()
    ids = load_config().get("ops_user_ids") or []
    if not ids:
        print("ops push skipped: no ops user configured (admin → Alerts → Make me the ops user)")
        return 0
    quoted = ",".join(f'"{i}"' for i in ids)
    rows = sb("GET", f"profiles?select=id,fcm_token&id=in.({quoted})&fcm_token=not.is.null")
    sent = 0
    for r in rows:
        if send_fcm_token(r["fcm_token"], title, body[:170], "", "") == "sent":
            sent += 1
    print(f"ops push: {sent}/{len(rows)} device(s)")
    return sent


if __name__ == "__main__":  # manual test: python pipeline/watchdog.py "title" "body"
    print(ops_push(sys.argv[1] if len(sys.argv) > 1 else "FinSwipe ops test",
                   sys.argv[2] if len(sys.argv) > 2 else "If you can read this, ops pushes work."))
