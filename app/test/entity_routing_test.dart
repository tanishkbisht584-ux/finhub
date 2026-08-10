import 'package:flutter_test/flutter_test.dart';
import 'package:finswipe/screens/ask.dart';

void main() {
  test('questions never route to a stock page', () {
    for (final q in [
      'Why is the NIFTY falling today?',
      'what did RBI decide',
      'Should I buy Reliance shares right now',
      'how is tata motors doing',
      'is the market open tomorrow',
    ]) {
      expect(looksLikeQuestion(q), isTrue, reason: q);
    }
  });

  test('bare entity queries are candidates for routing', () {
    for (final q in ['Tata Motors', 'RELIANCE', 'hdfc bank', 'M&M']) {
      expect(looksLikeQuestion(q), isFalse, reason: q);
    }
  });
}
