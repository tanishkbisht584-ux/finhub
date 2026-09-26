import 'package:finflick/portfolio.dart';
import 'package:flutter_test/flutter_test.dart';

Trade _t(String sym, String side, double qty, double price, String day, {int? id}) =>
    Trade(id: id, symbol: sym, side: side, qty: qty, price: price, tradedOn: DateTime.parse(day));

void main() {
  group('holdingsFrom', () {
    test('two buys average; a partial sell realises at the average and keeps it', () {
      final h = holdingsFrom([
        _t('TCS', 'buy', 10, 3900, '2026-06-01', id: 1),
        _t('TCS', 'buy', 10, 4100, '2026-07-01', id: 2),
        _t('TCS', 'sell', 4, 4500, '2026-08-01', id: 3),
      ]).single;
      expect(h.qty, 16);
      expect(h.avgCost, 4000);
      expect(h.realised, 4 * 500);
      expect(h.overSold, isFalse);
    });

    test('oversell is clamped and flagged; a closed position keeps realised', () {
      final h = holdingsFrom([
        _t('INFY', 'buy', 5, 1500, '2026-01-01', id: 1),
        _t('INFY', 'sell', 8, 1600, '2026-02-01', id: 2),
      ]).single;
      expect(h.qty, 0);
      expect(h.realised, 500);
      expect(h.overSold, isTrue);
    });

    test('order is by date then id, not insertion', () {
      final h = holdingsFrom([
        _t('A', 'sell', 1, 20, '2026-03-01', id: 2),
        _t('A', 'buy', 1, 10, '2026-02-01', id: 1),
      ]).single;
      expect(h.realised, 10);
      expect(h.overSold, isFalse);
    });
  });

  group('xirr', () {
    test('one year, −1000 → +1100 is 10%', () {
      final r = xirr([(DateTime(2021, 1, 1), -1000), (DateTime(2022, 1, 1), 1100)])!; // 365 days
      expect(r, closeTo(0.10, 1e-4));
    });

    test('a 4-flow ledger matches Excel XIRR', () {
      // act/365 reference (Python bisection on the same flows): 0.13024
      final r = xirr([
        (DateTime(2024, 1, 1), -10000),
        (DateTime(2024, 7, 1), -5000),
        (DateTime(2025, 1, 1), 2000),
        (DateTime(2025, 9, 26), 16000),
      ])!;
      expect(r, closeTo(0.13024, 2e-4));
    });

    test('null without a sign change, with one date, or with one flow', () {
      expect(xirr([(DateTime(2020), -1), (DateTime(2021), -2)]), isNull);
      expect(xirr([(DateTime(2020), -1), (DateTime(2020), 2)]), isNull);
      expect(xirr([(DateTime(2020), -1)]), isNull);
    });

    test('a loss gives a negative rate', () {
      expect(xirr([(DateTime(2021, 1, 1), -1000), (DateTime(2022, 1, 1), 800)])!, closeTo(-0.2, 1e-3));
    });
  });

  group('cashFlows + allocation', () {
    final trades = [
      _t('TCS', 'buy', 10, 3900, '2026-06-01', id: 1),
      _t('INFY', 'buy', 20, 1500, '2026-06-01', id: 2),
      _t('INFY', 'sell', 20, 1600, '2026-07-01', id: 3),
    ];
    test('buys out, sells in, terminal value in; null when a holding has no price', () {
      final f = cashFlows(trades, {'TCS': 4000}, DateTime(2026, 9, 26))!;
      expect(f.map((x) => x.$2), [-39000, -30000, 32000, 40000]);
      expect(cashFlows(trades, const {}, DateTime(2026, 9, 26)), isNull);
    });
    test('allocation shares sum to 1 and key by sector or symbol', () {
      final hs = holdingsFrom([...trades, _t('HDFCBANK', 'buy', 5, 1600, '2026-06-01', id: 4)]);
      final bySym = allocation(hs, {'TCS': 4000, 'HDFCBANK': 2000}, (s) => s);
      expect(bySym.values.fold(0.0, (a, b) => a + b), closeTo(1, 1e-9));
      expect(bySym['TCS'], closeTo(0.8, 1e-9));
      final bySector = allocation(hs, {'TCS': 4000, 'HDFCBANK': 2000}, (s) => s == 'TCS' ? 'IT' : 'Banks');
      expect(bySector.keys, ['IT', 'Banks']);
    });
  });

  group('parseTradesCsv', () {
    test('Zerodha Console tradebook: dates, sides, source', () {
      final p = parseTradesCsv('''symbol,isin,trade_date,exchange,segment,series,trade_type,auction,quantity,price,trade_id,order_id,order_execution_time
TCS,INE467B01029,2026-06-12,NSE,EQ,EQ,buy,false,10,3900.5,12345,99,2026-06-12T10:15:00
TCS,INE467B01029,2026-08-01,NSE,EQ,EQ,sell,false,4,4500,12346,100,2026-08-01T11:00:00
''');
      expect(p.source, 'zerodha');
      expect(p.dated, isTrue);
      expect(p.rows.length, 2);
      expect(p.rows[0].symbol, 'TCS');
      expect(p.rows[0].side, 'buy');
      expect(p.rows[0].price, 3900.5);
      expect(p.rows[0].date, DateTime(2026, 6, 12));
      expect(p.rows[1].side, 'sell');
    });

    test('Console holdings with a preamble and quoted fields, no dates', () {
      final p = parseTradesCsv('''Holdings as on 26-09-2026
Client ID,AB1234

Symbol,ISIN,Sector,Quantity Available,Quantity Discrepant,Quantity Long Term,Quantity Pledged (Margin),Quantity Pledged (Loan),Average Price,Previous Closing Price,Unrealized P&L,Unrealized P&L Pct.
"M&M",INE101A01026,"Automobiles, Cars",12,0,12,0,0,"2,850.25",3000,1797,5.25
INFY,INE009A01021,IT,20,0,20,0,0,1500,1600,2000,6.67
Total,,,,,,,,,,3797,
''');
      expect(p.source, 'zerodha');
      expect(p.dated, isFalse);
      expect(p.rows.map((r) => r.symbol), ['M&M', 'INFY']);
      expect(p.rows[0].price, 2850.25);
      expect(p.rows[0].qty, 12);
      expect(p.rows.every((r) => r.side == 'buy'), isTrue);
    });

    test('Kite holdings download', () {
      final p = parseTradesCsv('''Instrument,Qty.,Avg. cost,LTP,Cur. val,P&L,Net chg.,Day chg.
TCS,10,3900,4000,40000,1000,2.56,0.5
''');
      expect(p.source, 'zerodha');
      expect(p.rows.single.symbol, 'TCS');
      expect(p.rows.single.price, 3900);
    });

    test('Groww: name + ISIN, no symbol → symbol empty, isin kept', () {
      final p = parseTradesCsv('''Stock Name,ISIN,Quantity,Average buy price,Buy value,Closing price,Closing value,Unrealised P&L
Tata Consultancy Services,INE467B01029,10,3900,39000,4000,40000,1000
''');
      expect(p.source, 'groww');
      expect(p.rows.single.symbol, '');
      expect(p.rows.single.isin, 'INE467B01029');
      expect(p.rows.single.name, 'Tata Consultancy Services');
    });

    test('Upstox-shaped holdings; symbol suffixes stripped; dd/mm/yyyy dates', () {
      final p = parseTradesCsv('''Instrument\tQty\tAvg. Price\tInvested\tLTP\tDate
TCS-EQ\t10\t3,900\t39000\t4000\t12/06/2026
''');
      expect(p.source, 'upstox');
      expect(p.rows.single.symbol, 'TCS');
      expect(p.rows.single.price, 3900);
      expect(p.rows.single.date, DateTime(2026, 6, 12));
    });

    test('garbage / missing quantity → nothing; rows without price are skipped, not imported', () {
      expect(parseTradesCsv('hello world\n1,2,3').rows, isEmpty);
      final p = parseTradesCsv('symbol,quantity,price\nTCS,10,\nINFY,5,1500\n');
      expect(p.rows.single.symbol, 'INFY');
      expect(p.skipped.length, 1);
    });
  });

  test('splitCsvLine handles quotes, doubled quotes and empty cells', () {
    expect(splitCsvLine('a,"b, c","say ""hi""",,e'), ['a', 'b, c', 'say "hi"', '', 'e']);
  });

  test('parseTradeDate accepts ISO, ISO with time, d-m-y, d-Mon-y', () {
    expect(parseTradeDate('2026-06-12'), DateTime(2026, 6, 12));
    expect(parseTradeDate('2026-06-12 10:15:00'), DateTime(2026, 6, 12));
    expect(parseTradeDate('12-06-26'), DateTime(2026, 6, 12));
    expect(parseTradeDate('12-Jun-2026'), DateTime(2026, 6, 12));
    expect(parseTradeDate('junk'), isNull);
  });

  test('healthFlags are plain facts with thresholds', () {
    expect(healthFlags({'de': 2.5, 'altman_z': 1.2, 'f_score': 3, 'hi52': 100, 'lo52': 50, 'pe': -4}, 52),
        ['D/E 2.5', 'Altman Z 1.2', 'F-score 3', 'near 52w low', 'loss-making']);
    expect(healthFlags({'de': 0.1, 'hi52': 100, 'lo52': 50}, 97), ['near 52w high']);
    expect(healthFlags(const {}, null), isEmpty);
  });
}
