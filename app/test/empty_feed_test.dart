import 'package:finswipe/models.dart';
import 'package:finswipe/screens/feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an empty feed offers a Refresh button, not a dead end',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storiesProvider.overrideWith((_) async => <Story>[]),
      ],
      child: const MaterialApp(home: Scaffold(body: FeedScreen())),
    ));
    await tester.pump(); // resolve the future
    await tester.pump();
    expect(find.text('No stories yet — check back soon'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Refresh'), findsOneWidget);
  });
}
