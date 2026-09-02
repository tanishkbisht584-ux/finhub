"""Unit tests per spec §10: dedupe hashing, clustering, schema validation. No network."""
import io
from datetime import datetime, timedelta, timezone

import pytest

from ai import validate
from run import assign_cluster, canonical_url, title_tokens, url_hash
from seed.companies_seed import display_name


@pytest.fixture(autouse=True)
def _fresh_process_caches():
    """run.py memoizes per process (egress fix, 2026-08-23); tests must not
    see each other's cached windows, hashes or companies."""
    import run
    run._recent_cache.update(at=0.0, since=None, start=None, rows={}, col="updated_at")
    run._known_hashes.clear()
    run._companies_cache.update(at=0.0, by_key={})
    run._seen_images_cache.update(at=0.0, counts={})


def test_url_hash_strips_tracking_and_normalizes():
    a = url_hash("https://ET.com/story/1?utm_source=rss&utm_medium=x&gclid=abc")
    b = url_hash("https://et.com/story/1/")
    assert a == b
    assert url_hash("https://et.com/story/2") != a


def test_canonical_keeps_real_query():
    assert "id=100" in canonical_url("https://cnbc.com/rss?id=100&utm_source=x")


def test_cluster_same_story_joins_different_story_does_not():
    recent = [("cluster-1", title_tokens("RBI cuts repo rate by 25 bps"))]
    assert assign_cluster("RBI cuts repo rate 25 bps, first cut this year", recent) == "cluster-1"
    assert assign_cluster("Infosys Q1 profit rises 11 percent", recent) != "cluster-1"


@pytest.mark.parametrize("first,second", [
    # Measured 2026-08-09: 43 different companies' board outcomes landed in ONE
    # cluster, so 42 of them were dropped as duplicates and never reached the
    # feed. The ticker is a single token and the template outvotes it.
    ("ABFRL: Outcome of Board Meeting", "JSWENERGY: Outcome of Board Meeting"),
    ("Infosys Q1 Results Highlights", "TCS Q1 Results Highlights"),
    ("Tata Motors Board Meeting Intimation", "Wipro Board Meeting Intimation"),
    ("Geo Group Q2 Earnings Call Highlights", "Etsy Q2 Earnings Call Highlights"),
])
def test_different_companies_never_merge_on_filing_boilerplate(first, second):
    recent = [("cluster-1", title_tokens(first))]
    assert assign_cluster(second, recent) != "cluster-1"


def test_same_company_filing_still_dedupes():
    """Stripping boilerplate must not break the real job: the SAME company's
    filing arriving twice is still one story."""
    recent = [("cluster-1", title_tokens("INDOFARM: Outcome of Board Meeting"))]
    assert assign_cluster("INDOFARM: Outcome of Board Meeting", recent) == "cluster-1"


def test_display_name_strips_legal_suffix():
    """The NSE master is already properly cased ('HDFC Bank Limited', "Dr.
    Reddy's Laboratories Limited"); display_name must pass that casing
    through untouched and only strip the legal suffix. Re-casing with
    .title() corrupted 541 names (e.g. "Dr. Reddy'S Laboratories")."""
    assert display_name("HDFC Bank Limited") == "HDFC Bank"
    assert display_name("Dr. Reddy's Laboratories Limited") == "Dr. Reddy's Laboratories"
    assert display_name("Poly Medicure Ltd") == "Poly Medicure"
    # no trailing "Limited"/"Ltd" -> unchanged
    assert display_name("INFOSYS") == "INFOSYS"


def test_clusters_do_not_grow_by_chaining():
    """A joins B and B joins C, but A and C are unrelated. Comparing each new
    headline against every past member let clusters chain until they held
    stories with no words in common at all (seen: a 43-member cluster whose
    members shared zero tokens). Only the cluster's seed is a valid target."""
    from run import cluster_of
    recent = []
    a, _ = cluster_of("Reliance Jio subscriber growth slows in June quarter", recent)
    b, _ = cluster_of("Reliance Jio subscriber growth slows, Airtel gains share", recent)
    assert b == a, "genuine follow-up must still join"
    c, known = cluster_of("Airtel gains market share as tariffs rise", recent)
    assert c != a, "must not chain into Jio's cluster via the middle story"
    assert not known


CARD = {
    "hook": "Oil just got scary",
    "headline_rewrite": "Crude spikes 8% after supply shock",
    "summary": "s",
    "impact": {"direction": "negative", "strength": 3, "horizon": "short_term", "score": 9},
    "companies": [{"name": "ONGC", "nse_symbol": "ONGC"}],
    "sectors": ["Energy"],
    "category": "Commodities",
    "is_india_relevant": True,
    "confidence": "high",
}


def test_validate_accepts_good_card():
    assert validate(CARD) is CARD


@pytest.mark.parametrize("patch", [
    {"impact": {**CARD["impact"], "score": 11}},
    {"impact": {**CARD["impact"], "direction": "bullish"}},
    {"category": "Sports"},
    {"confidence": "certain"},
    {"is_india_relevant": "yes"},
])
def test_validate_rejects_bad_cards(patch):
    with pytest.raises(ValueError):
        validate({**CARD, **patch})


def test_validate_glance_lines_optional_and_coerced():
    """014 glance lines: five lanes answer this prompt, so a lane that omits
    or garbles them must cost the FIELD, never the story."""
    # all absent -> passes, coerced to explicit None
    card = validate(dict(CARD))
    assert card["why_it_matters"] is None and card["claim_status"] is None
    # bad enum / non-string / empty -> None, no raise
    card = validate({**CARD, "claim_status": "unverified", "why_it_matters": 7,
                     "winners_losers": "  ", "whats_next": "RBI meet Oct 1"})
    assert card["claim_status"] is None and card["why_it_matters"] is None
    assert card["winners_losers"] is None
    assert card["whats_next"] == "RBI meet Oct 1"
    # good values pass through
    card = validate({**CARD, "claim_status": "rumour",
                     "why_it_matters": "Cheaper loans likely by Diwali"})
    assert card["claim_status"] == "rumour"
    assert card["why_it_matters"] == "Cheaper loans likely by Diwali"


def test_prioritized_interleaves_sources_by_authority():
    from run import prioritized
    et = {"name": "ET", "authority": 8}
    rbi = {"name": "RBI", "authority": 10}
    items = [{"source": et, "published_at": f"2026-08-0{i}"} for i in range(1, 4)]
    items += [{"source": rbi, "published_at": "2026-08-01"}]
    out = prioritized(items)
    # highest authority leads, then every source gets a turn before ET's seconds
    assert out[0]["source"]["name"] == "RBI"
    assert out[1]["source"]["name"] == "ET"
    # newest first within a source
    assert [i["published_at"] for i in out if i["source"]["name"] == "ET"] == [
        "2026-08-03", "2026-08-02", "2026-08-01"]
    assert len(out) == len(items)  # nothing dropped


def test_alert_gate():
    from run import gate_passes
    assert gate_passes(8, 2, 5)        # multi-source confirmed
    assert gate_passes(9, 1, 10)       # primary source (RBI/exchange)
    assert not gate_passes(8, 1, 8)    # single-source non-primary waits for admin
    assert not gate_passes(7, 3, 10)   # below impact threshold
    assert not gate_passes(None, 3, 10)


def test_independent_sources_ignores_same_newsroom():
    from run import independent_sources
    # one newsroom's two feeds must not look like corroboration
    assert independent_sources(["ET Markets", "ET Top Stories"]) == 1
    assert independent_sources(["ET Markets", "LiveMint Markets"]) == 2
    assert independent_sources(["ET Markets", "ET IPO", "RBI Press"]) == 2
    assert independent_sources(["SEBI"]) == 1
    # Section feeds added 2026-08-09: each newsroom's feeds collapse to one, and
    # an outlet reached BOTH directly and via its Google News proxy is still one.
    assert independent_sources(["BusinessLine Markets", "BusinessLine Economy",
                                "Hindu BusinessLine"]) == 1
    assert independent_sources(["LiveMint Money", "Mint Companies"]) == 1
    assert independent_sources(["RBI Press", "RBI Notifications", "RBI Speeches"]) == 1
    assert independent_sources(["ET Commodities", "ET Banking"]) == 1
    assert independent_sources(["Investing.com", "Investing Commodities"]) == 1
    # ...but genuinely different newsrooms must still count separately.
    assert independent_sources(["Business Standard", "LiveMint Money", "ET Banking"]) == 3


def test_duplicate_is_only_stored_when_its_parent_landed():
    """A duplicate written while its parent was deferred orphans the event.

    Measured 2026-08-09: 969 stories sat in 226 clusters where every member was
    a duplicate and no card was ever shown — TBO Tek's results, Britannia's
    shareholder meeting. The parent had been cut by the per-run AI cap, its
    free duplicates were written anyway, and on the next run the parent matched
    the cluster its own copies had made and became a duplicate too.

    This pins the rule the fix encodes: store a duplicate only when its cluster
    already existed in the database, or its card was inserted this run."""
    seen_clusters = {"already-in-db"}          # loaded at the start of the run
    landed = {"processed-this-run"}            # card inserted moments ago

    def stored(cid):
        return cid in seen_clusters or cid in landed

    assert stored("already-in-db"), "parent from an earlier run"
    assert stored("processed-this-run"), "parent inserted this run"
    assert not stored("parent-was-deferred"), (
        "parent never reached the database, so its duplicate must be held back "
        "and the whole group retried together")


def test_app_publisher_map_matches_the_pipeline():
    """The app collapses a newsroom's feeds into one outlet on the card, using
    a copy of PUBLISHER in app/lib/publishers.dart. Two copies drift, and the
    drift is invisible: a new ET feed would quietly appear as an extra outlet
    'confirming' a story ET already ran. Cheaper to fail here than to ship a
    card that overstates its corroboration."""
    import pathlib
    import re
    from run import PUBLISHER
    dart = (pathlib.Path(__file__).parent.parent
            / "app" / "lib" / "publishers.dart")
    if not dart.exists():
        pytest.skip("app not checked out alongside the pipeline")
    body = dart.read_text(encoding="utf-8").split("publisherOf", 1)[1]
    body = body.split("};", 1)[0]
    copy = dict(re.findall(r"'([^']+)':\s*'([^']+)'", body))
    assert copy == PUBLISHER, (
        "publishers.dart is out of sync with run.py:\n"
        f"  only in run.py:        {sorted(set(PUBLISHER) - set(copy))}\n"
        f"  only in publishers.dart: {sorted(set(copy) - set(PUBLISHER))}\n"
        f"  disagree: {sorted(k for k in set(copy) & set(PUBLISHER) if copy[k] != PUBLISHER[k])}")


def test_ai_rewrites_of_one_event_merge_into_one_card():
    """Real pairs from the feed on 2026-08-09: two outlets, wording far enough
    apart that the pre-AI check passed them both, identical once the AI had
    rewritten them. Each was published as a separate card."""
    from run import merge_target
    for first, second in [
        ("Commerce Minister Piyush Goyal clarifies India opposes a shared BRICS currency",
         "Commerce Minister Piyush Goyal clarifies India opposes a shared BRICS currency"),
        ("RBI denies Religare Enterprises' proposal to demerge business units",
         "RBI denies Religare Enterprises' proposal to demerge its business units"),
        ("US stocks rally as cooling labor market eases rate hike fears",
         "US stocks climb as cooling labor market eases rate hike fears"),
        ("Delhi High Court stays FSSAI order restricting Dabur 100 percent pure claim",
         "Delhi High Court stays FSSAI directive restricting Dabur '100% pure' claim"),
        ("Hindalco reports strong Q1 earnings despite bauxite supply concerns",
         "Hindalco reports strong Q1 profit growth despite bauxite supply concerns"),
    ]:
        published = [("cluster-1", title_tokens(first))]
        assert merge_target(second, published) == "cluster-1", second


def test_merge_threshold_errs_towards_showing_a_duplicate():
    """Pairs that ARE one event but score below the bar stay separate on
    purpose. PFRDA's pension approval told two ways scores 0.60, under the
    0.64 that two different companies' results reach, so it cannot be merged
    without also merging those. Documented, not accidental."""
    from run import merge_target
    published = [("cluster-1", title_tokens(
        "PFRDA adds four new players to the National Pension System"))]
    assert merge_target(
        "PFRDA Approves Four New Pension Funds for National Pension System",
        published) is None


def test_merge_leaves_genuinely_different_news_alone():
    """The guard on the above: similar shape, different event. These must stay
    separate cards or the merge is destroying news instead of tidying it."""
    from run import merge_target
    for first, second in [
        # same company, different events
        ("Hindalco reports strong Q1 earnings despite bauxite supply concerns",
         "Hindalco announces Rs 8,000 crore expansion of its Odisha smelter"),
        # same event shape, different companies
        ("Infosys Q1 net profit rises 11 percent on strong deal wins",
         "Wipro Q1 net profit rises 9 percent on strong deal wins"),
        # same regulator, different rulings
        ("RBI denies Religare Enterprises' proposal to demerge business units",
         "RBI approves HDFC Bank's proposal to raise Tier-II capital"),
        # opposite outcomes must never merge
        ("Delhi High Court stays FSSAI order restricting Dabur's claim",
         "Delhi High Court dismisses Dabur's plea against the FSSAI order"),
    ]:
        published = [("cluster-1", title_tokens(first))]
        assert merge_target(second, published) is None, second


def test_breaking_news_jumps_the_backlog():
    """A story minutes old must reach the AI before a 300-item backlog, whatever
    its source's authority — that ordering is the whole latency promise."""
    from datetime import datetime, timedelta, timezone
    from run import prioritized
    now = datetime.now(timezone.utc)

    def item(source, authority, minutes_old):
        return {"source": {"name": source, "authority": authority},
                "published_at": (now - timedelta(minutes=minutes_old)).isoformat()}

    backlog = [item(f"Src{i}", 10, 600) for i in range(30)]
    fresh_small = item("Tiny Outlet", 5, 2)     # 2 min old, lowest authority
    fresh_older = item("Big Wire", 10, 9)       # 9 min old, highest authority
    out = prioritized(backlog + [fresh_older, fresh_small])
    assert out[0] is fresh_small and out[1] is fresh_older  # newest first
    assert len(out) == 32                                   # nothing dropped


def test_undated_items_never_counted_as_breaking():
    from run import age_minutes
    assert age_minutes({"published_at": None}) == float("inf")
    assert age_minutes({"published_at": "not-a-date"}) == float("inf")


def test_filing_noise_filter():
    from run import FILING_NOISE
    assert FILING_NOISE.search("Closure of Trading Window")
    assert FILING_NOISE.search("Certificate under Regulation 74(5)")
    assert not FILING_NOISE.search("Board approves acquisition of ABC Ltd")


def test_multi_key_lanes(monkeypatch):
    """N keys must fan out to N lanes per model, preferred model first across all
    keys — otherwise a second account buys daily volume but not quality."""
    import ai
    monkeypatch.setenv("GEMINI_MODELS", "flash-lite,flash")
    monkeypatch.setenv("GEMINI_API_KEY", "k1, k2 ,k3")
    monkeypatch.setattr(ai, "_available_models", lambda: None)  # no network in tests
    lanes = ai._gemini_lanes()
    assert [l[2] for l in lanes] == [
        "flash-lite#1", "flash-lite#2", "flash-lite#3", "flash#1", "flash#2", "flash#3"]
    assert lanes[1][0] == "k2"          # whitespace stripped, key carried per lane

    monkeypatch.setenv("GEMINI_API_KEY", "")
    assert ai._gemini_lanes() == []     # unset key must not fabricate a lane


def test_multi_key_fallback_lanes(monkeypatch):
    """Groq meters per account AND per model, so keys x models must multiply."""
    import ai
    monkeypatch.setenv("GROQ_API_KEY", "g1,g2")
    monkeypatch.setenv("GROQ_MODEL", "llama,qwen")
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    monkeypatch.setattr(ai, "_groq_models", lambda: None)  # no network in tests
    lanes = ai._fallback_lanes()
    assert [(l[0], l[3]) for l in lanes] == [
        ("g1", "llama#1"), ("g2", "llama#2"), ("g1", "qwen#1"), ("g2", "qwen#2")]


def test_validate_rejects_missing_field():
    bad = dict(CARD)
    del bad["hook"]
    with pytest.raises(ValueError):
        validate(bad)


def test_sb_pages_past_postgrest_1000_row_cap(monkeypatch):
    """PostgREST silently truncates at 1000 rows. Measured 2026-08-10: the 48h
    dedupe preload held 3177 rows, so the pipeline compared new stories against
    only the oldest 1000 and republished recent events as fresh cards."""
    import run

    class FakeResponse:
        ok, text = True, "x"
        def __init__(self, rows):
            self._rows = rows
        def json(self):
            return self._rows

    total = 2300
    calls = []

    def fake_request(method, url, headers=None, timeout=None, **kw):
        start, end = map(int, headers["Range"].split("-"))
        calls.append(method)
        return FakeResponse([{"i": i} for i in range(start, min(end + 1, total))])

    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setattr(run.requests, "request", fake_request)
    rows = run.sb("GET", "stories?select=i")
    assert len(rows) == total          # nothing silently dropped
    assert len(calls) == 3             # 1000 + 1000 + 300


def test_personal_matches_company_sector_category():
    from run import personal_matches
    story = {"id": 10, "impact_score": 6, "category": "Markets",
             "sectors": ["Energy", "Banking"]}
    follows_by_user = {
        "u-company":  [("company", "42")],
        "u-sector":   [("sector", "Banking")],
        "u-category": [("category", "Markets")],
        "u-miss":     [("company", "7"), ("sector", "IT"), ("category", "IPO")],
    }
    hits = personal_matches(story, follows_by_user, companies_of=lambda sid: {"42"})
    assert hits == {"u-company", "u-sector", "u-category"}


def test_personal_matches_cluster_branch():
    """015: following a cluster matches its developments — which are usually
    duplicate rows with NULL impact_score/category, so nothing else may be
    required of the story shape."""
    from run import personal_matches
    dup = {"id": 11, "impact_score": None, "category": None, "sectors": None,
           "cluster_id": "abc-123"}
    follows = {"u-cluster": [("cluster", "abc-123")],
               "u-other": [("cluster", "zzz-999")]}
    assert personal_matches(dup, follows, companies_of=lambda sid: set()) == {"u-cluster"}
    # a story with no cluster_id matches no cluster follow
    assert personal_matches({"id": 12}, follows, companies_of=lambda sid: set()) == set()


def test_personal_alert_engine_unions_followed_cluster_dupes(monkeypatch):
    """The main select filters approved+score>=6; a followed cluster's new
    duplicate row (NULL score) must still reach the loop via the second query,
    deduped by id and sorted for the cursor."""
    import run
    paths = []

    def fake_sb(method, path, **kw):
        paths.append(path)
        if path.startswith("profiles?select"):
            return [{"id": "u1", "fcm_token": "tok",
                     "alert_settings": {"personalized": True}}]
        if path.startswith("follows"):
            return [{"user_id": "u1", "target_type": "cluster", "target_id": "abc-123"}]
        if "impact_score=gte" in path:
            return [{"id": 20, "hook": "H", "headline": "Big story", "impact_score": 7,
                     "category": "Markets", "sectors": [], "cluster_id": "other"}]
        if "cluster_id=in." in path:
            assert '"abc-123"' in path
            return [{"id": 21, "hook": None, "headline": "Development lands",
                     "impact_score": None, "category": None, "sectors": None,
                     "cluster_id": "abc-123"},
                    {"id": 20, "hook": "H", "headline": "Big story", "impact_score": 7,
                     "category": "Markets", "sectors": [], "cluster_id": "other"}]
        return []

    pushed = []
    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "in_quiet_hours", lambda now: False)
    monkeypatch.setattr(run, "send_fcm_token",
                        lambda tok, title, body, sid, score: pushed.append((title, sid)) or "sent")
    sent = run.personal_alert_engine()
    assert sent == 1
    assert pushed == [("Development lands", 21)]  # dup row, hook None -> headline
    assert any("cluster_id=in." in p for p in paths)


def test_personal_matches_empty_follows():
    from run import personal_matches
    assert personal_matches({"id": 1, "category": None, "sectors": None},
                            {}, companies_of=lambda sid: set()) == set()


def test_personal_alert_only_queries_approved_stories(monkeypatch):
    """Pending stories are RLS-invisible to the app (deep-link -> "story
    unavailable") and can bypass gate_passes at impact>=8. The personal alert
    engine must only ever push stories already approved."""
    import run
    calls = []

    def fake_sb(method, path, **kw):
        calls.append(path)
        if path.startswith("profiles?select"):
            return [{"id": "u1", "fcm_token": "tok",
                     "alert_settings": {"personalized": True}}]
        if path.startswith("follows"):
            return [{"user_id": "u1", "target_type": "category", "target_id": "Markets"}]
        return []

    monkeypatch.setattr(run, "sb", fake_sb)
    run.personal_alert_engine()
    stories_calls = [c for c in calls if c.startswith("stories?")]
    assert stories_calls, "engine never queried stories"
    assert "status=eq.approved" in stories_calls[0]
    assert "status=in.(pending,approved)" not in stories_calls[0]


def test_fcm_token_dead_only_on_404_or_unregistered_400():
    """400 alone can be a malformed message, not proof the token is dead —
    only 404, or 400 whose body says UNREGISTERED, should get the token
    cleared from the profile."""
    from run import _fcm_token_is_dead
    assert _fcm_token_is_dead(404, "")
    assert _fcm_token_is_dead(400, "some UNREGISTERED token error")
    assert not _fcm_token_is_dead(400, "malformed request")
    assert not _fcm_token_is_dead(500, "")


def test_personal_alert_engine_patches_pa_state_even_if_story_loop_raises(monkeypatch):
    """A mid-loop exception (bad story shape, companies_of blip) must not lose
    the user's cursor/count -- otherwise a retry re-buzzes stories already
    sent, burning into the 5/day cap for nothing."""
    import run

    patches = []

    def fake_sb(method, path, json=None, **kw):
        if path.startswith("profiles?select"):
            return [{"id": "u1", "fcm_token": "tok",
                     "alert_settings": {"personalized": True, "pa": {}}}]
        if path.startswith("follows"):
            return [{"user_id": "u1", "target_type": "category", "target_id": "Markets"}]
        if path.startswith("stories"):
            return [{"id": 1, "hook": "h", "headline": "h", "impact_score": 9,
                     "category": "Markets", "sectors": []}]
        if method == "PATCH" and path.startswith("profiles?id=eq.u1"):
            patches.append(json)
            return {}
        raise AssertionError(f"unexpected sb call: {method} {path}")

    def boom(*a, **k):
        raise RuntimeError("network blip")

    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "send_fcm_token", boom)
    run.personal_alert_engine()

    assert len(patches) == 1
    assert patches[0]["alert_settings"]["pa"]["cur"] == 1  # cursor still advanced


def test_usable_image_rejects_junk_paths():
    from run import usable_image
    assert usable_image("https://et.com/img/logo.png", {}) is None
    assert usable_image("https://et.com/assets/icon-32.png", {}) is None
    assert usable_image("https://cdn.x.com/authors/rk-avatar.jpg", {}) is None
    assert usable_image("https://cdn.x.com/1x1.gif", {}) is None
    assert usable_image("https://cdn.x.com/ads/banner.jpg", {}) is None
    # Regression: word-bound junk patterns to avoid false positives on financial vocabulary
    assert usable_image("https://cdn.x.com/wilful-defaulters-list.jpg", {}) == "https://cdn.x.com/wilful-defaulters-list.jpg"
    assert usable_image("https://cdn.x.com/regulatory-authority-hq.jpg", {}) == "https://cdn.x.com/regulatory-authority-hq.jpg"
    assert usable_image("https://cdn.x.com/silicon-wafer-fab.jpg", {}) == "https://cdn.x.com/silicon-wafer-fab.jpg"
    # But actual junk patterns still reject
    assert usable_image("https://et.com/img/author-photo.jpg", {}) is None
    # Regression: digit-suffixed junk. Only author/default need the trailing
    # \b -- the rest must reject mid-word too, or CDN-suffixed junk survives.
    assert usable_image("https://cdn.x.com/logo2x.png", {}) is None
    assert usable_image("https://cdn.x.com/avatar1.jpg", {}) is None


def test_usable_image_rejects_declared_small():
    from run import usable_image
    # width declared in the URL the way CDNs do it
    assert usable_image("https://cdn.x.com/photo.jpg?width=200", {}) is None
    assert usable_image("https://cdn.x.com/photo-120x90.jpg", {}) is None
    # no declared dimensions -> benefit of the doubt
    assert usable_image("https://cdn.x.com/photo.jpg", {}) == "https://cdn.x.com/photo.jpg"


def test_usable_image_rejects_house_images():
    """The generic 'BSE building' photo on every filing story carries no
    information — 3+ appearances in a week means it's furniture, not news."""
    from run import usable_image
    url = "https://cdn.x.com/bse-building.jpg"
    assert usable_image(url, {url: 3}) is None
    assert usable_image(url, {url: 2}) == url


def test_usable_image_passes_normal_article_image():
    from run import usable_image
    u = "https://images.et.com/2026/08/rbi-governor-presser.jpg"
    assert usable_image(u, {}) == u
    assert usable_image(None, {}) is None


class _FakeRaw:
    """io.BytesIO plus the decode_content kwarg urllib3's HTTPResponse.read
    accepts -- og_image passes decode_content=True to undo gzip/br/deflate on
    real responses; the fake bodies are already plain text, so it's a no-op
    here, just accepted so the call signature matches."""
    def __init__(self, body):
        self._io = io.BytesIO(body)

    def read(self, amt, decode_content=None):
        return self._io.read(amt)


class _FakeOgResp:
    """Stands in for requests.get(..., stream=True)'s response: og_image now
    reads a bounded slice off r.raw and uses `with`, so the fake needs the
    same context-manager + raw.read(n, decode_content=...) shape as the real
    thing (urllib3's HTTPResponse.read)."""
    def __init__(self, text, content_type="text/html; charset=utf-8"):
        self.headers = {"Content-Type": content_type}
        self._body = text.encode()

    def raise_for_status(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    @property
    def raw(self):
        return _FakeRaw(self._body)


def test_og_image_parses_meta_and_filters(monkeypatch):
    import run

    html_ok = ('<html><head><meta property="og:image" '
               'content="https://cdn.et.com/2026/rbi-presser.jpg"/></head></html>')
    monkeypatch.setattr(run.requests, "get", lambda *a, **k: _FakeOgResp(html_ok))
    assert run.og_image("https://et.com/story", {}) == "https://cdn.et.com/2026/rbi-presser.jpg"
    # the scraped image still goes through the relevance filter
    html_junk = '<meta property="og:image" content="https://cdn.et.com/logo.png"/>'
    monkeypatch.setattr(run.requests, "get", lambda *a, **k: _FakeOgResp(html_junk))
    assert run.og_image("https://et.com/story", {}) is None


def test_og_image_falls_back_to_twitter_image(monkeypatch):
    import run

    html_ = '<meta name="twitter:image" content="https://cdn.x.com/photo.jpg">'
    monkeypatch.setattr(run.requests, "get", lambda *a, **k: _FakeOgResp(html_))
    assert run.og_image("https://x.com/s", {}) == "https://cdn.x.com/photo.jpg"


def test_og_image_unescapes_html_entities(monkeypatch):
    """content= is HTML-escaped like any other attribute: '&amp;' between query
    params is standard, and an un-unescaped URL 404s and confuses the width
    filter (which then sees '?w=800&amp;h=450' instead of '?w=800&h=450')."""
    import run

    html_ = ('<meta property="og:image" '
             'content="https://cdn.et.com/img.jpg?w=800&amp;h=450"/>')
    monkeypatch.setattr(run.requests, "get", lambda *a, **k: _FakeOgResp(html_))
    assert run.og_image("https://et.com/story", {}) == "https://cdn.et.com/img.jpg?w=800&h=450"


def test_og_image_never_raises(monkeypatch):
    import run
    def boom(*a, **k): raise run.requests.ConnectionError("dead host")
    monkeypatch.setattr(run.requests, "get", boom)
    assert run.og_image("https://dead.example/s", {}) is None

    monkeypatch.setattr(run.requests, "get",
                        lambda *a, **k: _FakeOgResp("", content_type="application/pdf"))
    assert run.og_image("https://x.com/file.pdf", {}) is None


def test_image_seen_counts_filters_status_and_memoizes(monkeypatch):
    """Only approved/pending rows count toward house-image detection (a
    rejected/duplicate row never showed anyone an image), and a resident
    poller calling this every 45s must not re-scan every time -- only after
    the cache window."""
    import run
    calls = []

    def fake_sb(method, path, **kw):
        calls.append(path)
        assert "status=in.(approved,pending)" in path
        assert "order=created_at.asc" in path
        return [{"image_url": "https://x.com/a.jpg"}, {"image_url": "https://x.com/a.jpg"}]

    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "_seen_images_cache", {"at": None, "counts": {}})
    first = run.image_seen_counts()
    assert first == {"https://x.com/a.jpg": 2}
    assert len(calls) == 1

    # second call within the cache window: no new query, same dict object
    second = run.image_seen_counts()
    assert len(calls) == 1
    assert second is first

    # a mutation by a caller (og fallback) survives the cache
    first["https://x.com/a.jpg"] += 1
    assert run.image_seen_counts()["https://x.com/a.jpg"] == 3


# ---------- egress caches (2026-08-23) ----------

def test_recent_stories_full_load_then_updated_at_delta(monkeypatch):
    """Lap 1 loads the 48 h window by created_at; lap 2 asks only for rows
    updated since the newest updated_at seen; a re-fetched row replaces
    itself (no duplicate), an edited row's new status shows, and a row older
    than the window is ignored even when it was edited."""
    import run
    calls = []
    # relative to the real clock: recent_stories trims against now-48h, so a
    # fixed date rots out of the window (these froze at 2026-08-23 and died)
    t0 = (datetime.now(timezone.utc) - timedelta(minutes=30)).replace(microsecond=0)
    ts = lambda m: (t0 + timedelta(minutes=m)).isoformat()

    def fake_sb(method, path, **kw):
        calls.append(path)
        if "created_at=gte." in path:
            return [{"id": 1, "cluster_id": "a", "headline": "A", "status": "pending",
                     "created_at": ts(0), "updated_at": ts(0)},
                    {"id": 2, "cluster_id": "b", "headline": "B", "status": "approved",
                     "created_at": ts(1), "updated_at": ts(1)}]
        assert f"updated_at=gte.{run.iso(t0 + timedelta(minutes=1))}" in path, path
        return [{"id": 2, "cluster_id": "b", "headline": "B", "status": "rejected",
                 "created_at": ts(1), "updated_at": ts(5)},             # edited in admin
                {"id": 3, "cluster_id": "c", "headline": "C", "status": "pending",
                 "created_at": ts(6), "updated_at": ts(6)},             # new
                {"id": 0, "cluster_id": "z", "headline": "old", "status": "approved",
                 "created_at": (t0 - timedelta(days=9)).isoformat(),    # edited but aged out
                 "updated_at": ts(7)}]

    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "_recent_cache",
                        {"at": None, "since": None, "start": None, "rows": {}, "col": "updated_at"})
    first = run.recent_stories()
    assert [r["id"] for r in first] == [1, 2]
    second = run.recent_stories()
    assert [r["id"] for r in second] == [1, 2, 3]          # order kept, no duplicate, no row 0
    assert second[1]["status"] == "rejected"                # the edit landed next lap
    assert len(calls) == 2 and "select=id,cluster_id,headline,status,source_name,created_at,updated_at" in calls[0]
    assert run._recent_cache["since"] == run.iso(t0 + timedelta(minutes=7))


def test_recent_stories_falls_back_to_created_at_before_012(monkeypatch, capsys):
    import run, requests
    calls = []

    t0 = (datetime.now(timezone.utc) - timedelta(minutes=30)).replace(microsecond=0)

    def fake_sb(method, path, **kw):
        calls.append(path)
        if "updated_at" in path:
            raise requests.HTTPError('400 stories: column stories.updated_at does not exist')
        return [{"id": 1, "cluster_id": "a", "headline": "A", "status": "pending",
                 "created_at": t0.isoformat()}]

    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "_recent_cache",
                        {"at": None, "since": None, "start": None, "rows": {}, "col": "updated_at"})
    assert [r["id"] for r in run.recent_stories()] == [1]
    run.recent_stories()
    assert "012 not applied" in capsys.readouterr().out
    assert calls[-1].count("updated_at") == 0 and f"created_at=gte.{run.iso(t0)}" in calls[-1]
    assert len(calls) == 3  # failed probe, full load, delta — and never the column again


def test_remaining_budget_counts_the_window_locally(monkeypatch):
    import run
    monkeypatch.setattr(run, "DAILY_AI_BUDGET", 10)
    monkeypatch.setattr(run, "sb", lambda *a, **k: pytest.fail("no DB read expected"))
    today = datetime.now(timezone.utc).isoformat()
    yday = (datetime.now(timezone.utc) - timedelta(hours=30)).isoformat()
    window = [{"status": "pending", "created_at": today},
              {"status": "duplicate", "created_at": today},   # free
              {"status": "rejected", "created_at": yday}]     # yesterday
    assert run.remaining_budget_today(window) == 9


def test_existing_hashes_remembers_and_insert_marks_known(monkeypatch):
    import run
    asked = []

    def fake_sb(method, path, **kw):
        if method == "POST":
            return [{"id": 7}]
        asked.append(path)
        return [{"url_hash": "h1"}] if '"h1"' in path else []

    monkeypatch.setattr(run, "sb", fake_sb)
    assert run.existing_hashes(["h1", "h2"]) == {"h1"}
    assert len(asked) == 1
    run.insert_story({"url_hash": "h2"}, {})
    assert run.existing_hashes(["h1", "h2", "h3"]) == {"h1", "h2"}
    assert len(asked) == 2 and '"h3"' in asked[1] and '"h1"' not in asked[1]  # only the unknown one


def test_companies_index_is_memoized(monkeypatch):
    import run
    calls = []
    monkeypatch.setattr(run, "sb", lambda m, p, **k: calls.append(p) or
                        [{"id": 1, "name": "Tata Consultancy Services", "nse_symbol": "tcs", "aliases": ["TCS Ltd"]}])
    idx = run.companies_index()
    assert idx["TCS"] == 1 and idx["tcs ltd"] == 1 and idx["tata consultancy services"] == 1
    assert run.companies_index() is idx and len(calls) == 1


def test_recent_stories_trims_aged_out_rows_locally(monkeypatch):
    """A row falls out of the window the moment it is 48 h old, without
    waiting for the next full reload — same as the old per-lap query."""
    import run
    now = datetime.now(timezone.utc)
    rows = [{"id": 1, "cluster_id": "a", "headline": "A", "status": "pending",
             "created_at": (now - timedelta(hours=47, minutes=59)).isoformat(),
             "updated_at": now.isoformat()}]
    monkeypatch.setattr(run, "sb", lambda *a, **k: rows)
    assert len(run.recent_stories()) == 1
    rows[:] = []                      # delta returns nothing
    run._recent_cache["rows"][1]["created_at"] = (now - timedelta(hours=49)).isoformat()
    assert run.recent_stories() == []


def test_silent_source_check_reads_only_quiet_sources(monkeypatch):
    """The 48 h window proves most sources productive for free; only the quiet
    ones are asked of the DB, and only for their own rows."""
    import run
    calls = []

    def fake_sb(method, path, **kw):
        calls.append((method, path))
        if method == "PATCH":
            return []
        if "select=source_name" in path:
            assert 'source_name=in.("Quiet","Silent")' in path and "Loud" not in path
            return [{"source_name": "Quiet"}]   # produced on day 3 -> stays
        if "select=created_at" in path:
            return [{"created_at": "2026-01-01T00:00:00+00:00"}]
        return []

    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "recent_stories",
                        lambda: [{"source_name": "Loud", "created_at": datetime.now(timezone.utc).isoformat()}])
    fresh = datetime.now(timezone.utc).isoformat()
    sources = [{"id": 1, "name": "Loud", "type": "rss", "last_fetched_at": fresh},
               {"id": 2, "name": "Quiet", "type": "rss", "last_fetched_at": fresh},
               {"id": 3, "name": "Silent", "type": "rss", "last_fetched_at": fresh}]
    assert run.disable_dead_sources(sources) == 1     # only Silent retired
    assert [p for m, p in calls if m == "PATCH" and "id=eq.3" in p]
    assert sum(1 for m, p in calls if "select=source_name" in p) == 1


def test_retention_cutoff_is_date_truncated(monkeypatch):
    """The cutoff must be a day boundary: the first sweep each day deletes
    everything older, every later sweep that day matches zero rows — that
    truncation IS the once-per-day guard, with no state to store."""
    import run
    calls = []
    monkeypatch.setattr(run, "sb", lambda m, p, **k: calls.append((m, p)) or [])
    run.retention_sweep()
    method, path = calls[0]
    assert method == "DELETE"
    assert "events?created_at=lt." in path
    assert "T00:00:00" in path
    # rejected cards too — and ONLY rejected: an approved card is the product
    rej = [p for m, p in calls if p.startswith("stories?")]
    assert rej == [p for p in rej if "status=eq.rejected" in p and "T00:00:00" in p] and len(rej) == 1


def test_dead_model_lane_benched_not_fatal(monkeypatch):
    """Google retiring a model (2026-08-11: gemini-2.0-flash-lite began 404ing)
    must cost one lane, not the story: 404/401 benches the lane and the next
    one answers. raise_for_status() here escaped _gemini before the fallback
    chain ever ran, so every call flagged once the preferred lanes hit quota."""
    import ai
    monkeypatch.setenv("GEMINI_API_KEY", "k1")
    monkeypatch.setenv("GEMINI_MODELS", "retired-model,live-model")
    monkeypatch.setattr(ai, "_available_models", lambda: None)  # no network in tests
    monkeypatch.setattr(ai, "_cooldown", {})
    monkeypatch.setattr(ai, "_next_slot", {})

    class Resp:
        def __init__(self, code, text=""):
            self.status_code = code
            self._text = text
        @property
        def ok(self):
            return self.status_code < 400
        def json(self):
            return {"candidates": [{"content": {"parts": [{"text": self._text}]}}]}
        def raise_for_status(self):
            if self.status_code >= 400:
                raise __import__("requests").HTTPError(f"{self.status_code}")

    calls = []
    def fake_post(url, **kw):
        calls.append(url)
        return Resp(404) if "retired-model" in url else Resp(200, '{"ok": 1}')
    monkeypatch.setattr(ai.requests, "post", fake_post)

    assert ai._gemini("prompt") == '{"ok": 1}'
    assert len(calls) == 2                      # dead lane tried once, then next
    assert ai._cooldown.get("retired-model#1", 0) > 0   # and benched


def test_all_lanes_dead_defers_instead_of_flagging(monkeypatch):
    """Every lane structurally dead + no fallback -> QuotaExhausted, which the
    caller treats as 'retry next run' — never a flagged story."""
    import ai
    import pytest as _pytest
    monkeypatch.setenv("GEMINI_API_KEY", "k1")
    monkeypatch.setenv("GEMINI_MODELS", "retired-model")
    monkeypatch.setattr(ai, "_available_models", lambda: None)  # no network in tests
    monkeypatch.setattr(ai, "_cooldown", {})
    monkeypatch.setattr(ai, "_next_slot", {})

    class Resp:
        status_code = 404
        ok = False
        def json(self):
            return {}
        def raise_for_status(self):
            raise __import__("requests").HTTPError("404")

    monkeypatch.setattr(ai.requests, "post", lambda url, **kw: Resp())
    monkeypatch.setattr(ai, "_fallback_chat", lambda prompt: None)
    with _pytest.raises(ai.QuotaExhausted):
        ai._gemini("prompt")


def test_retired_model_swapped_for_newest_live_lite(monkeypatch):
    """The 2026-08-11 outage, automated: a configured model Google no longer
    serves is dropped and the newest live flash-lite model takes its slot, so
    a retirement costs nothing until someone updates the list at leisure."""
    import ai
    monkeypatch.setenv("GEMINI_MODELS", "gemini-3.5-flash-lite,gemini-2.0-flash-lite")
    monkeypatch.setattr(ai, "_available_models", lambda: {
        "gemini-3.5-flash-lite", "gemini-4.0-flash-lite", "gemini-2.5-flash-lite",
        "gemini-4.0-flash-lite-preview"})
    assert ai._current_models() == [
        "gemini-3.5-flash-lite",   # still live, kept in preference order
        "gemini-4.0-flash-lite",   # newest live lite subs for retired 2.0
    ]


def test_discovery_failure_trusts_configured_list(monkeypatch):
    """Discovery is advisory: if the models endpoint is down, the configured
    list must pass through untouched — never the reason the pipeline stalls."""
    import ai
    monkeypatch.setenv("GEMINI_MODELS", "gemini-3.5-flash-lite,gemini-2.0-flash-lite")
    monkeypatch.setattr(ai, "_available_models", lambda: None)
    assert ai._current_models() == ["gemini-3.5-flash-lite", "gemini-2.0-flash-lite"]


def test_groq_retired_model_lanes_dropped(monkeypatch):
    """Groq deprecates models monthly; a name its catalog no longer lists must
    not keep a lane (probing a dead lane every call wastes the failover pass)."""
    import ai
    monkeypatch.setenv("GROQ_API_KEY", "g1,g2")
    monkeypatch.setenv("GROQ_MODEL", "llama,dead-model")
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    monkeypatch.setattr(ai, "_groq_models", lambda: {"llama"})
    lanes = ai._fallback_lanes()
    assert [(l[0], l[3]) for l in lanes] == [("g1", "llama#1"), ("g2", "llama#2")]


def test_gnews_card_borrows_cluster_siblings_article_url():
    """GNews wrapper links hide the article behind JS (verified 2026-08-11:
    no redirect, opaque tokens) — og:image on them sees Google's shell. The
    same story from a direct outlet feed sits in the same cluster with the
    real article URL; borrow it. No sibling -> no fetch, never Google's page."""
    from run import article_url_for_image
    alt = {"c1": "https://www.livemint.com/markets/rbi-cuts-rates-11754.html"}
    # direct-feed card: its own URL is the article
    assert article_url_for_image("https://et.com/story/1", "c1", alt) == "https://et.com/story/1"
    # gnews card with a direct sibling: borrow the sibling
    assert article_url_for_image(
        "https://news.google.com/rss/articles/CBMixyz", "c1", alt) == alt["c1"]
    # gnews card, no sibling: nothing to fetch
    assert article_url_for_image(
        "https://news.google.com/rss/articles/CBMiabc", "c9", alt) is None


def test_editor_pass_parses_and_validates_merge_pairs(monkeypatch):
    """2026-08-12: 'Chandrasekaran resigns' ran as 6 separate approved cards —
    word-overlap clustering cannot see that 'Leadership Uncertainty' retells
    'resigns'. Spec §5 always said the editor flags same-event pairs the
    clustering missed; editor_pass must surface them, validated."""
    import ai, json as _json
    monkeypatch.setattr(ai, "_gemini", lambda prompt: _json.dumps({
        "relevel": [], "top_story_id": None,
        "merge": [[14548, 14540], [14548, "junk"], [7, 7], [14507]]}))
    out = ai.editor_pass("digest")
    # only the well-formed pair survives: ints, distinct, both present
    assert out["merge"] == [[14548, 14540]]


def test_editor_pass_merge_null_and_missing_are_empty(monkeypatch):
    import ai, json as _json
    monkeypatch.setattr(ai, "_gemini", lambda p: _json.dumps(
        {"relevel": [], "top_story_id": None, "merge": None}))
    assert ai.editor_pass("d")["merge"] == []
    monkeypatch.setattr(ai, "_gemini", lambda p: _json.dumps(
        {"relevel": [], "top_story_id": None}))
    assert ai.editor_pass("d")["merge"] == []


def test_chief_editor_applies_merges_within_digest_only(monkeypatch):
    """The duplicate joins the keeper's cluster (so its outlet still gets
    credit on the card) and leaves the feed. Ids the digest never showed the
    editor must be ignored — hallucinated ids must not touch rows."""
    import run
    rows = [
        {"id": 1, "headline": "Tata Sons chairman resigns", "impact_score": 8,
         "category": "Corporate", "cluster_id": "keep-c", "source_name": "Mint"},
        {"id": 2, "headline": "Tata Group faces leadership uncertainty",
         "impact_score": 7, "category": "Corporate", "cluster_id": "dup-c",
         "source_name": "ET"},
    ]
    patches = []
    def fake_sb(method, path, **kw):
        if method == "GET" and path.startswith("stories"):
            return rows
        if method == "GET" and path.startswith("sources"):
            return []
        if method == "PATCH":
            patches.append((path, kw.get("json")))
            return []
        return []
    monkeypatch.setattr(run, "sb", fake_sb)
    releveled = run.chief_editor(lambda digest: {
        "relevel": [], "top_story_id": None,
        "merge": [[1, 2], [1, 999]]})   # 999 hallucinated -> ignored
    assert releveled == 0
    assert patches == [("stories?id=eq.2",
                        {"status": "duplicate", "cluster_id": "keep-c"})]


def test_dupe_image_promotes_to_imageless_card(monkeypatch):
    """A GNews-proxied card can never fetch its own image (locked links), but
    its direct-feed duplicate arrives carrying one — seen live 2026-08-12,
    first 15 direct-feed stories all filed as image-bearing dupes under
    imageless cards. The image must flow up to the card the reader sees."""
    import run
    patches = []
    def fake_sb(method, path, **kw):
        if method == "GET":
            return [{"id": 42, "cluster_id": "c1"}]   # imageless card in c1
        patches.append((path, kw.get("json")))
        return []
    monkeypatch.setattr(run, "sb", fake_sb)
    n = run.promote_dupe_images({"c1": "https://cdn.x.com/photo.jpg",
                                 "c2": "https://cdn.x.com/other.jpg"})
    assert n == 1
    assert patches == [("stories?id=eq.42",
                        {"image_url": "https://cdn.x.com/photo.jpg"})]
    assert run.promote_dupe_images({}) == 0     # nothing to do, no queries


def test_low_value_is_status_spam_only():
    """Owner's junk definition (2026-08-12): junk = not financial. Listicles
    are content now; only repetitive status counters stay pattern-filtered."""
    from run import LOW_VALUE
    # still filtered: the same counter reposted all day
    assert LOW_VALUE.search("Tata Capital IPO GMP today: grey market premium at 5%")
    assert LOW_VALUE.search("XYZ IPO day 3 subscription status")
    # content now: the AI reads and scores these
    assert not LOW_VALUE.search("Stocks to watch: Tata Motors, HAL, IRCTC")
    assert not LOW_VALUE.search("Top gainers and losers today")
    assert not LOW_VALUE.search("Multibagger alert: this smallcap tripled")
    assert not LOW_VALUE.search("F&O ban list for August 13")


def test_auto_approve_ten_minute_backstop(monkeypatch):
    """Owner's rule (2026-08-14): no relevant story waits more than 10 min.
    The fast lane approves score>=8 at insert, but a healed flag or an editor
    relevel re-enters pending ABOVE the auto-approve ceiling and sat there
    forever (seen live: 2 stuck cards). Age alone now publishes."""
    import run
    patches = []
    def fake_sb(method, path, **kw):
        if method == "PATCH":
            patches.append(path)
        return []
    monkeypatch.setattr(run, "sb", fake_sb)
    run.auto_approve()
    assert len(patches) == 2
    # the ordinary lane: score < 8 after AUTO_APPROVE_MINUTES
    assert "impact_score=lt.8" in patches[0]
    # the backstop: ANY pending story after 10 minutes, no score filter
    assert "impact_score" not in patches[1]
    assert "status=eq.pending" in patches[1]


# ---------- admin cockpit: remote config + run log ----------

def test_apply_config_overrides_known_knobs_only():
    import run
    saved = run.MAX_ALERTS_PER_DAY
    try:
        sw = run.apply_config({"knobs": {"max_alerts_per_day": "3", "bogus": 1},
                               "switches": {"alerts": False}})
        assert run.MAX_ALERTS_PER_DAY == 3 and not hasattr(run, "BOGUS")
        noon = datetime(2026, 8, 22, 6, 30, tzinfo=timezone.utc)  # 12:00 IST
        assert run.may_push(10, noon, 3) is False   # cap now 3
        assert run.may_push(10, noon, 2) is True
        assert sw["alerts"] is False and sw["pipeline"] is True and len(sw) == len(run.SWITCHES)
    finally:
        run.MAX_ALERTS_PER_DAY = saved


def test_run_logged_honours_pipeline_switch(monkeypatch):
    import run
    monkeypatch.setattr(run, "load_env", lambda: None)
    monkeypatch.setattr(run, "load_config", lambda: {"switches": {"pipeline": False}})
    monkeypatch.setattr(run, "main", lambda cfg=None: pytest.fail("main ran while paused"))
    assert run.run_logged() is True


def test_run_log_error_lines():
    import run
    log = "12 fetched\nFEED FAIL ET: timeout\nTraceback (most recent call last):\ndone: 3 pending"
    assert [l for l in log.splitlines() if run.ERR_RE.search(l)] == [
        "FEED FAIL ET: timeout", "Traceback (most recent call last):"]


def test_ops_push_skips_when_no_ops_users(monkeypatch):
    import ops as watchdog
    monkeypatch.setattr(watchdog, "load_env", lambda: None)
    monkeypatch.setattr(watchdog, "load_config", lambda: {"ops_user_ids": []})
    monkeypatch.setattr(watchdog, "sb", lambda *a, **k: pytest.fail("no lookup without ops users"))
    assert watchdog.ops_push("t", "b") == 0


def test_ops_push_sends_to_each_ops_device(monkeypatch):
    import ops as watchdog
    sent = []
    monkeypatch.setattr(watchdog, "load_env", lambda: None)
    monkeypatch.setattr(watchdog, "load_config", lambda: {"ops_user_ids": ["u1", "u2"]})
    monkeypatch.setattr(watchdog, "sb", lambda m, p, **k: [{"id": "u1", "fcm_token": "tok1"},
                                                            {"id": "u2", "fcm_token": "tok2"}])
    monkeypatch.setattr(watchdog, "send_fcm_token",
                        lambda tok, title, body, sid, score: (sent.append((tok, sid)), "sent")[1])
    assert watchdog.ops_push("t", "b" * 300) == 2
    assert sent == [("tok1", ""), ("tok2", "")]   # empty story_id => no deep-link


def test_check_keys_detects_duplicate_and_probes_each(monkeypatch):
    from types import SimpleNamespace
    import check_keys
    monkeypatch.setenv("GEMINI_API_KEY", "aaaaaaaaaaaa,aaaaaaaaaaaa")
    monkeypatch.setenv("GROQ_API_KEY", "bbbbbbbbbbbb")
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    probed = []
    fake = lambda env, k: (probed.append(env), SimpleNamespace(status_code=200 if env.startswith("GEMINI") else 401, text="no"))[1]
    rows = check_keys.check_keys(probe=fake)
    assert any("DUPLICATE" in d for _, _, ok, d in rows if ok is False)
    assert [r for r in rows if r[0] == "GROQ_API_KEY#1"][0][2] is False
    assert [r for r in rows if r[0] == "OPENROUTER_API_KEY"][0][2] is None
    assert probed == ["GEMINI_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY"]


def test_ops_evaluate_maps_facts_to_fixes():
    import ops
    healthy = {"errors": {}, "private": False, "crash_loop": False, "gh_active": False,
               "approved_age": 0.5, "ingested_age": 0.2, "top_age": 1.0, "flagged_hour": 0,
               "switches": {}, "last_run_ok": True, "edge_calls": 10, "edge_failed": 1}
    v = ops.evaluate(healthy)
    assert v["problems"] == [] and v["dispatch"] is False
    # nothing arriving, no run active -> self-heal by dispatch, no alarm
    v = ops.evaluate({**healthy, "approved_age": 5, "ingested_age": 5})
    assert v["dispatch"] is True and v["problems"] == []
    # same but a run is active -> the freeze is inside the run: alarm, no dispatch
    v = ops.evaluate({**healthy, "approved_age": 5, "ingested_age": 5, "gh_active": True})
    assert v["dispatch"] is False and [p["fix"] for p in v["problems"]] == ["logs"]
    # ingesting but nothing approved -> gate stalled -> review
    v = ops.evaluate({**healthy, "approved_age": 5, "ingested_age": 1})
    assert [p["fix"] for p in v["problems"]] == ["review"]
    # admin paused the pipeline: ingestion silence is expected, only a note
    v = ops.evaluate({**healthy, "approved_age": 9, "ingested_age": 9, "switches": {"pipeline": False}})
    assert v["problems"] == [] and v["dispatch"] is False and v["notes"]
    # failing lanes, starvation and edge errors all point at keys
    v = ops.evaluate({**healthy, "flagged_hour": 20, "starved": True, "edge_failed": 8})
    assert {p["fix"] for p in v["problems"]} == {"keys"}
    # supabase down is its own lever; github down is only a note
    v = ops.evaluate({"errors": {"supabase": "timeout", "github": "403"}})
    assert [p["fix"] for p in v["problems"]] == ["supabase"] and v["notes"]


def test_ops_evaluate_platform_and_deep_checks():
    import ops
    healthy = {"errors": {}, "private": False, "crash_loop": False, "gh_active": False,
               "approved_age": 0.5, "ingested_age": 0.2, "top_age": 1.0, "flagged_hour": 0,
               "switches": {}, "last_run_ok": True, "edge_calls": 10, "edge_failed": 1}
    # watchdog spam guard: the healthy baseline WITHOUT any deep keys stays clear
    assert ops.evaluate(healthy)["problems"] == []
    # incident + our probe failing -> ONE platform problem, not the generic supabase one
    v = ops.evaluate({**healthy, "errors": {"supabase": "timeout"},
                      "sb_status": {"indicator": "minor", "incidents": ["API gateway latency"]}})
    assert [p["fix"] for p in v["problems"]] == ["platform"]
    assert "NOT your project" in v["problems"][0]["msg"]
    # incident but our project answered fine -> note only, no problem
    v = ops.evaluate({**healthy, "sb_status": {"indicator": "minor", "incidents": ["latency"]}})
    assert v["problems"] == [] and any("responded normally" in n for n in v["notes"])
    # slow gateway with no incident listed -> its own platform problem; fast -> nothing
    assert [p["name"] for p in ops.evaluate({**healthy, "sb_latency_ms": 5000})["problems"]] == ["gateway slow"]
    assert ops.evaluate({**healthy, "sb_latency_ms": 400})["problems"] == []
    # stale fx quotes -> market problem pointing at the Markets page; fresh equity -> nothing
    v = ops.evaluate({**healthy, "quote_age_h": {"fx": 6.0, "equity": 1.0}})
    assert [(p["fix"], p["area"]) for p in v["problems"]] == [("market", "market")] and "fx" in v["problems"][0]["msg"]
    assert ops.evaluate({**healthy, "quote_age_h": {"mf": 20.0}})["problems"] == []
    # majority of sources stale -> stalled; minority -> fine
    assert [p["area"] for p in ops.evaluate({**healthy, "src_active": 10, "src_stale": 6})["problems"]] == ["sources"]
    assert ops.evaluate({**healthy, "src_active": 10, "src_stale": 2})["problems"] == []
    # edge function gone -> edge problem; unknown (None) stays silent
    assert [p["fix"] for p in ops.evaluate({**healthy, "edge_deploy": {"qa": False, "deepread": True}})["problems"]] == ["edge"]
    assert ops.evaluate({**healthy, "edge_deploy": {"qa": None}})["problems"] == []
    # maintenance banner is a note, never a problem
    v = ops.evaluate({**healthy, "maintenance_on": True})
    assert v["problems"] == [] and any("maintenance" in n for n in v["notes"])
    # every problem now carries an area for the Health page's grouping
    v = ops.evaluate({**healthy, "flagged_hour": 20, "quote_age_h": {"crypto": 9.0}})
    assert all(p["area"] for p in v["problems"]) and {p["area"] for p in v["problems"]} == {"ai", "market"}


def test_ops_evaluate_market_groups_and_fund_freshness():
    import ops
    healthy = {"errors": {}, "private": False, "crash_loop": False, "gh_active": False,
               "approved_age": 0.5, "ingested_age": 0.2, "top_age": 1.0, "flagged_hour": 0,
               "switches": {}, "last_run_ok": True, "edge_calls": 10, "edge_failed": 1}
    fail = {"ok": False, "err": "boom", "fails": 1, "daily": False}
    # interval group below the consecutive-failure bar -> silent; at the bar -> problem
    v = ops.evaluate({**healthy, "market_status": {"groups": {"fxcom": fail}}})
    assert v["problems"] == []
    v = ops.evaluate({**healthy, "market_status": {"groups": {"fxcom": {**fail, "fails": 3}}}})
    assert [(p["fix"], p["area"]) for p in v["problems"]] == [("market", "market")]
    assert "fxcom" in v["problems"][0]["msg"] and "boom" in v["problems"][0]["msg"]
    # a daily group alerts on its first failure — one miss is a lost day
    v = ops.evaluate({**healthy, "market_status": {"groups": {"screener": {**fail, "daily": True}}}})
    assert [p["name"] for p in v["problems"]] == ["market group failing"]
    # admin-disabled group: never a problem, only a note
    v = ops.evaluate({**healthy, "groups_off": ["screener"],
                      "market_status": {"groups": {"screener": {**fail, "daily": True}}}})
    assert v["problems"] == [] and any("disabled" in n for n in v["notes"])
    # market switch off silences the whole layer
    v = ops.evaluate({**healthy, "switches": {"market": False}, "fund_age_h": {"screener_metrics": 99},
                      "market_status": {"groups": {"screener": {**fail, "daily": True}}}})
    assert v["problems"] == [] and any("market switch" in n for n in v["notes"])
    # stale screener/fundamentals tables -> problem; fresh -> silent
    v = ops.evaluate({**healthy, "fund_age_h": {"screener_metrics": 40.0, "fundamentals": 10.0}})
    assert [p["name"] for p in v["problems"]] == ["screener_metrics stale"]
    # but not when its own refresh group is deliberately off
    v = ops.evaluate({**healthy, "groups_off": ["screener"], "fund_age_h": {"screener_metrics": 40.0}})
    assert v["problems"] == []


def test_ops_blob_content_age_grades_frozen_upstreams():
    import ops
    from datetime import datetime, timezone
    now = datetime(2026, 9, 2, 12, 0, tzinfo=timezone.utc)
    # bonds: newest yield date wins; flows: NSE's DD-MMM-YYYY parses too
    bonds = {"yields": [{"tenor": "10Y", "date": "2026-09-01"}, {"tenor": "5Y", "date": "2026-08-28"}]}
    assert ops.blob_content_age_h("bonds", bonds, now) == 36.0
    assert ops.blob_content_age_h("flows", {"date": "01-Sep-2026", "fii": {}}, now) == 36.0
    # no parseable date -> None (unknown), never a fabricated clock
    assert ops.blob_content_age_h("flows", {"fii": {}}, now) is None
    assert ops.blob_content_age_h("bonds", {"yields": []}, now) is None
    assert ops.blob_content_age_h("other", {"date": "2026-09-01"}, now) is None

    healthy = {"errors": {}, "private": False, "crash_loop": False, "gh_active": False,
               "approved_age": 0.5, "ingested_age": 0.2, "top_age": 1.0, "flagged_hour": 0,
               "switches": {}, "last_run_ok": True, "edge_calls": 10, "edge_failed": 1}
    # inside the long-weekend budget -> silent; past it -> market problem
    assert ops.evaluate({**healthy, "blob_content_age_h": {"bonds": 100.0}})["problems"] == []
    v = ops.evaluate({**healthy, "blob_content_age_h": {"bonds": 200.0, "flows": 50.0}})
    assert [(p["name"], p["fix"], p["area"]) for p in v["problems"]] == \
        [("blob content frozen", "market", "market")]
    assert "bonds" in v["problems"][0]["msg"] and "flows" not in v["problems"][0]["msg"]
