// The strip must never degrade a card: no media -> no gap, dead URL -> silent
// collapse (widget-test HTTP fails outright with a DNS/connection error, not
// a 400 -- which conveniently IS the dead-URL case), video -> tappable with a
// play badge while the thumbnail lives.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _s(Map<String, dynamic> overrides) => Story.fromJson({
      'id': 1,
      'headline': 'RBI holds repo rate',
      'hook': 'RBI stands still',
      'summary': 'Rates unchanged.',
      'impact_score': 7,
      'source_name': 'RBI Press',
      'source_url': 'https://rbi.org.in/x',
      'sectors': const [],
      ...overrides,
    });

Widget _app(Story s) => ProviderScope(
    child: MaterialApp(home: Scaffold(body: StoryCard(story: s))));

// A 1x1 transparent PNG -- just enough for Image.network to decode.
final Uint8List _onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
    'AAYAAjCB0C8AAAAASUVORK5CYII=');

/// Minimal dart:io HttpClient fake that answers every request with the
/// pixel above. Wired in via [debugNetworkImageHttpClientProvider] (Flutter's
/// own test hook for NetworkImage, re-checked on every load) rather than
/// [HttpOverrides.runZoned] -- NetworkImage's real client is a lazily-created
/// `static final`, so whichever HttpOverrides is active on the *first* image
/// load in the whole test process wins for every test after it; the debug
/// provider has no such staleness.
///
/// Uses Dart's noSuchMethod-forwarding exception (a class that overrides
/// noSuchMethod need not implement every interface member) to stay small
/// instead of stubbing the whole dart:io http surface.
class _FakeImageHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeImageHttpClientRequest();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeImageHttpClientRequest();

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImageHttpClientRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeImageHttpClientResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImageHttpClientResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  int get contentLength => _onePixelPng.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return Stream<List<int>>.fromIterable(<List<int>>[_onePixelPng]).listen(
        onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Installs the fake client for the duration of one test. Reset explicitly at
/// the end of the test body, not via addTearDown -- TestWidgetsFlutterBinding
/// asserts painting debug vars are back to null the instant the test body
/// returns, which is before addTearDown callbacks would otherwise run.
void _withMockedImageTransport() {
  debugNetworkImageHttpClientProvider = () => _FakeImageHttpClient();
}

/// Hero images only: the outlet credit's favicon is an Image too (OutletMark).
final heroImage = find.byWidgetPredicate(
    (w) => w is Image && w.key != const ValueKey('outlet-favicon'));

void main() {
  test('Story parses image_url and video_url', () {
    final s = _s({'image_url': 'https://cdn.et.com/a.jpg',
                  'video_url': 'https://www.youtube.com/watch?v=abc'});
    expect(s.imageUrl, 'https://cdn.et.com/a.jpg');
    expect(s.videoUrl, 'https://www.youtube.com/watch?v=abc');
    expect(_s(const {}).imageUrl, isNull);
  });

  testWidgets('no media, no strip — card is exactly today\'s card',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_s(const {})));
    expect(heroImage, findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    // The hook takes the photo's slot — shown once, in the hero.
    expect(find.text('RBI stands still'), findsOneWidget);
  });

  testWidgets('dead image URL collapses the strip silently', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_s({'image_url': 'https://x.invalid/a.jpg'})));
    await tester.pumpAndSettle();
    // Test HTTP fails outright (DNS/connection error) for every request:
    // the errorBuilder path. The hero drops to its compact face and the hook
    // still renders exactly once (below the hero, image-card layout).
    expect(find.byIcon(Icons.broken_image), findsNothing);
    expect(find.text('RBI stands still'), findsOneWidget);
  });

  testWidgets(
      'image + video render: AspectRatio, play icon, tappable InkWell',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    _withMockedImageTransport();

    await tester.pumpWidget(_app(_s({
      'image_url': 'https://cdn.et.com/a.jpg',
      'video_url': 'https://www.youtube.com/watch?v=abc',
    })));
    await tester.pumpAndSettle();

    expect(heroImage, findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
        find.ancestor(
            of: find.byIcon(Icons.play_arrow_rounded),
            matching: find.byType(InkWell)),
        findsOneWidget);
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets(
      'story change resets a dead strip (State reuse via PageView.builder)',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // First story: dead image (real, unmocked transport -> DNS/connection
    // failure) -> strip collapses and _dead latches true.
    await tester.pumpWidget(_app(_s({'image_url': 'https://x.invalid/a.jpg'})));
    await tester.pumpAndSettle();
    expect(heroImage, findsNothing);

    // Same widget position, no keys -> Flutter reuses the State, exactly
    // like PageView.builder swiping to the next card. A good image_url on
    // the new story must still render, not stay hidden by the old _dead.
    _withMockedImageTransport();
    await tester.pumpWidget(_app(_s({'image_url': 'https://cdn.et.com/b.jpg'})));
    await tester.pumpAndSettle();
    expect(heroImage, findsOneWidget);
    debugNetworkImageHttpClientProvider = null;
  });
}
