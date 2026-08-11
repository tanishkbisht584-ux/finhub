"""Unit tests per spec §10: dedupe hashing, clustering, schema validation. No network."""
import io
from datetime import datetime, timedelta, timezone

import pytest

from ai import validate
from run import assign_cluster, canonical_url, title_tokens, url_hash
from seed.companies_seed import display_name


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


# ---------- M8: video matching ----------

def test_youtube_sources_never_enter_the_story_path():
    """A youtube source must be split out before the FETCHERS loop — its items
    are media candidates, and fetch_items would happily turn them into stories."""
    from run import split_sources
    sources = [{"type": "rss"}, {"type": "youtube"}, {"type": "nse"}]
    story_sources, yt_sources = split_sources(sources)
    assert {s["type"] for s in story_sources} == {"rss", "nse"}
    assert [s["type"] for s in yt_sources] == ["youtube"]


def test_video_candidates_gate_on_cluster_and_recency():
    from run import video_candidates, title_tokens
    now = datetime.now(timezone.utc)
    recent = [("c1", title_tokens("RBI cuts repo rate by 25 bps"))]
    stories = {"c1": {"id": 7, "headline": "RBI cuts repo rate by 25 bps",
                      "published_at": now.isoformat(), "video_url": None,
                      "image_url": None}}
    vids = [
        # same cluster, fresh -> candidate
        {"title": "RBI cuts repo rate 25 bps: what it means", "video_id": "a1",
         "published_at": now.isoformat()},
        # no cluster match -> discarded, no AI spent
        {"title": "Closing Bell: Sensex today", "video_id": "b2",
         "published_at": now.isoformat()},
        # matches but 13h stale -> discarded
        {"title": "RBI cuts repo rate by 25 bps analysis", "video_id": "c3",
         "published_at": (now - timedelta(hours=13)).isoformat()},
    ]
    cands = video_candidates(vids, recent, stories)
    assert [c["video_id"] for c in cands] == ["a1"]
    assert cands[0]["story_id"] == 7


def test_match_videos_patches_only_the_confirmed_story(monkeypatch):
    """match_videos end-to-end: a matching + a non-matching video, one story
    without an image. Asserts the one PATCH that actually writes stories."""
    import run

    now = datetime.now(timezone.utc)
    story = {"id": 42, "cluster_id": "c1", "headline": "RBI cuts repo rate by 25 bps",
             "published_at": now.isoformat(), "image_url": None, "video_url": None}
    recent = [("c1", run.title_tokens(story["headline"]))]

    calls = []
    def fake_sb(method, path, **kwargs):
        calls.append((method, path, kwargs.get("json")))
        if method == "GET" and path.startswith("stories?"):
            return [story]
        return None
    monkeypatch.setattr(run, "sb", fake_sb)
    monkeypatch.setattr(run, "fetch_videos", lambda source: [
        {"title": "RBI cuts repo rate 25 bps: what it means", "video_id": "a1",
         "published_at": now.isoformat()},          # matches the story's cluster
        {"title": "Closing Bell: Sensex today", "video_id": "b2",
         "published_at": now.isoformat()},           # no cluster match -> gated out
    ])
    stub_video_match = lambda pairs: [0]  # confirms the sole surviving candidate

    attached = run.match_videos([{"id": 99, "name": "Test Video", "feed_url": "http://x"}],
                                 recent, {}, stub_video_match)

    assert attached == 1
    story_patches = [c for c in calls if c[0] == "PATCH" and c[1] == "stories?id=eq.42"]
    assert len(story_patches) == 1
    patch = story_patches[0][2]
    assert patch["video_url"] == "https://www.youtube.com/watch?v=a1"
    assert patch["image_url"] == "https://img.youtube.com/vi/a1/hqdefault.jpg"


def test_image_seen_counts_filters_status_and_memoizes(monkeypatch):
    """Only approved/pending rows count toward house-image detection (a
    rejected/duplicate row never showed anyone an image), and a resident
    poller calling this every 45s must not re-scan every time -- only after
    the 10-minute cache window."""
    import run
    run._seen_images_cache = {"at": 0.0, "counts": {}}
    calls = []

    def fake_sb(method, path, **kw):
        calls.append(path)
        assert "status=in.(approved,pending)" in path
        assert "order=created_at.asc" in path
        return [{"image_url": "https://x.com/a.jpg"}, {"image_url": "https://x.com/a.jpg"}]

    monkeypatch.setattr(run, "sb", fake_sb)
    first = run.image_seen_counts()
    assert first == {"https://x.com/a.jpg": 2}
    assert len(calls) == 1

    # second call within the cache window: no new query, same dict object
    second = run.image_seen_counts()
    assert len(calls) == 1
    assert second is first

    # a mutation by a caller (og fallback / match_videos) survives the cache
    first["https://x.com/a.jpg"] += 1
    assert run.image_seen_counts()["https://x.com/a.jpg"] == 3


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
