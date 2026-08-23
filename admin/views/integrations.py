"""Integrations: every external key/account — where it lives (local · GitHub CI ·
edge functions · admin), whether it works, add/rotate/remove, push everywhere,
restart the pipeline. Logic in admin/integrations.py; this file is the UI."""
import integrations as I

from common import *  # noqa: F401,F403

run, ai = pipeline_mod(), ai_mod()
ENV = I.EnvFile(REPO / "pipeline" / ".env")
TOML = I.TomlFile(REPO / ".streamlit" / "secrets.toml")
meta = cfg("integrations") or {}
meta.setdefault("labels", {}), meta.setdefault("log", []), meta.setdefault("custom", [])
REG = I.registry(meta["custom"])
GROUPS = [g for g in I.GROUP_ORDER if any(s["group"] == g for s in REG)]
gh_tok, mg_tok = gh_token(), mgmt_token()
GH = I.GitHubSecrets(GITHUB_REPO, gh_tok, HTTP) if gh_tok else None
ED = I.EdgeSecrets(PROJECT_REF, mg_tok, HTTP) if mg_tok else None
local = ENV.read()
toml_names = set(TOML.names())
t = iso_days_ago(1)


@st.cache_data(ttl=30, show_spinner=False)
def remote_lists():
    """{store: {name: {set, updated}}} + error text per store; cached 30 s."""
    out, errs = {"gh": {}, "edge": {}}, {}
    for key, store in (("gh", GH), ("edge", ED)):
        if store is None:
            errs[key] = "no token"
            continue
        try:
            out[key] = store.list()
        except Exception as e:  # noqa: BLE001
            errs[key] = str(e)[:160]
    return out, errs


@st.cache_data(ttl=30, show_spinner=False)
def gh_scopes():
    try:
        return GH.scopes() if GH else ("", None)
    except Exception as e:  # noqa: BLE001
        return ("", f"error: {str(e)[:80]}")


@st.cache_data(ttl=30, show_spinner=False)
def usage_today():
    """(provider, key index) -> calls, from pipeline_runs.ai_usage (1-based model#i)
    and edge_log.lane (provider/model#i, 0-based) — the only truth about CI/edge keys."""
    groq_models = set(ai._split("GROQ_MODEL", next(f[3] for f in ai.FALLBACKS if f[0] == "GROQ_API_KEY")))
    ci, edge = Counter(), Counter()
    for r in q_try(f"pipeline_runs?select=ai_usage&started_at=gte.{t}&ai_usage=not.is.null"):
        for lane, n in (r["ai_usage"] or {}).items():
            model, _, idx = lane.rpartition("#")
            prov = "GEMINI_API_KEY" if model.startswith("gemini") else ("GROQ_API_KEY" if model in groq_models else "OPENROUTER_API_KEY")
            ci[(prov, int(idx or 1))] += n
    for r in q_try(f"edge_log?select=lane&ok=eq.true&created_at=gte.{t}"):
        lane = r["lane"] or ""
        prov = "GEMINI_API_KEY" if lane.startswith("gemini") else "GROQ_API_KEY"
        idx = int(lane.rpartition("#")[2] or 0) + 1 if "#" in lane else 1
        edge[(prov, idx)] += 1
    return ci, edge


remote, rerr = remote_lists()
ci_use, edge_use = usage_today()
scopes, gh_login = gh_scopes()


def local_value(entry):
    if entry["name"] == "GITHUB_TOKEN":
        return st.secrets.get("GITHUB_TOKEN") or ""
    return local.get(entry["name"]) or st.secrets.get(entry["name"]) or ""


def store_state(entry):
    """{store: (present: bool|None, detail)} — None = store not a target."""
    n, tg = entry["name"], entry["targets"]
    out = {}
    out["env"] = (bool(local.get(n)), f"{len(I.split_list(local.get(n)))} key(s)" if entry["shape"] == "list" and local.get(n) else "") if tg.get("env") else (None, "")
    out["toml"] = (n in toml_names, "") if tg.get("toml") else (None, "")
    if tg.get("gh"):
        g = remote["gh"].get(n)
        out["gh"] = (bool(g), f"updated {ago(g['updated'])} ago" if g and g.get("updated") else ("" if g else rerr.get("gh", "")))
    else:
        out["gh"] = (None, "")
    en = I.edge_name(entry)
    if en:
        e = remote["edge"].get(en)
        out["edge"] = (bool(e), en if e else rerr.get("edge", ""))
    else:
        out["edge"] = (None, "")
    return out


def do_save(entry, value, targets, action, fp_note):
    """Write to the chosen stores, log it (fingerprints only), refresh."""
    n, written, failed = entry["name"], [], []
    for tg in targets:
        try:
            if tg == "env":
                ENV.put(n, value)
            elif tg == "toml":
                TOML.put(n, value)
            elif tg == "gh":
                if not GH:
                    raise RuntimeError("no GitHub token")
                GH.put(n, value)
            elif tg == "edge":
                if not ED:
                    raise RuntimeError("no SUPABASE_ACCESS_TOKEN")
                ED.put(I.edge_name(entry), value)
            written.append(tg)
        except Exception as e:  # noqa: BLE001
            failed.append(f"{tg}: {str(e)[:140]}")
    meta["log"] = ([{"at": I.now_iso(), "name": n, "action": action, "targets": written, "fp": fp_note}]
                   + meta["log"])[:200]
    cfg_save("integrations", meta)
    if failed:
        st.error("not written → " + " · ".join(failed))
    if written:
        st.success(f"{action} → {', '.join(written)}")
        os.environ[n] = str(value)  # this server sees it immediately
        remote_lists.clear()
        st.session_state["int_flash"] = f"{n}: {action} → {', '.join(written)}"
        refresh()


def do_delete(entry, targets):
    n = entry["name"]
    for tg in targets:
        try:
            {"env": lambda: ENV.delete(n), "toml": lambda: TOML.delete(n),
             "gh": lambda: GH.delete(n), "edge": lambda: ED.delete(I.edge_name(entry))}[tg]()
        except Exception as e:  # noqa: BLE001
            st.error(f"{tg}: {str(e)[:140]}")
    meta["log"] = ([{"at": I.now_iso(), "name": n, "action": "delete", "targets": targets, "fp": ""}] + meta["log"])[:200]
    cfg_save("integrations", meta)
    remote_lists.clear()
    refresh()


def target_boxes(entry, prefix, default_all=True):
    """Checkbox row for the stores this secret can go to; returns the picked set."""
    opts = [k for k in ("env", "gh", "edge", "toml") if entry["targets"].get(k)]
    labels = {"env": "local pipeline/.env", "gh": "GitHub secret (CI)", "edge": f"edge secret ({I.edge_name(entry)})",
              "toml": "admin secrets.toml"}
    cols = st.columns(len(opts) or 1)
    picked = set()
    for c, k in zip(cols, opts):
        disabled = (k == "gh" and not GH) or (k == "edge" and not ED)
        if c.checkbox(labels[k], value=default_all and not disabled, key=f"{prefix}_tg_{k}", disabled=disabled,
                      help="needs a token (see header)" if disabled else None):
            picked.add(k)
    return picked


# ---------- header ----------
rows_state = {s["name"]: store_state(s) for s in REG}
missing_gh = [n for n, s in rows_state.items() if s["gh"][0] is False]
missing_edge = [n for n, s in rows_state.items() if s["edge"][0] is False]
missing_local = [n for n, s in rows_state.items() if s["env"][0] is False]
header("Integrations", "Every outside service FinSwipe depends on — keys by account, where each one lives, "
       "whether it works, and one place to add, rotate or push them.",
       [pill(f"GitHub {gh_login or 'no token'}" + (f" · {scopes}" if scopes else ""), bool(GH) and not str(gh_login).startswith("error"),
             None if GH else DIM),
        pill("Supabase mgmt ok" if ED and not rerr.get("edge") else "Supabase mgmt: " + (rerr.get("edge") or "no token"), bool(ED) and not rerr.get("edge")),
        pill(f"{len(missing_gh)} missing in CI", not missing_gh, RED if missing_gh else GREEN),
        pill(f"{len(missing_edge)} missing on edge", not missing_edge, RED if missing_edge else GREEN)])
flash = st.session_state.pop("int_flash", None)
if flash:
    st.success(flash)
kpis([("Secrets tracked", len(REG), f"{len(GROUPS)} providers", BLUE),
      ("Local .env", f"{len(REG) - len(missing_local) - sum(1 for s in rows_state.values() if s['env'][0] is None)}/{sum(1 for s in rows_state.values() if s['env'][0] is not None)}", "set on this PC", GREEN if not missing_local else AMBER),
      ("GitHub CI", f"{sum(1 for s in rows_state.values() if s['gh'][0])}/{sum(1 for s in rows_state.values() if s['gh'][0] is not None)}", "Actions secrets", RED if missing_gh else GREEN),
      ("Edge", f"{sum(1 for s in rows_state.values() if s['edge'][0])}/{sum(1 for s in rows_state.values() if s['edge'][0] is not None)}", "qa / deepread", RED if missing_edge else GREEN),
      ("AI keys in use · CI today", len({k for k in ci_use}), f"{sum(ci_use.values())} calls", GREEN),
      ("AI keys in use · edge today", len({k for k in edge_use}), f"{sum(edge_use.values())} calls", GREEN)])

tab_m, tab_p, tab_s, tab_a, tab_l = st.tabs(["Matrix", "Providers", "Sync", "Add a provider", "Log & lint"])

# ---------- matrix ----------
with tab_m:
    def cell(v):
        ok, d = v
        return "—" if ok is None else (("✓ " + d).strip() if ok else ("MISSING " + d).strip())
    table = []
    for s in REG:
        st_ = rows_state[s["name"]]
        n_local = len(I.split_list(local_value(s))) if s["shape"] == "list" else (1 if local_value(s) else 0)
        ci = sum(v for (p, _), v in ci_use.items() if p == s["name"])
        ed = sum(v for (p, _), v in edge_use.items() if p == s["name"])
        table.append({"group": s["group"], "secret": s["name"], "shape": s["shape"],
                      "local": cell(st_["env"]) if s["targets"].get("env") else ("✓ secrets.toml" if local_value(s) else "—"),
                      "GitHub CI": cell(st_["gh"]), "edge": cell(st_["edge"]), "admin toml": cell(st_["toml"]),
                      "keys local": n_local, "CI calls today": ci, "edge calls today": ed})
    st.dataframe(table, hide_index=True, width="stretch", height=min(60 + 36 * len(table), 620))
    st.markdown("<div class='fs-muted'>Remote stores only expose names and dates — never values. "
                "“CI calls today” / “edge calls today” (from the run log and edge log) are the proof a key is "
                "actually being used out there.</div>", unsafe_allow_html=True)
    section("Build-time only", "baked into the APK — change = rebuild")
    kv_rows([(f"{n} · {where}", path) for n, where, path in I.BUILD_TIME])
    section("Test every local key", "each probe is one request against that provider")
    note("GNews / NewsData / MarketAux probes each spend one request of today's free quota. Groq is "
         "Cloudflare-blocked from this PC — 'unreachable' there is expected; look at its CI calls instead.", DIM)
    if st.button("Test all local keys", type="primary", icon=":material/network_check:"):
        rows = []
        with st.spinner("probing …"):
            for s in REG:
                v = local_value(s)
                vals = I.split_list(v) if s["shape"] == "list" else ([v] if v else [])
                if not vals:
                    rows.append((s["name"], "", None, "unset locally"))
                for i, k in enumerate(vals, 1):
                    ok, d = I.probe(s, k, URL, PROJECT_REF)
                    rows.append((f"{s['name']}#{i}" if s["shape"] == "list" else s["name"], I.fingerprint(k), ok, d))
        keys_table(rows)

# ---------- providers ----------
with tab_p:
    for g in GROUPS:
        entries = [s for s in REG if s["group"] == g]
        state_ok = all(rows_state[s["name"]]["gh"][0] is not False and rows_state[s["name"]]["edge"][0] is not False
                       for s in entries)
        with st.expander(f"{g} — " + ", ".join(s["name"] for s in entries), expanded=not state_ok):
            for s in entries:
                n, shape, pre = s["name"], s["shape"], f"p_{s['name']}"
                stt = rows_state[n]
                st.markdown(pill(n, True, DIM)
                            + (pill("local " + ("✓" if stt["env"][0] else "missing"), bool(stt["env"][0])) if stt["env"][0] is not None else "")
                            + (pill("CI " + ("✓" if stt["gh"][0] else "missing"), bool(stt["gh"][0])) if stt["gh"][0] is not None else "")
                            + (pill("edge " + ("✓" if stt["edge"][0] else "missing"), bool(stt["edge"][0])) if stt["edge"][0] is not None else "")
                            + (pill("admin " + ("✓" if stt["toml"][0] else "missing"), bool(stt["toml"][0])) if stt["toml"][0] is not None else ""),
                            unsafe_allow_html=True)
                c1, c2 = st.columns([3, 1])
                c1.markdown(f"<div class='fs-muted'>{escape(s['note'])}<br><b>Read by:</b> {escape(s['readers'])}</div>",
                            unsafe_allow_html=True)
                if s.get("console"):
                    c2.link_button("Open provider console", s["console"].replace("{ref}", PROJECT_REF), icon=":material/open_in_new:")
                cur = local_value(s)

                if shape == "list":
                    keys = I.split_list(cur)
                    labels = meta["labels"].get(n, {})
                    st.dataframe([{"#": i, "account / label": labels.get(I.fingerprint(k), ""), "fingerprint": I.fingerprint(k),
                                   "CI calls today": ci_use.get((n, i), 0), "edge calls today": edge_use.get((n, i), 0)}
                                  for i, k in enumerate(keys, 1)] or [{"#": "", "account / label": "no keys locally", "fingerprint": "", "CI calls today": "", "edge calls today": ""}],
                                 hide_index=True, width="stretch")
                    st.caption("CI / edge counts come from lane labels `model#i`; a key with 0 calls all day while others serve "
                               "is dead, throttled, or not pushed yet.")
                    # --- add a key
                    with st.form(f"{pre}_add", border=True):
                        st.markdown("<div class='fs-sec' style='margin-top:0'><span class='t'>Add a key</span>"
                                    "<span class='h'>paste → label with the account → test → save to the stores</span></div>",
                                    unsafe_allow_html=True)
                        a1, a2 = st.columns([3, 2])
                        new_key = a1.text_input("Key", type="password", key=f"{pre}_newkey")
                        new_label = a2.text_input("Account / label", placeholder="tanishk@gmail.com", key=f"{pre}_newlabel")
                        picked = target_boxes(s, f"{pre}_add")
                        b1, b2, _ = st.columns([1, 1, 3])
                        test = b1.form_submit_button("Test", icon=":material/network_check:")
                        save = b2.form_submit_button("Save", type="primary", icon=":material/save:")
                        if (test or save) and new_key.strip():
                            k = new_key.strip()
                            if k in keys:
                                st.error("that key is already in the list")
                            else:
                                ok, d = I.probe(s, k, URL, PROJECT_REF)
                                (st.success if ok else st.warning if ok is None else st.error)(f"{I.fingerprint(k)} → {d}")
                                if save and (ok is not False or n == "GROQ_API_KEY"):
                                    new_list = keys + [k]
                                    if new_label.strip():
                                        meta["labels"].setdefault(n, {})[I.fingerprint(k)] = new_label.strip()
                                    do_save(s, I.join_list(new_list), picked, f"add key #{len(new_list)}", I.fingerprint(k))
                                elif save:
                                    st.error("not saved — the probe failed. (Groq keys can't be probed from here and are saved anyway.)")
                    # --- manage an existing key
                    if keys:
                        m1, m2, m3, m4, m5 = st.columns([1, 2, 1, 1, 1])
                        idx = m1.selectbox("Key #", list(range(1, len(keys) + 1)), key=f"{pre}_idx")
                        k = keys[idx - 1]
                        relabel = m2.text_input("Label", labels.get(I.fingerprint(k), ""), key=f"{pre}_relabel", label_visibility="collapsed",
                                                placeholder="account / label")
                        if m3.button("Save label", key=f"{pre}_savelabel"):
                            meta["labels"].setdefault(n, {})[I.fingerprint(k)] = relabel.strip()
                            cfg_save("integrations", meta)
                            refresh()
                        if m4.button("Test", key=f"{pre}_testone", icon=":material/network_check:"):
                            ok, d = I.probe(s, k, URL, PROJECT_REF)
                            (st.success if ok else st.error)(f"#{idx} {I.fingerprint(k)} → {d}")
                        with m5.popover("Remove"):
                            st.markdown(f"Remove key #{idx} `{I.fingerprint(k)}` from the list and push the shorter list to:")
                            rp = target_boxes(s, f"{pre}_rm")
                            if st.button("Remove it", key=f"{pre}_rmgo", type="primary"):
                                do_save(s, I.join_list([x for x in keys if x != k]), rp, f"remove key #{idx}", I.fingerprint(k))
                        with st.popover("Replace (rotate) this key"):
                            rk = st.text_input("New key", type="password", key=f"{pre}_rk")
                            rp2 = target_boxes(s, f"{pre}_rp")
                            if st.button("Replace", key=f"{pre}_rpgo", type="primary") and rk.strip():
                                new_list = [rk.strip() if x == k else x for x in keys]
                                if labels.get(I.fingerprint(k)):
                                    meta["labels"].setdefault(n, {})[I.fingerprint(rk.strip())] = labels[I.fingerprint(k)]
                                do_save(s, I.join_list(new_list), rp2, f"rotate key #{idx}", I.fingerprint(rk.strip()))

                elif shape == "json":
                    st.markdown(f"<div class='fs-muted'>current: {('set · ' + I.fingerprint(cur)) if cur else 'not set locally'}</div>",
                                unsafe_allow_html=True)
                    up = st.file_uploader("Service-account JSON file", type=["json"], key=f"{pre}_up")
                    picked = target_boxes(s, f"{pre}_json")
                    if up is not None:
                        raw = up.read().decode("utf8")
                        try:
                            one = json.dumps(json.loads(raw), separators=(",", ":"))
                        except ValueError:
                            st.error("not valid JSON")
                            one = None
                        if one:
                            j1, j2, _ = st.columns([1, 1, 3])
                            if j1.button("Test", key=f"{pre}_jtest", icon=":material/network_check:"):
                                ok, d = I.probe(s, one, URL, PROJECT_REF)
                                (st.success if ok else st.error)(d)
                            if j2.button("Save", key=f"{pre}_jsave", type="primary", icon=":material/save:"):
                                ok, d = I.probe(s, one, URL, PROJECT_REF)
                                if ok:
                                    do_save(s, one, picked, "replace", I.fingerprint(json.loads(one).get("private_key_id", "")))
                                else:
                                    st.error(f"not saved — {d}")

                else:  # single
                    st.markdown(f"<div class='fs-muted'>current: {('set · ' + I.fingerprint(cur)) if cur else 'not set locally'}</div>",
                                unsafe_allow_html=True)
                    with st.form(f"{pre}_single", border=True):
                        val = st.text_input("New value", type="password", key=f"{pre}_val")
                        picked = target_boxes(s, f"{pre}_sg")
                        b1, b2, _ = st.columns([1, 1, 3])
                        test = b1.form_submit_button("Test", icon=":material/network_check:")
                        save = b2.form_submit_button("Save", type="primary", icon=":material/save:")
                        if (test or save) and val.strip():
                            ok, d = I.probe(s, val.strip(), URL, PROJECT_REF)
                            (st.success if ok else st.warning if ok is None else st.error)(f"{I.fingerprint(val)} → {d}")
                            if save and ok is not False:
                                do_save(s, val.strip(), picked, "set", I.fingerprint(val))
                            elif save:
                                st.error("not saved — the probe failed")
                if cur and s["targets"].get("env"):
                    with st.popover("Reveal local value"):
                        st.code(cur if shape != "json" else cur[:400] + " …", language=None)
                st.markdown("<div style='height:6px'></div>", unsafe_allow_html=True)
    section("Models & throttle", "not secrets — live overrides on Pipeline › Knobs")
    st.markdown(" ".join(pill(f"{k} = {str(effective_knob(k))[:60]}", True, DIM) for k in I.MODEL_KNOBS), unsafe_allow_html=True)
    page_link("pipeline", "→ Pipeline › Knobs", icon=":material/tune:")

# ---------- sync ----------
with tab_s:
    st.markdown("<div class='fs-muted'>Remote values can't be read back, so 'in sync' means <i>you pushed the "
                "local value</i>. Pushing <b>overwrites</b> the remote value with the local one — check the key "
                "count on the Matrix tab first.</div>", unsafe_allow_html=True)
    note("GitHub-secret changes only reach the pipeline after <b>Restart pipeline</b> (a running job keeps the "
         "secrets it started with). Edge-secret changes apply on the next request.", AMBER, html=True)
    last_push = {}
    for e in meta["log"]:
        for tg in e.get("targets", []):
            last_push.setdefault((e["name"], tg), e["at"])
    sync_rows = []
    for s in REG:
        v = local_value(s)
        if not v:
            continue
        for tg in ("gh", "edge"):
            if s["targets"].get(tg):
                stt = rows_state[s["name"]][tg]
                sync_rows.append({"secret": s["name"], "store": "GitHub CI" if tg == "gh" else f"edge ({I.edge_name(s)})",
                                  "remote": "set" if stt[0] else "MISSING",
                                  "remote updated": stt[1] if tg == "gh" else "",
                                  "last pushed from here": (ago(last_push[(s["name"], tg)]) + " ago") if (s["name"], tg) in last_push else "never",
                                  "local": f"{len(I.split_list(v))} key(s)" if s["shape"] == "list" else I.fingerprint(v)})
    st.dataframe(sync_rows, hide_index=True, width="stretch")
    c1, c2, c3 = st.columns([2, 1, 1])
    pick = c1.selectbox("Secret", [s["name"] for s in REG if local_value(s) and (s["targets"].get("gh") or s["targets"].get("edge"))])
    ent = I.by_name(pick, meta["custom"])
    if ent and ent["targets"].get("gh") and c2.button("local → GitHub", disabled=not GH, icon=":material/cloud_upload:"):
        do_save(ent, local_value(ent), {"gh"}, "push", I.fingerprint(local_value(ent)))
    if ent and ent["targets"].get("edge") and c3.button("local → edge", disabled=not ED, icon=":material/cloud_upload:"):
        do_save(ent, local_value(ent), {"edge"}, "push", I.fingerprint(local_value(ent)))
    section("Everything at once")
    p1, p2, _ = st.columns([1, 1, 2])
    sure = p1.checkbox("I know this overwrites every remote value with the local .env", key="sync_all_sure")
    if p1.button("Push all local → CI + edge", type="primary", disabled=not sure, icon=":material/sync:"):
        n_ok = 0
        for s in REG:
            v = local_value(s)
            if not v:
                continue
            for tg in ("gh", "edge"):
                if s["targets"].get(tg) and ((tg == "gh" and GH) or (tg == "edge" and ED)):
                    try:
                        (GH.put(s["name"], v) if tg == "gh" else ED.put(I.edge_name(s), v))
                        meta["log"] = [{"at": I.now_iso(), "name": s["name"], "action": "push-all", "targets": [tg],
                                        "fp": I.fingerprint(v)}] + meta["log"]
                        n_ok += 1
                    except Exception as e:  # noqa: BLE001
                        st.error(f"{s['name']} → {tg}: {str(e)[:120]}")
        meta["log"] = meta["log"][:200]
        cfg_save("integrations", meta)
        st.success(f"{n_ok} write(s) done")
        remote_lists.clear()
    if p2.button("Restart pipeline now", disabled=not GH, icon=":material/restart_alt:",
                 help="Cancels queued/running pipeline jobs and dispatches a fresh one that reads the new secrets"):
        try:
            n = GH.restart_pipeline()
            st.success(f"cancelled {n} run(s), dispatched a new one — see Pipeline › Control in ~30 s")
        except Exception as e:  # noqa: BLE001
            st.error(f"{e}")

# ---------- add a provider ----------
with tab_a:
    st.markdown("<div class='fs-muted'>Register a new env variable so this page tracks, tests and pushes it. "
                "The pipeline code still has to <i>read</i> it — the YAML line below goes under "
                "<code>env:</code> in .github/workflows/pipeline.yml in a commit.</div>", unsafe_allow_html=True)
    with st.form("add_provider"):
        a1, a2, a3 = st.columns([2, 1, 1])
        name = a1.text_input("Env variable name", placeholder="POLYGON_API_KEY")
        shape = a2.selectbox("Shape", ["single", "list", "json"])
        group = a3.text_input("Provider / group", placeholder="Polygon")
        readers = st.text_input("Read by (who uses it)", placeholder="pipeline market.py (CI)")
        console = st.text_input("Console URL (where keys are made)", placeholder="https://…")
        note_txt = st.text_input("Free-tier note", placeholder="5 req/min per account")
        probe_url = st.text_input("Probe URL with {key} (optional, GET must return 200 for a live key)",
                                  placeholder="https://api.example.com/v1/ping?apikey={key}")
        t1, t2, t3 = st.columns(3)
        tg_env, tg_gh, tg_edge = t1.checkbox("local .env", True), t2.checkbox("GitHub secret (CI)", True), t3.checkbox("edge secret", False)
        if st.form_submit_button("Register", type="primary", icon=":material/add:"):
            nm = name.strip().upper()
            if not nm or not nm.replace("_", "").isalnum():
                st.error("name must be like POLYGON_API_KEY")
            elif I.by_name(nm, meta["custom"]):
                st.error("already registered")
            else:
                entry = {"name": nm, "group": group.strip() or "Custom", "shape": shape, "readers": readers.strip(),
                         "console": console.strip(), "note": note_txt.strip(),
                         "probe": None, "probe_url": probe_url.strip(),
                         "targets": {k: v for k, v in (("env", tg_env), ("gh", tg_gh), ("edge", tg_edge)) if v}}
                meta["custom"].append(entry)
                cfg_save("integrations", meta)
                st.success(f"{nm} registered — now add to pipeline.yml:")
                st.code(I.yaml_snippet(nm), language="yaml")
                refresh()
    if meta["custom"]:
        section("Custom providers")
        for c in meta["custom"]:
            c1, c2, c3 = st.columns([3, 3, 1])
            c1.markdown(pill(c["name"], True, DIM) + f" <span class='fs-muted'>{escape(c.get('group', ''))} · {c.get('shape')}</span>",
                        unsafe_allow_html=True)
            c2.code(I.yaml_snippet(c["name"]).strip(), language="yaml")
            if c3.button("Unregister", key=f"unreg_{c['name']}"):
                meta["custom"] = [x for x in meta["custom"] if x["name"] != c["name"]]
                cfg_save("integrations", meta)
                refresh()

# ---------- log + lint ----------
with tab_l:
    section("Change log", "fingerprints only — never values")
    st.dataframe([{"when": ago(e["at"]) + " ago", "secret": e["name"], "action": e["action"],
                   "stores": ", ".join(e.get("targets") or []), "fingerprint": e.get("fp", "")} for e in meta["log"]],
                 hide_index=True, width="stretch", height=320)
    section(".env lint", "variables nothing reads, dead names, duplicates")
    issues = I.lint_env(ENV)
    if not issues:
        st.markdown(pill("pipeline/.env is clean"), unsafe_allow_html=True)
    for kind, nme, advice in issues:
        st.markdown(pill(f"{kind}: {nme}", False, AMBER) + f" <span class='fs-muted'>{escape(advice)}</span>", unsafe_allow_html=True)
    if issues and st.button("Fix .env", icon=":material/build:", help="Rename dead names, drop duplicate lines (first wins). Unknown keys are left alone."):
        cur = ENV.read()
        for old, new in I.DEAD_RENAMES.items():
            if old in cur:
                if new not in cur:
                    ENV.put(new, cur[old])
                ENV.delete(old)
        for d in ENV.duplicates():
            ENV.put(d, ENV.read()[d])  # put() keeps the first and drops the rest
        st.success("fixed")
        refresh()
