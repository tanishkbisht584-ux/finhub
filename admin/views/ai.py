"""AI: which lanes served, key smoke test, live model catalog, edge-function call log."""
from common import *  # noqa: F401,F403

run, ai = pipeline_mod(), ai_mod()
import check_keys  # noqa: E402  (pipeline/ is on sys.path after pipeline_mod)

t = iso_days_ago(1)
usage = Counter()
for r in q_try(f"pipeline_runs?select=ai_usage&started_at=gte.{t}&ai_usage=not.is.null"):
    usage.update(r["ai_usage"] or {})
try:
    edge = sb_all(f"edge_log?select=fn,lane,ok,status,ms,error,created_at&created_at=gte.{t}&order=created_at.desc")
except requests.RequestException:
    edge = []
ok_lane = Counter(f"{r['fn']} · {r['lane']}" for r in edge if r["ok"])
bad_lane = Counter(f"{r['fn']} · {r['lane']}" for r in edge if not r["ok"])
n_ok, n_bad = sum(ok_lane.values()), sum(bad_lane.values())

header("AI", "Which provider/model/key actually served, whether every key works, and what the edge functions did.",
       [pill(f"pipeline {sum(usage.values())} calls today", True, DIM),
        pill(f"edge {n_ok} ok · {n_bad} failed", not (n_ok + n_bad >= 5 and n_bad * 2 > n_ok + n_bad))])
kpis([("Pipeline calls · today", sum(usage.values()), f"{len(usage)} lane(s) served", GREEN),
      ("Edge ok · today", n_ok, "qa + deepread", GREEN),
      ("Edge failed · today", n_bad, "lane attempts", RED if n_bad else GREEN),
      ("Flagged (AI failed)", count("stories?status=eq.flagged"), "see Review", RED if count("stories?status=eq.flagged") >= 15 else GREEN)])

tab_l, tab_k, tab_m, tab_e = st.tabs(["Lanes", "Keys", "Models", f"Edge call log · {len(edge)}"])

with tab_l:
    c1, c2 = st.columns(2)
    with c1:
        section("Pipeline lanes · today", "model#key → calls")
        html_bars(dict(usage.most_common(12)), GREEN) if usage else st.caption("no run attribution yet")
    with c2:
        section("Edge lanes · today", "ok in green, failed in red")
        if ok_lane:
            html_bars(dict(ok_lane.most_common(8)), GREEN)
        if bad_lane:
            html_bars(dict(bad_lane.most_common(8)), RED)
        if not edge:
            st.caption("no edge_log rows yet (migration 010 + redeploy qa/deepread)")

with tab_k:
    st.markdown("<div class='fs-muted'>Keys come from pipeline/.env on this machine. GitHub secrets are separate — "
                "the pipeline's own attribution (Lanes tab) shows what CI actually uses.</div>", unsafe_allow_html=True)
    if st.button("Smoke-test every key", type="primary", icon=":material/key:"):
        with st.spinner("probing providers … (Groq is Cloudflare-blocked from this machine; that FAIL is expected)"):
            keys_table(check_keys.check_keys())

with tab_m:
    st.markdown("<div class='fs-muted'>Configured lists, and — on demand — whether each provider still serves them. "
                "Discovery is button-gated: Groq is Cloudflare-blocked from this machine and would stall the page.</div>",
                unsafe_allow_html=True)
    check_live = st.button("Check live catalogs", icon=":material/cloud_sync:")
    m1, m2 = st.columns(2)
    with m1:
        section("Gemini", "configured vs served right now")
        conf = ai._split("GEMINI_MODELS", ai.GEMINI_MODELS)
        live = None
        if check_live:
            try:
                live = ai._available_models()
            except Exception as e:  # noqa: BLE001
                st.caption(f"discovery failed: {e}")
        st.markdown("".join(pill(m, (None if live is None else (m in live)) is not False,
                                 DIM if live is None else None) for m in conf), unsafe_allow_html=True)
        if live is not None:
            try:
                st.caption("effective (retired swapped): " + ", ".join(ai._current_models()))
            except Exception:  # noqa: BLE001
                pass
    with m2:
        section("Groq / OpenRouter")
        for key_env, _, model_env, defaults in ai.FALLBACKS:
            conf = ai._split(model_env, defaults)
            live = None
            if check_live and key_env == "GROQ_API_KEY":
                try:
                    live = ai._groq_models()
                except Exception:  # noqa: BLE001
                    live = None
            st.markdown("".join(pill(f"{model_env}: {m}", (None if live is None else (m in live)) is not False,
                                     DIM if live is None else None) for m in conf), unsafe_allow_html=True)
    st.caption("Override model lists on Pipeline › Knobs (GEMINI_MODELS / GROQ_MODEL / OPENROUTER_MODEL); "
               "edge-function lane order on App Config.")

with tab_e:
    e1, e2, e3 = st.columns([1, 2, 3])
    only_bad = e1.checkbox("errors only", value=True)
    fn_pick = e2.radio("fn", ["both", "qa", "deepread"], horizontal=True, label_visibility="collapsed")
    needle = e3.text_input("contains", placeholder="429, quota, gemini …", label_visibility="collapsed")
    shown = [r for r in edge if (not only_bad or not r["ok"]) and (fn_pick == "both" or r["fn"] == fn_pick)
             and (not needle or needle.lower() in f"{r['lane']} {r['error'] or ''}".lower())][:300]
    edge_table(shown, height=420)

auto_refresh()  # status page: stale data heals itself while the tab is open
