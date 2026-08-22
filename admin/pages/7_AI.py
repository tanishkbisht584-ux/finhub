"""AI: which lanes served, key smoke test, live model catalog, edge-function error log."""
from common import *  # noqa: F401,F403

gate("AI")
run, ai = pipeline_mod(), ai_mod()
import check_keys  # noqa: E402  (pipeline/ is on sys.path after pipeline_mod)

st.markdown("### AI · lanes · keys")
t = iso_days_ago(1)

# ---------- lanes served today ----------
usage = Counter()
for r in sb_try(f"pipeline_runs?select=ai_usage&started_at=gte.{t}&ai_usage=not.is.null"):
    usage.update(r["ai_usage"] or {})
try:
    edge = sb_all(f"edge_log?select=fn,lane,ok,status,ms,error,created_at&created_at=gte.{t}&order=created_at.desc")
except requests.RequestException:
    edge = []
ok_lane = Counter(f"{r['fn']} · {r['lane']}" for r in edge if r["ok"])
bad_lane = Counter(f"{r['fn']} · {r['lane']}" for r in edge if not r["ok"])
c1, c2 = st.columns(2)
with c1:
    st.markdown(f"**PIPELINE LANES · TODAY** · {sum(usage.values())} calls")
    html_bars(dict(usage.most_common(12)), GREEN) if usage else st.caption("no run attribution yet")
with c2:
    st.markdown(f"**EDGE LANES · TODAY** · {sum(ok_lane.values())} ok · {sum(bad_lane.values())} failed")
    if ok_lane:
        html_bars(dict(ok_lane.most_common(8)), GREEN)
    if bad_lane:
        html_bars(dict(bad_lane.most_common(8)), RED)
    if not edge:
        st.caption("no edge_log rows yet (migration 010 + redeploy qa/deepread)")

# ---------- keys ----------
st.markdown("**KEYS** — from pipeline/.env on this machine (GitHub secrets are separate; "
            "the pipeline's own attribution above shows what CI actually uses)")
if st.button("Smoke-test every key", type="primary"):
    with st.spinner("probing providers …"):
        rows = check_keys.check_keys()
    st.dataframe([{"key": l, "id": m, "status": "unset" if ok is None else ("ok" if ok else "FAIL"),
                   "detail": d} for l, m, ok, d in rows], hide_index=True, width="stretch")

# ---------- models ----------
st.markdown("**MODELS** — configured vs what the providers serve right now")
m1, m2 = st.columns(2)
with m1:
    st.markdown("Gemini")
    conf = ai._split("GEMINI_MODELS", ai.GEMINI_MODELS)
    try:
        live = ai._available_models()
    except Exception as e:  # noqa: BLE001
        live = None
        st.caption(f"discovery failed: {e}")
    for m in conf:
        alive = None if live is None else (m in live)
        st.markdown(pill(m, alive is not False, DIM if alive is None else None), unsafe_allow_html=True)
    if live is not None:
        try:
            st.caption("effective (retired swapped): " + ", ".join(ai._current_models()))
        except Exception:  # noqa: BLE001
            pass
with m2:
    st.markdown("Groq / OpenRouter")
    for key_env, _, model_env, defaults in ai.FALLBACKS:
        conf = ai._split(model_env, defaults)
        live = None
        if key_env == "GROQ_API_KEY":
            try:
                live = ai._groq_models()
            except Exception:  # noqa: BLE001
                live = None
        for m in conf:
            alive = None if live is None else (m in live)
            st.markdown(pill(f"{model_env}: {m}", alive is not False, DIM if alive is None else None),
                        unsafe_allow_html=True)
st.caption("Override model lists on the Pipeline page (GEMINI_MODELS / GROQ_MODEL / OPENROUTER_MODEL knobs); "
           "edge-function lane order on the App Config page.")

# ---------- edge error log ----------
st.markdown("**EDGE CALL LOG** — last 24 h, newest first")
e1, e2 = st.columns([1, 3])
only_bad = e1.checkbox("errors only", value=True)
fn_pick = e2.radio("fn", ["both", "qa", "deepread"], horizontal=True, label_visibility="collapsed")
shown = [r for r in edge if (not only_bad or not r["ok"]) and (fn_pick == "both" or r["fn"] == fn_pick)][:200]
st.dataframe([{"when": ago(r["created_at"]) + " ago", "fn": r["fn"], "lane": r["lane"],
               "ok": "ok" if r["ok"] else "FAIL", "status": r["status"], "ms": r["ms"],
               "error": (r["error"] or "")[:160]} for r in shown],
             hide_index=True, width="stretch", height=360)
