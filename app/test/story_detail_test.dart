// StoryCard renders from a Story without network; the detail screen's fetch
// needs Supabase, so test the render path that both feed and deep-link share.
import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart' show StoryCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Story _story(Map<String, dynamic> overrides) => Story.fromJson({
      'id': 1,
      'hook': 'Oil just got scary',
      'headline': 'Crude spikes 8% after supply shock',
      'summary': 'Supply shock details.',
      'impact_direction': 'negative',
      'impact_strength': 3,
      'impact_horizon': 'short_term',
      'impact_score': 9,
      'severity_level': 1,
      'confidence': 'high',
      'source_name': 'ET',
      'source_url': 'https://e.co',
      'category': 'Commodities',
      'sectors': ['Energy'],
      ...overrides,
    });

void main() {
  testWidgets('renders hook, headline and impact', (tester) async {
    await tester.pumpWidget(
        ProviderScope(
            child: MaterialApp(
                home: Scaffold(body: StoryCard(story: _story(const {}))))));
    expect(find.text('Oil just got scary'), findsOneWidget);
    expect(find.textContaining('IMPACT 9/10'), findsOneWidget);
  });

  testWidgets('survives a story with nothing but the required fields',
      (tester) async {
    // Flagged and quota-deferred rows reach the app with null hook/summary/
    // score; a deep link must not crash on one.
    final bare = Story.fromJson({
      'id': 2,
      'headline': 'Bare headline',
      'source_name': 'RBI',
      'source_url': 'https://rbi.org.in',
      'sectors': null,
    });
    await tester.pumpWidget(
        ProviderScope(
            child: MaterialApp(home: Scaffold(body: StoryCard(story: bare)))));
    expect(find.text('Bare headline'), findsOneWidget);
    expect(find.textContaining('IMPACT –/10'), findsOneWidget);
  });
}
