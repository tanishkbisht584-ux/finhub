# M7: Alerts Live — FCM Receive, Deep-links, L1 Voice, Personalized Sends

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alerts actually arrive on phones: topic pushes received with deep-links and L1 voice, plus spec §7 personalized alerts (impact ≥ 6 touching a followed company/sector/category, 5/day/user) — the payoff for M6's follows data.

**Architecture:** Send side already exists (`send_fcm`, FCM v1, service account from `FIREBASE_SERVICE_ACCOUNT_JSON`) — it only needs the secret in the workflow env. The app gains firebase_messaging (topic `alerts`), a `navigatorKey` deep-link to `StoryDetailScreen`, foreground L1 voice via flutter_tts, and writes its FCM token to `profiles.fcm_token`. A new `personal_alert_engine` in run.py joins un-alerted impact≥6 stories against `follows` (companies via `story_companies`, sectors via `stories.sectors`, categories via `stories.category`) and sends direct-to-token. Per-user state (daily count + story-id cursor) lives in `profiles.alert_settings` jsonb — the events table's CHECK constraint forbids new event types and DDL access is gone with the revoked `sbp_` token.

**Tech Stack:** Existing pipeline (google-auth already pinned), Flutter `firebase_core` + `firebase_messaging` + `flutter_tts`, Gradle Kotlin DSL (`.kts` — the M5 plan's Groovy instructions do NOT apply), `app/android/app/google-services.json` (already in place, committable — public identifiers only).

## Global Constraints

- ₹0 stack; the service-account JSON lives ONLY in the GitHub secret `FIREBASE_SERVICE_ACCOUNT_JSON` (user is adding it; pipeline no-ops with a print until it lands — that's existing behavior, keep it).
- Spec §7 verbatim: personalized = impact ≥ 6 touching a followed stock/sector, max 5/day per user; quiet hours 22:00–07:00 IST pierced only by impact ≥ 9; caps limit pushes, never publication. IST from the pipeline's existing `IST` constant, never host clock.
- No DDL, no new event types (`events.type` CHECK), no RLS changes. Per-user alert state rides in `profiles.alert_settings` jsonb via service-key PATCH.
- A story that was globally alerted (`alerted_at` set) is never also sent personalized — no double buzz. Personalized sends do NOT set `alerted_at` (that would eat the global 5/day cap).
- App version bumps to `0.10.0+19`; APK to `C:\Users\Tanis\Desktop\finswipe-v0.10.0.apk`; `--dart-define=APP_VERSION=0.10.0`.
- Firebase init failure (no Play Services, dev build) must never break the app — wrap in try/catch, features degrade silently (M5 plan's stance).
- Local end-to-end test: the service-account JSON is at scratchpad `fbsa.json` (session-local); `FIREBASE_SERVICE_ACCOUNT_JSON=$(cat ...) python -c "from run import send_fcm; ..."` fires a real push — use it to verify receive before claiming done.

---

### Task 1: Pipeline — secret into workflow + personalized alert engine

**Files:**
- Modify: `.github/workflows/pipeline.yml` (env gains `FIREBASE_SERVICE_ACCOUNT_JSON`)
- Modify: `pipeline/run.py` (add `send_fcm_token`, `personal_alert_engine`, call it from `main()` after `alert_engine`)
- Test: `pipeline/test_pipeline.py` (gate/matching logic, no network)

**Interfaces:**
- Consumes: `send_fcm`'s credential pattern (run.py:439-463), `sb()`, `IST`, `in_quiet_hours(now)` (run.py:356), `follows` rows `{user_id, target_type: company|sector|category, target_id}` (company target_id = numeric string), `story_companies`, `profiles.fcm_token`, `profiles.alert_settings`.
- Produces: `personal_matches(story, follows_by_user, companies_of) -> set[user_id]` (pure, testable); `personal_alert_engine(now=None) -> int` called in `main()`; per-user jsonb state `alert_settings.pa = {"d": "<YYYY-MM-DD IST>", "n": <sent today>, "cur": <max story id processed>}`.

- [ ] **Step 1: Add the secret to `.github/workflows/pipeline.yml`** — in the `env:` block of the run step, after `OPENROUTER_API_KEY`:

```yaml
          # turns send_fcm from a printed no-op into real pushes (M7)
          FIREBASE_SERVICE_ACCOUNT_JSON: ${{ secrets.FIREBASE_SERVICE_ACCOUNT_JSON }}
```

- [ ] **Step 2: Write the failing tests** (append to `pipeline/test_pipeline.py`):

```python
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
```

- [ ] **Step 3: Run — expect FAIL** (`cd pipeline && python -m pytest test_pipeline.py -q`)

- [ ] **Step 4: Implement in `pipeline/run.py`** (below `send_fcm`):

```python
def send_fcm_token(token, hook, headline, story_id, score):
    """Direct-to-device variant of send_fcm for personalized alerts."""
    import json as _json
    sa_json = os.environ.get("FIREBASE_SERVICE_ACCOUNT_JSON")
    if not sa_json:
        print(f"PERSONAL ALERT (FCM not configured): {hook}")
        return False
    from google.oauth2 import service_account
    import google.auth.transport.requests
    creds = service_account.Credentials.from_service_account_info(
        _json.loads(sa_json), scopes=["https://www.googleapis.com/auth/firebase.messaging"])
    creds.refresh(google.auth.transport.requests.Request())
    r = requests.post(
        f"https://fcm.googleapis.com/v1/projects/{creds.project_id}/messages:send",
        headers={"Authorization": f"Bearer {creds.token}"},
        json={"message": {"token": token,
                          "notification": {"title": hook, "body": headline},
                          "data": {"story_id": str(story_id), "hook": hook,
                                   "impact_score": str(score)}}},
        timeout=30)
    # 404/400 = dead token (app uninstalled): clear it so we stop trying
    return r.ok


def personal_matches(story, follows_by_user, companies_of):
    """Users whose follows this story touches. follows_by_user: {user_id:
    [(target_type, target_id)]}; companies_of(story_id) -> set of company-id
    strings. Pure so the matching rules are testable without a database."""
    cats = {story.get("category")} - {None}
    secs = set(story.get("sectors") or [])
    comps = None  # lazy: most stories touch no follower at all
    hit = set()
    for uid, follows in follows_by_user.items():
        for ttype, tid in follows:
            if ttype == "category" and tid in cats:
                hit.add(uid); break
            if ttype == "sector" and tid in secs:
                hit.add(uid); break
            if ttype == "company":
                if comps is None:
                    comps = companies_of(story["id"])
                if tid in comps:
                    hit.add(uid); break
    return hit


PERSONAL_CAP_PER_DAY = 5     # spec §7
PERSONAL_MIN_SCORE = 6


def personal_alert_engine(now=None):
    """Spec §7 personalized alerts: impact >= 6 touching a followed
    company/sector/category -> direct push, max 5/day/user, quiet hours
    pierced only by >= 9. Per-user state in profiles.alert_settings.pa
    (ponytail: jsonb counter+cursor; a real sends table when DDL access
    returns / beta grows). Globally-alerted stories are excluded — the topic
    push already reached everyone."""
    now = now or datetime.now(timezone.utc)
    profiles = sb("GET", "profiles?select=id,fcm_token,alert_settings"
                         "&fcm_token=not.is.null")
    profiles = [p for p in profiles
                if (p.get("alert_settings") or {}).get("personalized", True)]
    if not profiles:
        return 0
    all_follows = sb("GET", "follows?select=user_id,target_type,target_id")
    follows_by_user = {}
    for f in all_follows:
        follows_by_user.setdefault(f["user_id"], []).append(
            (f["target_type"], f["target_id"]))
    if not follows_by_user:
        return 0

    today = now.astimezone(IST).strftime("%Y-%m-%d")
    cutoff = iso(now - timedelta(hours=6))
    stories = sb("GET", "stories?select=id,hook,headline,impact_score,category,sectors"
                        f"&created_at=gte.{cutoff}&impact_score=gte.{PERSONAL_MIN_SCORE}"
                        "&alerted_at=is.null&status=in.(pending,approved)"
                        "&order=id.asc")
    if not stories:
        return 0

    link_cache = {}
    def companies_of(sid):
        if sid not in link_cache:
            link_cache[sid] = {str(r["company_id"]) for r in
                               sb("GET", f"story_companies?select=company_id&story_id=eq.{sid}")}
        return link_cache[sid]

    sent = 0
    quiet = in_quiet_hours(now)
    for p in profiles:
        uid = p["id"]
        if uid not in follows_by_user:
            continue
        settings = p.get("alert_settings") or {}
        pa = settings.get("pa") or {}
        n_today = pa.get("n", 0) if pa.get("d") == today else 0
        cursor = pa.get("cur", 0)
        new_cursor = cursor
        for s in stories:
            if s["id"] <= cursor:
                continue
            new_cursor = max(new_cursor, s["id"])
            if n_today >= PERSONAL_CAP_PER_DAY:
                continue  # cursor still advances: stale news never buzzes later
            if quiet and (s["impact_score"] or 0) < 9:
                continue
            if uid not in personal_matches(s, {uid: follows_by_user[uid]}, companies_of):
                continue
            if send_fcm_token(p["fcm_token"], s["hook"] or s["headline"],
                              s["headline"], s["id"], s["impact_score"]):
                n_today += 1
                sent += 1
        if new_cursor != cursor or n_today != (pa.get("n", 0) if pa.get("d") == today else 0):
            sb("PATCH", f"profiles?id=eq.{uid}",
               json={"alert_settings": {**settings,
                     "pa": {"d": today, "n": n_today, "cur": new_cursor}}})
    return sent
```

In `main()`, after `alerted = alert_engine(...)`, add:

```python
    personal = personal_alert_engine()
```

and extend the `done:` print with `f", {personal} personal alerts"` appended to the alerts segment.

- [ ] **Step 5: Run tests — expect PASS** (`python -m pytest test_pipeline.py -q`)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/pipeline.yml pipeline/run.py pipeline/test_pipeline.py
git commit -m "M7: personalized alerts — follows x impact>=6, 5/day/user, jsonb state"
```

---

### Task 2: App — FCM receive, deep-link, L1 voice, token save

**Files:**
- Modify: `app/pubspec.yaml` (deps), `app/android/settings.gradle.kts` (plugin), `app/android/app/build.gradle.kts` (plugin)
- Modify: `app/lib/main.dart`
- Commit (already present): `app/android/app/google-services.json`

**Interfaces:**
- Consumes: `StoryDetailScreen({required int storyId})`; `send_fcm` data payload `{story_id, hook, impact_score}`; `profiles.fcm_token`, `profiles.alert_settings.voice_l1`.
- Produces: `navigatorKey` on the MaterialApp; topic `alerts` subscription; notification tap → StoryDetailScreen + `alert_open` event; foreground impact≥9 speaks hook when `voice_l1` ≠ false; FCM token upserted into the user's profile on auth.

- [ ] **Step 1: Deps** — `cd app && flutter pub add firebase_core firebase_messaging flutter_tts`

- [ ] **Step 2: Gradle (Kotlin DSL — NOT the M5 plan's Groovy)** — in `app/android/settings.gradle.kts` `plugins { }` block add:

```kotlin
    id("com.google.gms.google-services") version "4.4.2" apply false
```

and in `app/android/app/build.gradle.kts` `plugins { }` block add:

```kotlin
    id("com.google.gms.google-services")
```

- [ ] **Step 3: Wire `app/lib/main.dart`** — new imports:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'screens/story_detail.dart';
```

Top-level, above `main()`:

```dart
final navigatorKey = GlobalKey<NavigatorState>();

void _openStory(RemoteMessage m) {
  final id = int.tryParse(m.data['story_id'] ?? '');
  if (id == null) return;
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid != null) {
    Supabase.instance.client.from('events')
        .insert({'user_id': uid, 'story_id': id, 'type': 'alert_open'})
        .then((_) {}, onError: (_) {});
  }
  navigatorKey.currentState
      ?.push(MaterialPageRoute(builder: (_) => StoryDetailScreen(storyId: id)));
}

/// L1 voice (spec §7): a foreground push with impact >= 9 speaks the hook —
/// ~3 s of on-device TTS, gated on the profile toggle, on by default.
Future<void> _maybeSpeak(RemoteMessage m) async {
  final score = int.tryParse(m.data['impact_score'] ?? '') ?? 0;
  final hook = m.data['hook'] ?? '';
  if (score < 9 || hook.isEmpty) return;
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid != null) {
    try {
      final row = await Supabase.instance.client.from('profiles')
          .select('alert_settings').eq('id', uid).maybeSingle();
      if (row?['alert_settings']?['voice_l1'] == false) return;
    } catch (_) {}  // can't read the toggle -> default on (it's L1-rare)
  }
  await FlutterTts().speak(hook);
}

/// The pipeline needs the device token to send personalized alerts.
Future<void> _saveFcmToken() async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await Supabase.instance.client.from('profiles')
          .update({'fcm_token': token}).eq('id', uid);
    }
  } catch (_) {}  // no Firebase on this build/device — personalized just stays off
}
```

`main()` becomes:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  try {
    await Firebase.initializeApp();
    await FirebaseMessaging.instance.requestPermission();
    await FirebaseMessaging.instance.subscribeToTopic('alerts');
    FirebaseMessaging.onMessageOpenedApp.listen(_openStory);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _openStory(initial);
    FirebaseMessaging.onMessage.listen(_maybeSpeak);
    FirebaseMessaging.instance.onTokenRefresh.listen((_) => _saveFcmToken());
  } catch (_) {
    // no google-services / Play Services: app works, alerts don't arrive
  }
  runApp(const ProviderScope(child: FinSwipeApp()));
}
```

In `FinSwipeApp.build`, add `navigatorKey: navigatorKey,` to the `MaterialApp`. In `AuthGate`'s builder, where a signed-in session is established (next to `_ensureProfile(session.user)`), add `_saveFcmToken();`.

- [ ] **Step 4: Run the full suite — expect PASS** (`cd app && flutter test`; existing tests must not regress — Firebase is never touched in test builds because init is inside try/catch and tests don't call `main()`).

- [ ] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/android/ app/lib/main.dart
git commit -m "M7: alerts arrive — FCM receive, deep-link, L1 voice, token save"
```

---

### Task 3: Profile — Alerts toggles

**Files:**
- Modify: `app/lib/screens/profile.dart`
- Test: `app/test/alert_settings_test.dart`

**Interfaces:**
- Consumes: `profiles.alert_settings` jsonb (`{"personalized": true, "voice_l1": true}` defaults from 003).
- Produces: two SwitchListTiles in Profile — "Read the biggest stories aloud" (`voice_l1`), "Alerts for my watchlist" (`personalized`) — optimistic toggle, PATCH to profiles, revert on failure. Merge-write: always spread the existing map so the pipeline's `pa` state survives (`{...settings, 'voice_l1': v}`).

- [ ] **Step 1: Failing test** — a pure helper `mergedAlertSettings(Map current, String key, bool value)` exported from profile.dart:

```dart
// app/test/alert_settings_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/profile.dart';

void main() {
  test('toggle write preserves unrelated keys (pipeline pa state)', () {
    final merged = mergedAlertSettings(
        {'personalized': true, 'voice_l1': true, 'pa': {'d': '2026-08-10', 'n': 2}},
        'voice_l1', false);
    expect(merged['voice_l1'], false);
    expect(merged['pa'], {'d': '2026-08-10', 'n': 2});
    expect(merged['personalized'], true);
  });
}
```

- [ ] **Step 2: Run — FAIL; implement** — in profile.dart add the helper + an `_AlertSettings` StatefulWidget section: loads `alert_settings` once, two `SwitchListTile`s (defaults true when key absent), optimistic setState, `update({'alert_settings': mergedAlertSettings(current, key, v)})`, revert on catch. Match the screen's existing visual style (mono/serif, dark theme constants).

- [ ] **Step 3: Full suite PASS, commit**

```bash
git add app/lib/screens/profile.dart app/test/alert_settings_test.dart
git commit -m "M7: alert toggles in Profile — voice + watchlist alerts"
```

---

### Task 4: Release v0.10.0 + live end-to-end

**Files:** `app/pubspec.yaml` (version `0.10.0+19`)

- [ ] **Step 1:** Bump version; run both suites (pipeline + app) — all green or stop.
- [ ] **Step 2:** Build APK with the same dart-defines as v0.9.0 but `APP_VERSION=0.10.0`; copy to `C:\Users\Tanis\Desktop\finswipe-v0.10.0.apk`.
- [ ] **Step 3:** Commit + tag `v0.10.0`.
- [ ] **Step 4 [HUMAN]:** Install the APK, open it once (grants notification permission, saves token).
- [ ] **Step 5:** Live test from the controller session (NOT CI): with the scratchpad `fbsa.json` as `FIREBASE_SERVICE_ACCOUNT_JSON`, call `send_fcm("Test alert", "FinSwipe alert path test", <real recent story id>, 9)` — phone must show the notification; tapping opens the story card; if the app is foreground it speaks the hook. Then verify `profiles.fcm_token` is non-null for Tanis's user.

## Out of scope (explicit)

- Grace-window (5-min) redesign of the global gate, admin manual-send UI: exist/M3 scope, untouched.
- Per-user alert history screen; notification channels/sounds customization.
- A real `personal_alerts` table — blocked on DDL access; the jsonb state is marked `ponytail:` in code.

## Self-review notes

- Spec §7 coverage: receive+deep-link+voice (Task 2), personalized ≥6 follows 5/day quiet-hours (Task 1), toggles (Task 3), §10 tests per task.
- Field-name contracts: FCM data keys `{story_id, hook, impact_score}` identical in `send_fcm`, `send_fcm_token`, `_openStory`, `_maybeSpeak`. jsonb key `pa` written only via spread-merges on both sides (Task 1 engine, Task 3 helper).
- No double-buzz: personalized excludes `alerted_at is not null`; personalized never sets `alerted_at`.
