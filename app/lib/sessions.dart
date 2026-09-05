/// Which exchanges are trading right now, told in IST. Pure: feed it a UTC
/// instant, get one state per venue. London and New York shift with DST by
/// the statutory rules (last Sunday of March/October; second Sunday of March
/// to first Sunday of November) - no tz database in the app.
/// ponytail: no exchange-holiday table; add when someone complains.
class SessionState {
  const SessionState(this.name, this.open, this.note);
  final String name;
  final bool open;
  final String note;
}

typedef _Venue = ({
  String name,
  int Function(DateTime utc) offsetMin, // local = utc + offset
  int open, // minutes since local midnight
  int close,
  (int, int)? lunch,
});

final _venues = <_Venue>[
  (name: 'NSE', offsetMin: (_) => 330, open: 9 * 60 + 15, close: 15 * 60 + 30, lunch: null),
  (name: 'LONDON', offsetMin: (u) => _ukOffsetH(u) * 60, open: 8 * 60, close: 16 * 60 + 30, lunch: null),
  (name: 'NEW YORK', offsetMin: (u) => _usOffsetH(u) * 60, open: 9 * 60 + 30, close: 16 * 60, lunch: null),
  (name: 'TOKYO', offsetMin: (_) => 540, open: 9 * 60, close: 15 * 60 + 30, lunch: (11 * 60 + 30, 12 * 60 + 30)),
  (name: 'HONG KONG', offsetMin: (_) => 480, open: 9 * 60 + 30, close: 16 * 60, lunch: (12 * 60, 13 * 60)),
];

const _dow = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// n-th Sunday of a month (1-based), or the last one when [n] is -1. UTC.
DateTime _sunday(int y, int m, int n) {
  if (n > 0) {
    final first = DateTime.utc(y, m, 1);
    return DateTime.utc(y, m, 1 + (7 - first.weekday) % 7 + 7 * (n - 1));
  }
  final last = DateTime.utc(y, m + 1, 0); // day 0 = last day of month m
  return last.subtract(Duration(days: last.weekday % 7));
}

int _ukOffsetH(DateTime u) {
  final s = _sunday(u.year, 3, -1).add(const Duration(hours: 1));
  final e = _sunday(u.year, 10, -1).add(const Duration(hours: 1));
  return !u.isBefore(s) && u.isBefore(e) ? 1 : 0;
}

int _usOffsetH(DateTime u) {
  final s = _sunday(u.year, 3, 2).add(const Duration(hours: 7)); // 02:00 EST
  final e = _sunday(u.year, 11, 1).add(const Duration(hours: 6)); // 02:00 EDT
  return !u.isBefore(s) && u.isBefore(e) ? -4 : -5;
}

/// Local calendar day + minutes-since-midnight -> "HH:MM" in IST.
String _ist(DateTime localDay, int mins, int offsetMin) {
  final t = DateTime.utc(localDay.year, localDay.month, localDay.day)
      .add(Duration(minutes: mins - offsetMin + 330));
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

SessionState _state(_Venue v, DateTime u) {
  final off = v.offsetMin(u);
  final local = u.add(Duration(minutes: off));
  final mins = local.hour * 60 + local.minute;
  final weekday = local.weekday <= 5;
  if (weekday && mins >= v.open && mins < v.close) {
    final l = v.lunch;
    if (l != null && mins >= l.$1 && mins < l.$2) {
      return SessionState(v.name, true, 'lunch · reopens ${_ist(local, l.$2, off)} IST');
    }
    return SessionState(v.name, true, 'open · closes ${_ist(local, v.close, off)} IST');
  }
  var day = local;
  if (!(weekday && mins < v.open)) {
    do {
      day = day.add(const Duration(days: 1));
    } while (day.weekday > 5);
  }
  final when = day.day == local.day ? '' : '${_dow[day.weekday]} ';
  return SessionState(v.name, false, 'opens $when${_ist(day, v.open, off)} IST');
}

List<SessionState> sessionStates(DateTime utcNow) {
  final u = utcNow.toUtc();
  return [for (final v in _venues) _state(v, u)];
}
