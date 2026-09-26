// 033: every term the app can ask the server to define must be in the qa
// function's DEFINE_TERMS whitelist — 33 terms silently 400'd for six days
// before this test existed. Reads the TypeScript source, no network.
import 'dart:io';

import 'package:finflick/models.dart';
import 'package:finflick/screens/screens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('glossaryTerms and every metric term exist in qa DEFINE_TERMS', () {
    final src = File('../supabase/functions/qa/index.ts').readAsStringSync();
    final m = RegExp(r'const DEFINE_TERMS = new Set\(\[(.*?)\]\);', dotAll: true)
        .firstMatch(src)!;
    final server = RegExp(r'"([^"]+)"')
        .allMatches(m.group(1)!)
        .map((x) => x.group(1)!)
        .toSet();
    final missing = <String>{
      for (final t in glossaryTerms)
        if (!server.contains(t)) t,
      for (final d in metricDefs)
        if (!server.contains(d.term)) d.term,
    };
    expect(missing, isEmpty, reason: 'add to DEFINE_TERMS and redeploy qa');
  });
}
