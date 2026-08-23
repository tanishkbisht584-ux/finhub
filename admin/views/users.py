"""Users: every profile, what they follow/save/do, their rate-limit ledgers, and the levers."""
from common import *  # noqa: F401,F403

t = iso_days_ago(1)
edge_cap = int((cfg("edge") or {}).get("daily_cap") or 50)
profiles = sb_all("profiles?select=*&order=created_at.desc")
events_today = sb_all(f"events?select=user_id,type&created_at=gte.{t}")
by_user = {}
for e in events_today:
    by_user.setdefault(e["user_id"], Counter())[e["type"]] += 1
ist_today = datetime.now(timezone(timedelta(hours=5, minutes=30))).strftime("%Y-%m-%d")
with_device = sum(1 for p in profiles if p.get("fcm_token"))
seen_today = sum(1 for p in profiles if p.get("last_seen_at") and run_age(p, "last_seen_at") < 86400)
active_today = len(by_user)

header("Users", "Every profile, their activity and rate-limit ledgers, and the per-user levers.",
       [pill(f"{len(profiles)} profiles", True, DIM), pill(f"{with_device} with device", True, DIM),
        pill(f"{active_today} active today", True, GREEN)])
kpis([("Profiles", len(profiles), "signed in at least once", BLUE),
      ("Devices", with_device, "FCM token on file", BLUE),
      ("Active today", active_today, "wrote an event", GREEN),
      ("Seen today", seen_today, "reported by builds ≥ 0.19", GREEN),
      ("Asks today", sum(c["qa_ask"] for c in by_user.values()), f"cap {edge_cap}/user", DIM),
      ("Deep reads today", sum(c["deep_read"] for c in by_user.values()), f"cap {edge_cap}/user", DIM)])


def row(p):
    a = p.get("alert_settings") or {}
    pa = a.get("pa") or {}
    ev = by_user.get(p["id"], Counter())
    return {"name": p.get("display_name") or "?", "id": p["id"][:8],
            "joined": ago(p["created_at"]) + " ago",
            "seen": (ago(p["last_seen_at"]) + " ago") if p.get("last_seen_at") else "—",
            "app": p.get("app_version") or "—", "device": "yes" if p.get("fcm_token") else "no",
            "personal": "off" if a.get("personalized") is False else "on",
            "voice": "off" if a.get("voice_l1") is False else "on",
            "pushes today": pa.get("n") if str(pa.get("d")) == ist_today else 0,
            "views": ev["view"], "asks": ev["qa_ask"], "deep reads": ev["deep_read"]}


tab_all, tab_one = st.tabs(["All users", "One user"])
with tab_all:
    st.dataframe([row(p) for p in profiles], hide_index=True, width="stretch", height=480)

with tab_one:
    lab = {p["id"]: f"{p.get('display_name') or '?'} · {p['id'][:8]}" for p in profiles}
    uid = st.selectbox("User", list(lab), format_func=lab.get)
    if not uid:
        st.stop()
    p = next(x for x in profiles if x["id"] == uid)
    a = p.get("alert_settings") or {}
    ev = by_user.get(uid, Counter())
    c1, c2 = st.columns(2)
    with c1:
        section("Activity · today")
        kv_rows([("Cards viewed", ev["view"]), ("Shares", ev["share"]), ("Alert opens", ev["alert_open"]),
                 ("Asks (cap)", f"{ev['qa_ask']} / {edge_cap}"),
                 ("Deep reads generated (cap)", f"{ev['deep_read']} / {edge_cap}"),
                 ("Saved stories (all time)", count(f"saves?user_id=eq.{uid}")),
                 ("App version", p.get("app_version") or "—"),
                 ("Last seen", (ago(p["last_seen_at"]) + " ago") if p.get("last_seen_at") else "—")])
        follows = sb("GET", f"follows?select=target_type,target_id&user_id=eq.{uid}&order=target_type")
        section("Follows")
        if follows:
            cids = [f["target_id"] for f in follows if f["target_type"] == "company"]
            names = {str(c["id"]): c["name"] for c in
                     sb("GET", f"companies?select=id,name&id=in.({','.join(cids)})")} if cids else {}
            st.markdown(" ".join(pill(f"{f['target_type'][:3]} · {names.get(f['target_id'], f['target_id'])}", True, DIM)
                                 for f in follows), unsafe_allow_html=True)
        else:
            st.caption("nothing followed")
    with c2:
        section("Levers")
        st.code(f"id: {uid}\ndevice token: {(p.get('fcm_token') or '—')[:24]}…\n"
                f"alert_settings: {jdump(a)}", language=None)
        l1, l2 = st.columns(2)
        personal = l1.toggle("personal alerts", value=a.get("personalized", True) is not False, key="u_pers")
        voice = l2.toggle("voice for L1", value=a.get("voice_l1", True) is not False, key="u_voice")
        if personal != (a.get("personalized", True) is not False) or voice != (a.get("voice_l1", True) is not False):
            sb("PATCH", f"profiles?id=eq.{uid}",
               json={"alert_settings": {**a, "personalized": personal, "voice_l1": voice}})
            refresh()
        b1, b2, b3 = st.columns(3)
        if b1.button("Clear device token", disabled=not p.get("fcm_token"),
                     help="Stops all pushes to this device until the app re-registers"):
            sb("PATCH", f"profiles?id=eq.{uid}", json={"fcm_token": None})
            refresh()
        if b2.button("Reset personal-alert counter", help="Lets today's personal pushes start from 0"):
            sb("PATCH", f"profiles?id=eq.{uid}", json={"alert_settings": {k: v for k, v in a.items() if k != "pa"}})
            refresh()
        if b3.button("Clear today's rate limits", help="Deletes this user's qa_ask/deep_read events from today"):
            sb("DELETE", f"events?user_id=eq.{uid}&type=in.(qa_ask,deep_read)&created_at=gte.{t}")
            refresh()
        st.markdown("---")
        sure = st.checkbox("I understand this deletes the account, follows, saves and device token", key="del_user")
        if st.button("Delete user", type="primary", disabled=not sure, icon=":material/person_remove:"):
            r = requests.delete(f"{URL}/auth/v1/admin/users/{uid}", headers=sb_headers(), timeout=30)
            if r.ok:
                st.success("deleted")
                refresh()
            else:
                st.error(f"{r.status_code}: {r.text[:300]}")
