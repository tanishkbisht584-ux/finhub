"""Alerts: caps + quiet hours, history, manual send, ops pushes, mute stats."""
from common import *  # noqa: F401,F403

gate("Alerts")
run = pipeline_mod()
st.markdown("### Alerts")

pc = cfg("pipeline")
switches = pc.get("switches") or {}
now_ist = datetime.now(run.IST)
today_ist = now_ist.strftime("%Y-%m-%d")
t = iso_days_ago(1)
cap = int(effective_knob("MAX_ALERTS_PER_DAY"))
q_start, q_end = int(effective_knob("QUIET_START_IST")), int(effective_knob("QUIET_END_IST"))
quiet = now_ist.hour >= q_start or now_ist.hour < q_end
sent_today = count(f"stories?alerted_at=gte.{t}")
profiles = sb_all("profiles?select=*")  # * : app_version/last_seen_at only exist after migration 010
with_token = [p for p in profiles if p.get("fcm_token")]

# ---------- status + switches ----------
st.markdown(pill(f"broadcast today {sent_today} / {cap}", sent_today < cap)
            + pill(f"quiet hours {'NOW' if quiet else 'off'} ({q_start}:00–{q_end}:00 IST)", not quiet,
                   AMBER if quiet else GREEN)
            + pill(f"{len(with_token)} device(s) registered", True, DIM), unsafe_allow_html=True)
c1, c2, _ = st.columns([1, 1, 3])
a_on = c1.toggle("broadcast alerts", value=bool(switches.get("alerts", True)),
                 help="OFF = qualifying stories still publish, nobody's phone buzzes")
p_on = c2.toggle("personal alerts", value=bool(switches.get("personal_alerts", True)))
if a_on != bool(switches.get("alerts", True)) or p_on != bool(switches.get("personal_alerts", True)):
    cfg_save("pipeline", {**pc, "switches": {**switches, "alerts": a_on, "personal_alerts": p_on}})
    st.rerun()

# ---------- knobs ----------
st.markdown("**CAPS · GATE · QUIET HOURS** — blank = code default")
knob_editor(("MAX_ALERTS_PER_DAY", "QUIET_START_IST", "QUIET_END_IST", "QUIET_PIERCE_SCORE",
             "TRUSTED_AUTHORITY", "TRUSTED_SOLO_MINUTES", "PERSONAL_CAP_PER_DAY", "PERSONAL_MIN_SCORE"),
            "knobs_alerts")

# ---------- manual send ----------
st.markdown("**MANUAL SEND** — bypasses the gate, cap and quiet hours. You are the gate.")
fcm_ok = bool(os.environ.get("FIREBASE_SERVICE_ACCOUNT_JSON"))
if not fcm_ok:
    st.warning("FIREBASE_SERVICE_ACCOUNT_JSON not in secrets/.env — sends will no-op.")
cands = sb("GET", "stories?select=id,hook,headline,impact_score,source_name,alerted_at"
                  f"&status=eq.approved&created_at=gte.{t}&order=impact_score.desc.nullslast&limit=100")
lab = {c["id"]: f"#{c['id']} [{c['impact_score']}] {(c['hook'] or c['headline'])[:80]}"
              + (" (already alerted)" if c["alerted_at"] else "") for c in cands}
pick = st.selectbox("Story (approved, last 24 h)", list(lab), format_func=lab.get)
s = next((c for c in cands if c["id"] == pick), None)
m1, m2, m3 = st.columns([1, 2, 1])
if m1.button("Broadcast to everyone", type="primary", disabled=not s):
    ok = run.send_fcm(s["hook"] or s["headline"], s["headline"], s["id"], s["impact_score"])
    if ok:
        sb("PATCH", f"stories?id=eq.{s['id']}", json={"alerted_at": datetime.now(timezone.utc).isoformat()})
        st.success("sent to the `alerts` topic")
    else:
        st.error("not sent — FCM not configured")
ulab = {p["id"]: f"{p.get('display_name') or '?'} · {p['id'][:8]}" for p in with_token}
one = m2.selectbox("…or one user", list(ulab), format_func=ulab.get, label_visibility="collapsed")
if m3.button("Send to that user", disabled=not (s and one)):
    tok = next(p["fcm_token"] for p in with_token if p["id"] == one)
    st.info(f"result: {run.send_fcm_token(tok, s['hook'] or s['headline'], s['headline'], s['id'], s['impact_score'])}")

# ---------- ops pushes ----------
st.markdown("**OPS PUSHES** — watchdog alarms go to these devices, never to the public topic")
ops_ids = pc.get("ops_user_ids") or []
by_id = {p["id"]: p for p in profiles}
st.markdown("".join(pill(f"{by_id[i].get('display_name') or i[:8]}"
                         + ("" if by_id[i].get("fcm_token") else " · no device"), bool(by_id[i].get("fcm_token")))
                    for i in ops_ids if i in by_id) or pill("no ops user set", False), unsafe_allow_html=True)
o1, o2, o3 = st.columns([2, 1, 1])
all_lab = {p["id"]: f"{p.get('display_name') or '?'} · {p['id'][:8]}" for p in profiles}
new_ops = o1.multiselect("Ops users", list(all_lab), default=[i for i in ops_ids if i in all_lab],
                         format_func=all_lab.get, label_visibility="collapsed")
if o2.button("Save ops users"):
    cfg_save("pipeline", {**pc, "ops_user_ids": new_ops})
    st.rerun()
if o3.button("Test push to ops devices", disabled=not ops_ids):
    import ops
    st.info(f"sent to {ops.ops_push('FinSwipe ops test', 'If you can read this, ops pushes work.')} device(s)")

# ---------- history ----------
st.markdown("**HISTORY** — broadcast alerts, newest first")
hist = sb("GET", "stories?select=id,hook,headline,impact_score,source_name,alerted_at"
                 "&alerted_at=not.is.null&order=alerted_at.desc&limit=50")
st.dataframe([{"when": ago(h["alerted_at"]) + " ago", "impact": h["impact_score"],
               "hook": h["hook"] or h["headline"], "source": h["source_name"], "id": h["id"]}
              for h in hist], hide_index=True, width="stretch", height=300)

# ---------- mute stats ----------
st.markdown("**USERS** — who can be reached, who opted out")
settings = [p.get("alert_settings") or {} for p in profiles]
personal_today = sum(int((a.get("pa") or {}).get("n") or 0) for a in settings
                     if str((a.get("pa") or {}).get("d")) == today_ist)
kv_rows([("Profiles", len(profiles)),
         ("With a device token", len(with_token)),
         ("Personal alerts muted", sum(1 for a in settings if a.get("personalized") is False)),
         ("Voice for L1 muted", sum(1 for a in settings if a.get("voice_l1") is False)),
         ("Personal pushes today", personal_today),
         ("Alert opens · 7 d", count(f"events?type=eq.alert_open&created_at=gte.{iso_days_ago(7)}"))])
