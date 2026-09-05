import 'package:finswipe/sessions.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, SessionState> _at(DateTime utc) =>
    {for (final s in sessionStates(utc)) s.name: s};

void main() {
  test('a Wednesday mid-morning IST: NSE and Tokyo open, West closed, HK at lunch', () {
    final s = _at(DateTime.utc(2026, 9, 9, 4, 30)); // 10:00 IST
    expect(s['NSE']!.open, isTrue);
    expect(s['NSE']!.note, 'open · closes 15:30 IST');
    expect(s['LONDON']!.open, isFalse);
    expect(s['LONDON']!.note, 'opens 12:30 IST'); // 08:00 BST
    expect(s['NEW YORK']!.open, isFalse);
    expect(s['NEW YORK']!.note, 'opens 19:00 IST'); // 09:30 EDT
    expect(s['TOKYO']!.open, isTrue);
    expect(s['TOKYO']!.note, 'open · closes 12:00 IST'); // 15:30 JST
    expect(s['HONG KONG']!.open, isTrue);
    expect(s['HONG KONG']!.note, 'lunch · reopens 10:30 IST'); // 13:00 HKT
  });

  test('a Saturday: everything closed, next open is Monday', () {
    final s = _at(DateTime.utc(2026, 9, 12, 4, 30));
    expect(s.values.every((v) => !v.open), isTrue);
    expect(s['NSE']!.note, 'opens Mon 09:15 IST');
    expect(s['NEW YORK']!.note, 'opens Mon 19:00 IST');
  });

  test('London follows BST: same clock time is closed in GMT, open in BST', () {
    // 27 Mar 2026 (Fri) is GMT: 07:30 local, bell at 08:00. 30 Mar (Mon) is BST: 08:30 local.
    expect(_at(DateTime.utc(2026, 3, 27, 7, 30))['LONDON']!.open, isFalse);
    expect(_at(DateTime.utc(2026, 3, 30, 7, 30))['LONDON']!.open, isTrue);
    // New York: EDT from 8 Mar 2026; 6 Mar 15:00Z is 10:00 EST (open), 9 Mar 13:00Z is 09:00 EDT (closed)
    expect(_at(DateTime.utc(2026, 3, 6, 15, 0))['NEW YORK']!.open, isTrue);
    expect(_at(DateTime.utc(2026, 3, 9, 13, 0))['NEW YORK']!.open, isFalse);
    expect(_at(DateTime.utc(2026, 3, 9, 14, 0))['NEW YORK']!.open, isTrue);
  });
}
