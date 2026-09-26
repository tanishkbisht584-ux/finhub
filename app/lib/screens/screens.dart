import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../glossary.dart' show showDefineSheet;
import '../ledger.dart' show pillRow;
import '../models.dart';
import '../screen_query.dart';
import '../theme.dart';
import 'feed.dart' show filterPill, showPillSheet;
import 'stock.dart';

/// The screening engine ("screens" half of Screener): filter/rank the
/// `screener_metrics` table server-side — one PostgREST query per change,
/// <=50 rows back. Metrics are rebuilt daily by pipeline/fundamentals.py.

typedef ScreenFilter = ({String metric, bool gte, double value});
typedef ScreenPreset = ({
  String name,
  List<ScreenFilter> filters,
  String sortCol,
  bool asc
});

typedef MetricDef = ({
  String col,
  String label,
  String unit,
  String cat,
  String term,
  List<(String, bool, double)> choices
});

/// Column, chip label, category, glossary term, curated threshold pills
/// (label, gte, value). 033 (26 Sep 2026): 44 -> ~170, three owners (see
/// pipeline/migrations/033_screener_breadth.sql). ponytail: pill thresholds
/// only; the custom box covers PE < 17.3.
final List<MetricDef> metricDefs = [
  (col: 'pe', label: 'PE', unit: '', cat: 'VALUATION', term: 'pe', choices: [ ('≤ 10', false, 10), ('≤ 15', false, 15), ('≤ 25', false, 25), ('≥ 25', true, 25) ]),
  (col: 'pb', label: 'PB', unit: '', cat: 'VALUATION', term: 'pb', choices: [('≤ 1', false, 1), ('≤ 3', false, 3), ('≥ 3', true, 3)]),
  (col: 'mcap_cr', label: 'MCAP', unit: ' CR', cat: 'SIZE & SECTOR', term: 'market cap', choices: [ ('≥ 300', true, 300), ('≥ 500', true, 500), ('≥ 5000', true, 5000), ('≤ 5000', false, 5000), ('≥ 20000', true, 20000) ]),
  (col: 'div_yield', label: 'DIV YIELD', unit: '%', cat: 'DIVIDENDS', term: 'dividend yield', choices: [('≥ 1', true, 1), ('≥ 3', true, 3), ('≥ 5', true, 5)]),
  (col: 'roe', label: 'ROE', unit: '%', cat: 'PROFITABILITY', term: 'roe', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'roce', label: 'ROCE', unit: '%', cat: 'PROFITABILITY', term: 'roce', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'de', label: 'DEBT/EQ', unit: '', cat: 'BALANCE SHEET', term: 'debt to equity', choices: [('≤ 0.1', false, 0.1), ('≤ 0.3', false, 0.3), ('≤ 1', false, 1)]),
  (col: 'opm', label: 'OPM', unit: '%', cat: 'PROFITABILITY', term: 'operating margin', choices: [('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'sales_cagr_3y', label: 'SALES 3Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'profit_cagr_3y', label: 'PROFIT 3Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'sales_cagr_5y', label: 'SALES 5Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 10', true, 10), ('≥ 15', true, 15)]),
  (col: 'profit_cagr_5y', label: 'PROFIT 5Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'promoter_pct', label: 'PROMOTER', unit: '%', cat: 'OWNERSHIP', term: 'promoter holding', choices: [('≥ 50', true, 50), ('≥ 60', true, 60), ('≥ 75', true, 75)]),
  (col: 'ret_1w', label: 'RET 1W', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 5', true, 5), ('≤ -5', false, -5)]),
  (col: 'ret_1m', label: 'RET 1M', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 0', true, 0), ('≥ 10', true, 10), ('≤ -10', false, -10)]),
  (col: 'ret_3m', label: 'RET 3M', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 0', true, 0), ('≥ 10', true, 10), ('≤ -10', false, -10)]),
  (col: 'ret_6m', label: 'RET 6M', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 0', true, 0), ('≥ 20', true, 20), ('≤ -20', false, -20)]),
  (col: 'ret_ytd', label: 'RET YTD', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 0', true, 0), ('≥ 20', true, 20), ('≤ -10', false, -10)]),
  (col: 'ret_1y', label: 'RET 1Y', unit: '%', cat: 'RETURNS', term: 'return', choices: [ ('≥ 0', true, 0), ('≥ 25', true, 25), ('≥ 50', true, 50), ('≤ -20', false, -20) ]),
  (col: 'ret_3y', label: 'RET 3Y', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 50', true, 50), ('≥ 100', true, 100), ('≥ 200', true, 200)]),
  (col: 'ret_5y', label: 'RET 5Y', unit: '%', cat: 'RETURNS', term: 'return', choices: [('≥ 100', true, 100), ('≥ 200', true, 200), ('≥ 500', true, 500)]),
  (col: 'ath_pct', label: 'FROM ATH', unit: '%', cat: 'TECHNICALS', term: 'all-time high', choices: [('≥ -5', true, -5), ('≥ -20', true, -20), ('≤ -50', false, -50)]),
  (col: 'turnover_cr', label: 'TURNOVER', unit: ' CR', cat: 'PRICE & VOLUME', term: 'turnover', choices: [('≥ 1', true, 1), ('≥ 10', true, 10), ('≥ 100', true, 100)]),
  (col: 'avg_vol', label: 'AVG VOL', unit: '', cat: 'PRICE & VOLUME', term: 'average volume', choices: [('≥ 100000', true, 100000), ('≥ 1000000', true, 1000000)]),
  (col: 'rel_vol', label: 'REL VOL', unit: 'x', cat: 'PRICE & VOLUME', term: 'relative volume', choices: [('≥ 1.5', true, 1.5), ('≥ 3', true, 3)]),
  (col: 'sharpe', label: 'SHARPE', unit: '', cat: 'RISK', term: 'sharpe ratio', choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]),
  (col: 'sortino', label: 'SORTINO', unit: '', cat: 'RISK', term: 'sortino ratio', choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]),
  (col: 'atr', label: 'ATR', unit: '', cat: 'RISK', term: 'average true range', choices: [('≤ 10', false, 10), ('≤ 50', false, 50)]),
  (col: 'graham_upside', label: 'GRAHAM UPSIDE', unit: '%', cat: 'VALUATION', term: 'graham number', choices: [('≥ 0', true, 0), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'f_score', label: 'F-SCORE', unit: '', cat: 'PROFITABILITY', term: 'piotroski f-score', choices: [('≥ 6', true, 6), ('≥ 7', true, 7), ('≥ 8', true, 8)]),
  (col: 'ps', label: 'P/S', unit: '', cat: 'VALUATION', term: 'price to sales', choices: [('≤ 1', false, 1), ('≤ 3', false, 3), ('≤ 10', false, 10)]),
  (col: 'earnings_yield', label: 'EARN YIELD', unit: '%', cat: 'VALUATION', term: 'earnings yield', choices: [('≥ 4', true, 4), ('≥ 8', true, 8)]),
  (col: 'fcf_yield', label: 'FCF YIELD', unit: '%', cat: 'CASH FLOW', term: 'fcf yield', choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 8', true, 8)]),
  (col: 'roic', label: 'ROIC', unit: '%', cat: 'PROFITABILITY', term: 'roic', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'int_cov', label: 'INT COVER', unit: 'x', cat: 'BALANCE SHEET', term: 'interest coverage', choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 10', true, 10)]),
  (col: 'ev_ebitda', label: 'EV/EBITDA', unit: '', cat: 'VALUATION', term: 'ev/ebitda', choices: [('≤ 8', false, 8), ('≤ 12', false, 12), ('≤ 20', false, 20)]),
  (col: 'sector_pe', label: 'SECTOR PE', unit: '', cat: 'VALUATION', term: 'sector pe', choices: [('≤ 15', false, 15), ('≤ 25', false, 25)]),
  (col: 'industry_pe', label: 'INDUSTRY PE', unit: '', cat: 'VALUATION', term: 'industry pe', choices: [('≤ 15', false, 15), ('≤ 25', false, 25)]),
  (col: 'shares_yoy', label: 'SHARES YOY', unit: '%', cat: 'OWNERSHIP', term: 'dilution', choices: [('≤ 0', false, 0), ('≤ 2', false, 2), ('≥ 5', true, 5)]),
  (col: 'rsi', label: 'RSI', unit: '', cat: 'TECHNICALS', term: 'rsi', choices: [('≤ 30', false, 30), ('≤ 40', false, 40), ('≥ 60', true, 60), ('≥ 70', true, 70)]),
  (col: 'altman_z', label: 'ALTMAN Z', unit: '', cat: 'RISK', term: 'altman z', choices: [('≥ 3', true, 3), ('≥ 1.8', true, 1.8), ('≤ 1.8', false, 1.8)]),
  (col: 'beta_5y', label: 'BETA', unit: '', cat: 'RISK', term: 'beta', choices: [('≤ 0.8', false, 0.8), ('≤ 1', false, 1), ('≥ 1.2', true, 1.2)]),
  // ---- 033 stockanalysis-owned ----
  (col: 'ret_10y', label: 'RET 10Y', unit: '%', cat: 'RETURNS', term: '10-year return', choices: [('≥ 50', true, 50), ('≥ 100', true, 100), ('≥ 300', true, 300)]),
  (col: 'tr_1y', label: 'TOTAL RET 1Y', unit: '%', cat: 'RETURNS', term: 'total return', choices: [('≥ 10', true, 10), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'dist_lo52', label: 'ABOVE 52W LOW', unit: '%', cat: 'TECHNICALS', term: '52-week low', choices: [('≥ 10', true, 10), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'dist_hi52', label: 'FROM 52W HIGH', unit: '%', cat: 'TECHNICALS', term: '52-week high', choices: [('≥ -5', true, -5), ('≥ -10', true, -10), ('≥ -25', true, -25)]),
  (col: 'from_atl_pct', label: 'FROM ATL', unit: '%', cat: 'TECHNICALS', term: 'all-time low', choices: [('≥ 50', true, 50), ('≥ 100', true, 100), ('≥ 500', true, 500)]),
  (col: 'target_upside', label: 'TARGET UPSIDE', unit: '%', cat: 'VALUATION', term: 'price target', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'analyst_count', label: 'ANALYSTS', unit: '', cat: 'VALUATION', term: 'analyst coverage', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'employees', label: 'EMPLOYEES', unit: '', cat: 'SIZE & SECTOR', term: 'employees', choices: [('≥ 1000', true, 1000), ('≥ 10000', true, 10000), ('≥ 50000', true, 50000)]),
  (col: 'rev_per_employee_l', label: 'REV / EMPLOYEE', unit: ' L', cat: 'PROFITABILITY', term: 'revenue per employee', choices: [('≥ 10', true, 10), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'fwd_pe', label: 'FWD PE', unit: '', cat: 'VALUATION', term: 'forward pe', choices: [('≤ 10', false, 10), ('≤ 15', false, 15), ('≤ 25', false, 25)]),
  (col: 'pe_avg_3y', label: 'PE AVG 3Y', unit: '', cat: 'VALUATION', term: 'average pe', choices: [('≤ 15', false, 15), ('≤ 25', false, 25), ('≤ 40', false, 40)]),
  (col: 'pe_avg_5y', label: 'PE AVG 5Y', unit: '', cat: 'VALUATION', term: 'average pe', choices: [('≤ 15', false, 15), ('≤ 25', false, 25), ('≤ 40', false, 40)]),
  (col: 'peg', label: 'PEG', unit: '', cat: 'VALUATION', term: 'peg ratio', choices: [('≤ 1', false, 1), ('≤ 1.5', false, 1.5), ('≤ 2', false, 2)]),
  (col: 'ev_sales', label: 'EV/SALES', unit: '', cat: 'VALUATION', term: 'ev/sales', choices: [('≤ 1', false, 1), ('≤ 3', false, 3), ('≤ 5', false, 5)]),
  (col: 'ev_ebit', label: 'EV/EBIT', unit: '', cat: 'VALUATION', term: 'ev/ebit', choices: [('≤ 10', false, 10), ('≤ 15', false, 15), ('≤ 25', false, 25)]),
  (col: 'ev_fcf', label: 'EV/FCF', unit: '', cat: 'VALUATION', term: 'ev/fcf', choices: [('≤ 10', false, 10), ('≤ 20', false, 20), ('≤ 30', false, 30)]),
  (col: 'ev_cr', label: 'EV', unit: ' CR', cat: 'SIZE & SECTOR', term: 'enterprise value', choices: [('≥ 500', true, 500), ('≥ 5000', true, 5000), ('≥ 50000', true, 50000)]),
  (col: 'p_fcf', label: 'P/FCF', unit: '', cat: 'VALUATION', term: 'price to free cash flow', choices: [('≤ 10', false, 10), ('≤ 20', false, 20), ('≤ 30', false, 30)]),
  (col: 'p_ocf', label: 'P/OCF', unit: '', cat: 'VALUATION', term: 'price to operating cash flow', choices: [('≤ 10', false, 10), ('≤ 15', false, 15), ('≤ 25', false, 25)]),
  (col: 'p_ebitda', label: 'P/EBITDA', unit: '', cat: 'VALUATION', term: 'price to ebitda', choices: [('≤ 5', false, 5), ('≤ 10', false, 10), ('≤ 20', false, 20)]),
  (col: 'gross_margin', label: 'GROSS MARGIN', unit: '%', cat: 'PROFITABILITY', term: 'gross margin', choices: [('≥ 20', true, 20), ('≥ 40', true, 40), ('≥ 60', true, 60)]),
  (col: 'ebitda_margin', label: 'EBITDA MARGIN', unit: '%', cat: 'PROFITABILITY', term: 'ebitda margin', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'pretax_margin', label: 'PRETAX MARGIN', unit: '%', cat: 'PROFITABILITY', term: 'pretax margin', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'npm', label: 'NET MARGIN', unit: '%', cat: 'PROFITABILITY', term: 'net margin', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'fcf_margin', label: 'FCF MARGIN', unit: '%', cat: 'CASH FLOW', term: 'fcf margin', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'buyback_yield', label: 'BUYBACK YIELD', unit: '%', cat: 'DIVIDENDS', term: 'buyback yield', choices: [('≥ 1', true, 1), ('≥ 2', true, 2), ('≥ 5', true, 5)]),
  (col: 'shareholder_yield', label: 'SHAREHOLDER YIELD', unit: '%', cat: 'DIVIDENDS', term: 'shareholder yield', choices: [('≥ 1', true, 1), ('≥ 3', true, 3), ('≥ 5', true, 5)]),
  (col: 'div_growth_5y', label: 'DIV GROWTH 5Y', unit: '%', cat: 'DIVIDENDS', term: 'dividend growth', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'div_years', label: 'DIV YEARS', unit: '', cat: 'DIVIDENDS', term: 'dividend payment years', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 20', true, 20)]),
  (col: 'net_cash_cr', label: 'NET CASH', unit: ' CR', cat: 'BALANCE SHEET', term: 'net cash', choices: [('≥ 0', true, 0), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'cash_cr', label: 'CASH', unit: ' CR', cat: 'BALANCE SHEET', term: 'cash and equivalents', choices: [('≥ 100', true, 100), ('≥ 1000', true, 1000), ('≥ 10000', true, 10000)]),
  (col: 'net_cash_mcap_pct', label: 'NET CASH / MCAP', unit: '%', cat: 'BALANCE SHEET', term: 'net cash to market cap', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 25', true, 25)]),
  (col: 'debt_ebitda', label: 'DEBT/EBITDA', unit: '', cat: 'BALANCE SHEET', term: 'debt to ebitda', choices: [('≤ 1', false, 1), ('≤ 2', false, 2), ('≤ 3', false, 3)]),
  (col: 'nd_ebitda', label: 'NET DEBT/EBITDA', unit: '', cat: 'BALANCE SHEET', term: 'net debt to ebitda', choices: [('≤ 0', false, 0), ('≤ 1', false, 1), ('≤ 3', false, 3)]),
  (col: 'debt_fcf', label: 'DEBT/FCF', unit: '', cat: 'BALANCE SHEET', term: 'debt to free cash flow', choices: [('≤ 1', false, 1), ('≤ 3', false, 3), ('≤ 5', false, 5)]),
  (col: 'inst_pct', label: 'INSTITUTIONS', unit: '%', cat: 'OWNERSHIP', term: 'institutional holding', choices: [('≥ 10', true, 10), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'ma20', label: '20 DMA', unit: '', cat: 'TECHNICALS', term: 'moving average', choices: []),
  (col: 'ma150', label: '150 DMA', unit: '', cat: 'TECHNICALS', term: 'moving average', choices: []),
  (col: 'dist_ma20', label: 'VS 20 DMA', unit: '%', cat: 'TECHNICALS', term: 'moving average', choices: [('≥ 0', true, 0), ('≥ 5', true, 5), ('≤ -5', false, -5)]),
  (col: 'dist_ma50', label: 'VS 50 DMA', unit: '%', cat: 'TECHNICALS', term: 'moving average', choices: [('≥ 0', true, 0), ('≥ 5', true, 5), ('≤ -5', false, -5)]),
  (col: 'dist_ma200', label: 'VS 200 DMA', unit: '%', cat: 'TECHNICALS', term: 'moving average', choices: [('≥ 0', true, 0), ('≥ 10', true, 10), ('≤ -10', false, -10)]),
  (col: 'rsi_w', label: 'RSI WEEKLY', unit: '', cat: 'TECHNICALS', term: 'rsi', choices: [('≤ 30', false, 30), ('≤ 50', false, 50), ('≤ 70', false, 70)]),
  (col: 'rsi_m', label: 'RSI MONTHLY', unit: '', cat: 'TECHNICALS', term: 'rsi', choices: [('≤ 30', false, 30), ('≤ 50', false, 50), ('≤ 70', false, 70)]),
  (col: 'beta_1y', label: 'BETA 1Y', unit: '', cat: 'RISK', term: 'beta', choices: [('≤ 0.5', false, 0.5), ('≤ 1', false, 1), ('≤ 1.5', false, 1.5)]),
  (col: 'sharpe_3y', label: 'SHARPE 3Y', unit: '', cat: 'RISK', term: 'sharpe ratio', choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]),
  (col: 'sortino_3y', label: 'SORTINO 3Y', unit: '', cat: 'RISK', term: 'sortino ratio', choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]),
  (col: 'gap_pct', label: 'GAP', unit: '%', cat: 'PRICE & VOLUME', term: 'gap up', choices: [('≥ 1', true, 1), ('≥ 2', true, 2), ('≥ 5', true, 5)]),
  (col: 'range_pos', label: 'RANGE POS', unit: '%', cat: 'PRICE & VOLUME', term: 'position in range', choices: [('≥ 20', true, 20), ('≥ 50', true, 50), ('≥ 80', true, 80)]),
  (col: 'from_open_pct', label: 'FROM OPEN', unit: '%', cat: 'PRICE & VOLUME', term: 'change from open', choices: [('≥ 1', true, 1), ('≥ 2', true, 2), ('≤ -2', false, -2)]),
  (col: 'shares_qoq', label: 'SHARES QOQ', unit: '%', cat: 'OWNERSHIP', term: 'dilution', choices: [('≤ 0', false, 0), ('≤ 1', false, 1), ('≤ 5', false, 5)]),
  (col: 'float_pct', label: 'FREE FLOAT', unit: '%', cat: 'OWNERSHIP', term: 'free float', choices: [('≥ 25', true, 25), ('≥ 50', true, 50), ('≥ 75', true, 75)]),
  (col: 'lynch_upside', label: 'LYNCH UPSIDE', unit: '%', cat: 'VALUATION', term: 'lynch fair value', choices: [('≥ 0', true, 0), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'wacc', label: 'WACC', unit: '%', cat: 'RISK', term: 'wacc', choices: [('≤ 8', false, 8), ('≤ 10', false, 10), ('≤ 12', false, 12)]),
  (col: 'profitable_years', label: 'PROFITABLE YRS', unit: '', cat: 'PROFITABILITY', term: 'profitable years', choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 10', true, 10)]),
  (col: 'rev_growth_years', label: 'REV GROWTH YRS', unit: '', cat: 'GROWTH', term: 'revenue growth years', choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 10', true, 10)]),
  (col: 'div_growth_years', label: 'DIV GROWTH YRS', unit: '', cat: 'DIVIDENDS', term: 'dividend growth years', choices: [('≥ 3', true, 3), ('≥ 5', true, 5), ('≥ 10', true, 10)]),
  (col: 'eps_growth', label: 'EPS GROWTH', unit: '%', cat: 'GROWTH', term: 'eps growth', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'eps_growth_q', label: 'EPS GROWTH Q', unit: '%', cat: 'GROWTH', term: 'eps growth', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'fcf_ps', label: 'FCF / SHARE', unit: '', cat: 'CASH FLOW', term: 'free cash flow per share', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 25', true, 25)]),
  (col: 'p_tbv', label: 'P/TBV', unit: '', cat: 'VALUATION', term: 'tangible book value', choices: [('≤ 1', false, 1), ('≤ 2', false, 2), ('≤ 4', false, 4)]),
  // ---- 033 fundamentals-derived ----
  (col: 'sales_cr', label: 'SALES', unit: ' CR', cat: 'SIZE & SECTOR', term: 'revenue', choices: [('≥ 100', true, 100), ('≥ 1000', true, 1000), ('≥ 10000', true, 10000)]),
  (col: 'pat_cr', label: 'NET PROFIT', unit: ' CR', cat: 'SIZE & SECTOR', term: 'net profit', choices: [('≥ 10', true, 10), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'op_profit_cr', label: 'OP PROFIT', unit: ' CR', cat: 'SIZE & SECTOR', term: 'operating profit', choices: [('≥ 10', true, 10), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'sales_1y', label: 'SALES GROWTH 1Y', unit: '%', cat: 'GROWTH', term: 'sales growth', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'profit_1y', label: 'PROFIT GROWTH 1Y', unit: '%', cat: 'GROWTH', term: 'profit growth', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'sales_cagr_10y', label: 'SALES CAGR 10Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'profit_cagr_10y', label: 'PROFIT CAGR 10Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'sales_ttm_cr', label: 'SALES TTM', unit: ' CR', cat: 'SIZE & SECTOR', term: 'ttm', choices: [('≥ 100', true, 100), ('≥ 1000', true, 1000), ('≥ 10000', true, 10000)]),
  (col: 'pat_ttm_cr', label: 'PROFIT TTM', unit: ' CR', cat: 'SIZE & SECTOR', term: 'ttm', choices: [('≥ 10', true, 10), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'sales_ttm_growth', label: 'SALES TTM GROWTH', unit: '%', cat: 'GROWTH', term: 'ttm', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'profit_ttm_growth', label: 'PROFIT TTM GROWTH', unit: '%', cat: 'GROWTH', term: 'ttm', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'sales_yoy_q', label: 'SALES YOY Q', unit: '%', cat: 'GROWTH', term: 'quarterly growth', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'profit_yoy_q', label: 'PROFIT YOY Q', unit: '%', cat: 'GROWTH', term: 'quarterly growth', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'sales_qoq', label: 'SALES QOQ', unit: '%', cat: 'GROWTH', term: 'quarterly growth', choices: [('≥ 0', true, 0), ('≥ 5', true, 5), ('≥ 10', true, 10)]),
  (col: 'profit_qoq', label: 'PROFIT QOQ', unit: '%', cat: 'GROWTH', term: 'quarterly growth', choices: [('≥ 0', true, 0), ('≥ 5', true, 5), ('≥ 10', true, 10)]),
  (col: 'opm_q', label: 'OPM LATEST Q', unit: '%', cat: 'PROFITABILITY', term: 'operating margin', choices: [('≥ 10', true, 10), ('≥ 20', true, 20), ('≥ 30', true, 30)]),
  (col: 'opm_trend', label: 'OPM TREND', unit: ' pt', cat: 'PROFITABILITY', term: 'margin trend', choices: [('≥ 0', true, 0), ('≥ 2', true, 2), ('≥ 5', true, 5)]),
  (col: 'eps_ttm', label: 'EPS TTM', unit: '', cat: 'PROFITABILITY', term: 'eps', choices: [('≥ 1', true, 1), ('≥ 10', true, 10), ('≥ 50', true, 50)]),
  (col: 'eps_cagr_3y', label: 'EPS CAGR 3Y', unit: '%', cat: 'GROWTH', term: 'cagr', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'bvps', label: 'BOOK VALUE / SH', unit: '', cat: 'VALUATION', term: 'book value', choices: [('≥ 10', true, 10), ('≥ 100', true, 100), ('≥ 500', true, 500)]),
  (col: 'tax_pct', label: 'TAX RATE', unit: '%', cat: 'PROFITABILITY', term: 'effective tax rate', choices: [('≤ 15', false, 15), ('≤ 25', false, 25), ('≤ 30', false, 30)]),
  (col: 'int_cr', label: 'INTEREST', unit: ' CR', cat: 'BALANCE SHEET', term: 'interest cost', choices: [('≤ 1', false, 1), ('≤ 10', false, 10), ('≤ 100', false, 100)]),
  (col: 'dep_cr', label: 'DEPRECIATION', unit: ' CR', cat: 'PROFITABILITY', term: 'depreciation', choices: [('≤ 1', false, 1), ('≤ 10', false, 10), ('≤ 100', false, 100)]),
  (col: 'other_income_pct', label: 'OTHER INCOME / PBT', unit: '%', cat: 'PROFITABILITY', term: 'other income', choices: [('≤ 5', false, 5), ('≤ 10', false, 10), ('≤ 25', false, 25)]),
  (col: 'reserves_cr', label: 'RESERVES', unit: ' CR', cat: 'BALANCE SHEET', term: 'reserves', choices: [('≥ 100', true, 100), ('≥ 1000', true, 1000), ('≥ 10000', true, 10000)]),
  (col: 'equity_cr', label: 'NET WORTH', unit: ' CR', cat: 'BALANCE SHEET', term: 'net worth', choices: [('≥ 100', true, 100), ('≥ 1000', true, 1000), ('≥ 10000', true, 10000)]),
  (col: 'debt_cr', label: 'BORROWINGS', unit: ' CR', cat: 'BALANCE SHEET', term: 'borrowings', choices: [('≤ 0', false, 0), ('≤ 100', false, 100), ('≤ 1000', false, 1000)]),
  (col: 'total_assets_cr', label: 'TOTAL ASSETS', unit: ' CR', cat: 'BALANCE SHEET', term: 'total assets', choices: [('≥ 100', true, 100), ('≥ 1000', true, 1000), ('≥ 10000', true, 10000)]),
  (col: 'current_ratio', label: 'CURRENT RATIO', unit: '', cat: 'BALANCE SHEET', term: 'current ratio', choices: [('≥ 1', true, 1), ('≥ 1.5', true, 1.5), ('≥ 2', true, 2)]),
  (col: 'quick_ratio', label: 'QUICK RATIO', unit: '', cat: 'BALANCE SHEET', term: 'quick ratio', choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 1.5', true, 1.5)]),
  (col: 'wc_days', label: 'WORKING CAP DAYS', unit: '', cat: 'BALANCE SHEET', term: 'working capital days', choices: [('≤ 30', false, 30), ('≤ 60', false, 60), ('≤ 90', false, 90)]),
  (col: 'debtor_days', label: 'DEBTOR DAYS', unit: '', cat: 'BALANCE SHEET', term: 'debtor days', choices: [('≤ 30', false, 30), ('≤ 60', false, 60), ('≤ 90', false, 90)]),
  (col: 'inventory_days', label: 'INVENTORY DAYS', unit: '', cat: 'BALANCE SHEET', term: 'inventory days', choices: [('≤ 30', false, 30), ('≤ 60', false, 60), ('≤ 120', false, 120)]),
  (col: 'payable_days', label: 'PAYABLE DAYS', unit: '', cat: 'BALANCE SHEET', term: 'payable days', choices: [('≥ 30', true, 30), ('≥ 60', true, 60), ('≥ 90', true, 90)]),
  (col: 'ccc_days', label: 'CASH CYCLE DAYS', unit: '', cat: 'BALANCE SHEET', term: 'cash conversion cycle', choices: [('≤ 0', false, 0), ('≤ 30', false, 30), ('≤ 90', false, 90)]),
  (col: 'roa', label: 'ROA', unit: '%', cat: 'PROFITABILITY', term: 'return on assets', choices: [('≥ 5', true, 5), ('≥ 10', true, 10), ('≥ 15', true, 15)]),
  (col: 'roe_3y', label: 'ROE 3Y AVG', unit: '%', cat: 'PROFITABILITY', term: 'return on equity', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'roce_3y', label: 'ROCE 3Y AVG', unit: '%', cat: 'PROFITABILITY', term: 'return on capital employed', choices: [('≥ 10', true, 10), ('≥ 15', true, 15), ('≥ 20', true, 20)]),
  (col: 'asset_turnover', label: 'ASSET TURNOVER', unit: '×', cat: 'PROFITABILITY', term: 'asset turnover', choices: [('≥ 0.5', true, 0.5), ('≥ 1', true, 1), ('≥ 2', true, 2)]),
  (col: 'cfo_cr', label: 'CASH FROM OPS', unit: ' CR', cat: 'CASH FLOW', term: 'operating cash flow', choices: [('≥ 10', true, 10), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'fcf_cr', label: 'FREE CASH FLOW', unit: ' CR', cat: 'CASH FLOW', term: 'free cash flow', choices: [('≥ 0', true, 0), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'capex_cr', label: 'CAPEX', unit: ' CR', cat: 'CASH FLOW', term: 'capex', choices: [('≥ 10', true, 10), ('≥ 100', true, 100), ('≥ 1000', true, 1000)]),
  (col: 'cash_conv', label: 'CASH CONVERSION', unit: '%', cat: 'CASH FLOW', term: 'cash conversion', choices: [('≥ 50', true, 50), ('≥ 80', true, 80), ('≥ 100', true, 100)]),
  (col: 'div_payout', label: 'PAYOUT', unit: '%', cat: 'DIVIDENDS', term: 'dividend payout', choices: [('≥ 20', true, 20), ('≥ 40', true, 40), ('≥ 60', true, 60)]),
  (col: 'fii_pct', label: 'FII', unit: '%', cat: 'OWNERSHIP', term: 'fii holding', choices: [('≥ 5', true, 5), ('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'dii_pct', label: 'DII', unit: '%', cat: 'OWNERSHIP', term: 'dii holding', choices: [('≥ 5', true, 5), ('≥ 15', true, 15), ('≥ 25', true, 25)]),
  (col: 'public_pct', label: 'PUBLIC', unit: '%', cat: 'OWNERSHIP', term: 'public holding', choices: [('≥ 10', true, 10), ('≥ 25', true, 25), ('≥ 50', true, 50)]),
  (col: 'promoter_chg_q', label: 'PROMOTER CHG Q', unit: ' pt', cat: 'OWNERSHIP', term: 'promoter holding', choices: [('≥ 0', true, 0), ('≥ 1', true, 1), ('≤ -1', false, -1)]),
  (col: 'fii_chg_q', label: 'FII CHG Q', unit: ' pt', cat: 'OWNERSHIP', term: 'fii holding', choices: [('≥ 0', true, 0), ('≥ 1', true, 1), ('≤ -1', false, -1)]),
  (col: 'n_holders', label: 'SHAREHOLDERS', unit: '', cat: 'OWNERSHIP', term: 'shareholders', choices: [('≥ 10000', true, 10000), ('≥ 100000', true, 100000), ('≥ 1000000', true, 1000000)]),
  // ---- 033 close-series / tape-derived ----
  (col: 'vol_30d', label: 'VOLATILITY 30D', unit: '%', cat: 'RISK', term: 'volatility', choices: [('≤ 20', false, 20), ('≤ 30', false, 30), ('≤ 50', false, 50)]),
  (col: 'vol_1y', label: 'VOLATILITY 1Y', unit: '%', cat: 'RISK', term: 'volatility', choices: [('≤ 20', false, 20), ('≤ 30', false, 30), ('≤ 50', false, 50)]),
  (col: 'max_dd_1y', label: 'MAX DRAWDOWN 1Y', unit: '%', cat: 'RISK', term: 'max drawdown', choices: [('≤ -10', false, -10), ('≤ -20', false, -20), ('≤ -40', false, -40)]),
  (col: 'up_days_pct_1y', label: 'UP DAYS 1Y', unit: '%', cat: 'TECHNICALS', term: 'up days', choices: [('≥ 45', true, 45), ('≥ 50', true, 50), ('≥ 55', true, 55)]),
  (col: 'corr_nifty_1y', label: 'CORR NIFTY', unit: '', cat: 'RISK', term: 'correlation', choices: [('≤ 0.3', false, 0.3), ('≤ 0.5', false, 0.5), ('≤ 0.7', false, 0.7)]),
  (col: 'days_since_hi52', label: 'DAYS SINCE 52W HI', unit: '', cat: 'TECHNICALS', term: '52-week high', choices: [('≤ 5', false, 5), ('≤ 20', false, 20), ('≤ 60', false, 60)]),
  (col: 'days_since_lo52', label: 'DAYS SINCE 52W LO', unit: '', cat: 'TECHNICALS', term: '52-week low', choices: [('≤ 5', false, 5), ('≤ 20', false, 20), ('≤ 60', false, 60)]),
  (col: 'macd_hist', label: 'MACD HIST', unit: '', cat: 'TECHNICALS', term: 'macd', choices: [('≥ 0', true, 0), ('≥ 1', true, 1), ('≤ -1', false, -1)]),
  (col: 'deliv_pct_last', label: 'DELIVERY %', unit: '%', cat: 'PRICE & VOLUME', term: 'delivery', choices: [('≥ 30', true, 30), ('≥ 50', true, 50), ('≥ 70', true, 70)]),
  (col: 'deliv_pct_avg22', label: 'DELIVERY % AVG', unit: '%', cat: 'PRICE & VOLUME', term: 'delivery', choices: [('≥ 30', true, 30), ('≥ 50', true, 50), ('≥ 70', true, 70)]),
  (col: 'deliv_vs_avg', label: 'DELIVERY VS AVG', unit: '×', cat: 'PRICE & VOLUME', term: 'delivery', choices: [('≥ 1', true, 1), ('≥ 1.5', true, 1.5), ('≥ 2', true, 2)]),
  (col: 'turnover_avg22_cr', label: 'TURNOVER AVG', unit: ' CR', cat: 'PRICE & VOLUME', term: 'turnover', choices: [('≥ 1', true, 1), ('≥ 10', true, 10), ('≥ 100', true, 100)]),
  (col: 'trades_avg22', label: 'TRADES AVG', unit: '', cat: 'PRICE & VOLUME', term: 'trades', choices: [('≥ 1000', true, 1000), ('≥ 10000', true, 10000), ('≥ 100000', true, 100000)]),
];

/// ADD FILTER groups, in display order.
const metricCats = ['PRICE & VOLUME', 'RETURNS', 'VALUATION', 'PROFITABILITY', 'GROWTH', 'BALANCE SHEET', 'CASH FLOW', 'DIVIDENDS', 'OWNERSHIP', 'TECHNICALS', 'RISK', 'SIZE & SECTOR'];

/// low-is-good columns rank ascending when chosen as the sort.
const lowIsGood = {'beta_1y', 'ccc_days', 'corr_nifty_1y', 'days_since_hi52', 'days_since_lo52', 'de', 'debt_cr', 'debt_ebitda', 'debt_fcf', 'debtor_days', 'dep_cr', 'dist_hi52', 'ev_ebit', 'ev_ebitda', 'ev_fcf', 'ev_sales', 'fwd_pe', 'int_cr', 'inventory_days', 'nd_ebitda', 'other_income_pct', 'p_ebitda', 'p_fcf', 'p_ocf', 'p_tbv', 'pb', 'pe', 'pe_avg_3y', 'pe_avg_5y', 'peg', 'ps', 'rsi_m', 'rsi_w', 'shares_qoq', 'shares_yoy', 'tax_pct', 'vol_1y', 'vol_30d', 'wacc', 'wc_days'};

const List<ScreenPreset> screenPresets = [
  (
    name: 'VALUE',
    sortCol: 'pe',
    asc: true,
    filters: [
      (metric: 'pe', gte: false, value: 15.0),
      (metric: 'roe', gte: true, value: 15.0),
      (metric: 'de', gte: false, value: 0.5),
      (metric: 'mcap_cr', gte: true, value: 500.0)
    ]
  ),
  (
    name: 'COMPOUNDERS',
    sortCol: 'profit_cagr_5y',
    asc: false,
    filters: [
      (metric: 'roe', gte: true, value: 20.0),
      (metric: 'roce', gte: true, value: 20.0),
      (metric: 'profit_cagr_5y', gte: true, value: 15.0),
      (metric: 'de', gte: false, value: 0.3)
    ]
  ),
  (
    name: 'DIVIDEND',
    sortCol: 'div_yield',
    asc: false,
    filters: [
      (metric: 'div_yield', gte: true, value: 3.0),
      (metric: 'roe', gte: true, value: 12.0),
      (metric: 'de', gte: false, value: 1.0)
    ]
  ),
  (
    name: 'GROWTH',
    sortCol: 'profit_cagr_3y',
    asc: false,
    filters: [
      (metric: 'sales_cagr_3y', gte: true, value: 15.0),
      (metric: 'profit_cagr_3y', gte: true, value: 20.0),
      (metric: 'pe', gte: false, value: 30.0)
    ]
  ),
  (
    name: 'DEBT-FREE SMALLCAP',
    sortCol: 'roe',
    asc: false,
    filters: [
      (metric: 'de', gte: false, value: 0.1),
      (metric: 'mcap_cr', gte: true, value: 300.0),
      (metric: 'mcap_cr', gte: false, value: 5000.0),
      (metric: 'roe', gte: true, value: 15.0)
    ]
  ),
  (
    name: 'PROMOTER HEAVY',
    sortCol: 'mcap_cr',
    asc: false,
    filters: [
      (metric: 'promoter_pct', gte: true, value: 60.0),
      (metric: 'roe', gte: true, value: 15.0),
      (metric: 'pe', gte: false, value: 25.0)
    ]
  ),
];

/// Plain-words line per preset — what the screen hunts, for readers the pill
/// names alone don't reach. The filter pills below it spell the exact cuts.
const presetBlurbs = {
  'VALUE': 'cheap earnings · solid returns · low debt',
  'COMPOUNDERS': 'high ROE/ROCE, profits compounding for 5 years',
  'DIVIDEND': 'pays ≥3% yield without wrecking the balance sheet',
  'GROWTH': 'sales and profits accelerating, P/E still sane',
  'DEBT-FREE SMALLCAP': 'small companies, near-zero debt, real returns',
  'PROMOTER HEAVY': 'founders own ≥60% — skin in the game',
};

// ---------- saved screens (SharedPreferences, same pattern as feed filters) ----------

typedef SavedScreen = ({
  String name,
  List<ScreenFilter> filters,
  String sortCol,
  bool asc
});

String encodeScreen(SavedScreen s) => jsonEncode({
      'name': s.name,
      'filters': [
        for (final f in s.filters)
          {'metric': f.metric, 'gte': f.gte, 'value': f.value}
      ],
      'sortCol': s.sortCol,
      'asc': s.asc,
    });

SavedScreen? decodeScreen(String raw) {
  try {
    final j = jsonDecode(raw) as Map;
    return (
      name: j['name'] as String,
      filters: [
        for (final f in j['filters'] as List)
          (
            metric: f['metric'] as String,
            gte: f['gte'] as bool,
            value: (f['value'] as num).toDouble()
          )
      ],
      sortCol: j['sortCol'] as String,
      asc: j['asc'] as bool,
    );
  } catch (_) {
    return null;
  }
}

Future<List<SavedScreen>> loadSavedScreens() async {
  final prefs = await SharedPreferences.getInstance();
  return [
    for (final raw in prefs.getStringList('saved_screens') ?? const [])
      if (decodeScreen(raw) != null) decodeScreen(raw)!
  ];
}

Future<void> persistSavedScreens(List<SavedScreen> screens) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
      'saved_screens', [for (final s in screens) encodeScreen(s)]);
}

/// Phase C (030): the account's screens, merged over the local cache (cloud
/// wins on the same name), cache refreshed. Any failure → the local list.
Future<List<SavedScreen>> syncSavedScreens() async {
  final local = await loadSavedScreens();
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return local;
  try {
    final rows = await Supabase.instance.client
        .from('user_screens')
        .select('name,filters,sort_col,sort_asc')
        .eq('user_id', uid);
    final cloud = <String, SavedScreen>{
      for (final r in rows)
        '${r['name']}': (
          name: '${r['name']}',
          filters: [
            for (final f in (r['filters'] as List? ?? const []))
              (metric: '${f['metric']}', gte: f['gte'] == true, value: (f['value'] as num).toDouble())
          ],
          sortCol: '${r['sort_col'] ?? 'mcap_cr'}',
          asc: r['sort_asc'] == true,
        )
    };
    final merged = [
      for (final s in local)
        if (!cloud.containsKey(s.name)) s,
      ...cloud.values,
    ];
    // local-only screens (saved before 030 / offline) go up now
    for (final s in local) {
      if (!cloud.containsKey(s.name)) await cloudSaveScreen(s);
    }
    await persistSavedScreens(merged);
    return merged;
  } catch (_) {
    return local;
  }
}

Future<void> cloudSaveScreen(SavedScreen s) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  await Supabase.instance.client.from('user_screens').upsert({
    'user_id': uid,
    'name': s.name,
    'query': screenQueryText(s.filters),
    'filters': [
      for (final f in s.filters) {'metric': f.metric, 'gte': f.gte, 'value': f.value}
    ],
    'sort_col': s.sortCol,
    'sort_asc': s.asc,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  });
}

Future<void> cloudDeleteScreen(String name) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return;
  await Supabase.instance.client.from('user_screens').delete().match({'user_id': uid, 'name': name});
}

MetricDef _def(String col) => metricDefs.firstWhere((m) => m.col == col);

String _trim(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

String filterLabel(ScreenFilter f) {
  final d = _def(f.metric);
  return '${d.label} ${f.gte ? '≥' : '≤'} ${_trim(f.value)}${d.unit}'
      .trimRight();
}

/// 'PE 14.2' · 'ROE 22%' · 'MCAP 2,800 CR' — the result-row trail bits.
String metricText(String col, num? v) {
  if (v == null) return '';
  final d = _def(col);
  final s = const {'mcap_cr', 'avg_vol', 'turnover_cr'}.contains(col)
      ? fmtNum(v.toDouble(), decimals: 0)
      : (v.toDouble() == v.roundToDouble()
          ? '${v.round()}'
          : v.toDouble().toStringAsFixed(1));
  return '${d.label} $s${d.unit}';
}

/// Pure render half — takes rows directly so tests feed data (MarketsBody
/// pattern). The screen around it owns state and queries.
class ScreensBody extends StatelessWidget {
  const ScreensBody(this.rows,
      {super.key,
      required this.filters,
      required this.sortCol,
      required this.onRemoveFilter,
      this.onAddFilter,
      this.onSort,
      this.onSave,
      this.onTapRow,
      this.savedNames = const [],
      this.onLoadSaved,
      this.onDeleteSaved,
      this.updatedAt,
      this.blurb,
      this.queryController,
      this.queryError,
      this.onRunQuery,
      this.onCopyQuery,
      this.onMore});
  final List<Map<String, dynamic>> rows;
  final List<ScreenFilter> filters;
  final String sortCol;
  final void Function(ScreenFilter) onRemoveFilter;
  final VoidCallback? onAddFilter;
  final VoidCallback? onSort;
  final VoidCallback? onSave;
  final void Function(String symbol)? onTapRow;
  final List<String> savedNames;
  final void Function(int index)? onLoadSaved;
  final void Function(int index)? onDeleteSaved; // long-press a saved chip
  final DateTime? updatedAt;

  /// Phase C: the formula bar. Null hides it (preset pages, tests).
  final TextEditingController? queryController;
  final String? queryError;
  final VoidCallback? onRunQuery, onCopyQuery;

  /// Non-null when a further page of results exists.
  final VoidCallback? onMore;

  /// One plain-words line under a preset's title — what this screen hunts.
  final String? blurb;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (blurb != null) ...[
        Text(blurb!, style: mono.copyWith(fontSize: 10.5, color: inkDim)),
        const SizedBox(height: 12),
      ],
      if (queryController != null && onRunQuery != null) ...[
        Text('FORMULA', style: mono.copyWith(fontSize: 10, color: inkDim)),
        const SizedBox(height: 6),
        TextField(
          key: const Key('screenQuery'),
          controller: queryController,
          minLines: 1,
          maxLines: 3,
          style: mono.copyWith(fontSize: 12),
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => onRunQuery!(),
          decoration: InputDecoration(
              isDense: true,
              hintText: 'e.g. ${screenQueryExamples.first}',
              hintStyle: mono.copyWith(fontSize: 11, color: inkDim),
              suffixIcon: IconButton(
                  tooltip: 'Run',
                  icon: const Icon(Icons.play_arrow_rounded, color: green),
                  onPressed: onRunQuery)),
        ),
        if (queryError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(queryError!, style: mono.copyWith(fontSize: 10, color: red)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('metric > number, joined with AND · > and < mean at least / at most',
                style: mono.copyWith(fontSize: 9.5, color: inkDim)),
          ),
        const SizedBox(height: 10),
      ],
      if (savedNames.isNotEmpty && onLoadSaved != null) ...[
        Text('SAVED${onDeleteSaved == null ? '' : ' · hold to delete'}',
            style: mono.copyWith(fontSize: 10, color: inkDim)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < savedNames.length; i++)
            GestureDetector(
              onLongPress: onDeleteSaved == null ? null : () => onDeleteSaved!(i),
              child: filterPill(savedNames[i], false, inkDim, () => onLoadSaved!(i),
                  fontSize: 10),
            ),
        ]),
        const SizedBox(height: 10),
      ],
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final f in filters)
          filterPill(filterLabel(f), true, green, () => onRemoveFilter(f),
              fontSize: 10),
        if (onAddFilter != null)
          filterPill('+ FILTER', false, green, onAddFilter!, fontSize: 10),
        if (onSort != null)
          filterPill('SORT · ${_def(sortCol).label}', false, amber, onSort!,
              fontSize: 10),
        if (onSave != null && filters.isNotEmpty)
          filterPill('SAVE', false, inkDim, onSave!, fontSize: 10),
        if (onCopyQuery != null && filters.isNotEmpty)
          filterPill('COPY', false, inkDim, onCopyQuery!, fontSize: 10),
      ]),
      const SizedBox(height: 14),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text('No matches — loosen a filter.',
              style: mono.copyWith(fontSize: 13)),
        )
      else ...[
        for (final r in rows)
          InkWell(
            onTap: onTapRow == null ? null : () => onTapRow!('${r['symbol']}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(children: [
                SizedBox(
                    width: 86,
                    child: Text('${r['symbol']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 11))),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['name'] ?? r['symbol']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: ink,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        Text(
                            [
                              if (r['price'] != null)
                                '₹${fmtNum((r['price'] as num).toDouble())}',
                              metricText(sortCol, r[sortCol] as num?),
                              for (final f in filters)
                                if (f.metric != sortCol)
                                  metricText(f.metric, r[f.metric] as num?),
                            ].where((s) => s.isNotEmpty).take(3).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mono.copyWith(fontSize: 10)),
                      ]),
                ),
              ]),
            ),
          ),
        if (onMore != null)
          TextButton(
              onPressed: onMore,
              child: Text('show 50 more', style: mono.copyWith(fontSize: 12, color: green))),
        const SizedBox(height: 10),
        Text(
            '${rows.length} matches'
            '${onMore != null ? ' so far' : ''}'
            '${updatedAt != null ? ' · metrics as of ${fmtDayShort(updatedAt!)}' : ''}'
            ' · rebuilt daily',
            style: mono.copyWith(fontSize: 10)),
      ],
    ]);
  }
}

String fmtDayShort(DateTime t) {
  const m = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${ist.day} ${m[ist.month - 1]}';
}

class ScreensScreen extends StatefulWidget {
  const ScreensScreen({super.key, this.preset});
  final ScreenPreset? preset;

  @override
  State<ScreensScreen> createState() => _ScreensScreenState();
}

class _ScreensScreenState extends State<ScreensScreen> {
  late List<ScreenFilter> _filters =
      List.of(widget.preset?.filters ?? const <ScreenFilter>[]);
  late String _sortCol = widget.preset?.sortCol ?? 'mcap_cr';
  late bool _asc = widget.preset?.asc ?? false;
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  bool _failed = false;
  bool _hasMore = false;
  List<SavedScreen> _saved = const [];
  // Phase C: the typed formula. Pills regenerate it; RUN parses it into pills.
  late final TextEditingController _query =
      TextEditingController(text: screenQueryText(_filters));
  String? _queryError;

  @override
  void initState() {
    super.initState();
    _run();
    if (widget.preset == null) {
      syncSavedScreens().then((s) {
        if (mounted) setState(() => _saved = s);
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _setFilters(List<ScreenFilter> next) {
    setState(() {
      _filters = next;
      _query.text = screenQueryText(next);
      _queryError = null;
    });
    _run();
  }

  void _runQuery() {
    final p = parseScreenQuery(_query.text);
    if (p.error != null) {
      setState(() => _queryError = p.error);
      return;
    }
    setState(() {
      _filters = p.filters;
      _queryError = null;
    });
    _run();
  }

  Future<void> _copyQuery() async {
    final text = _query.text.trim().isEmpty ? screenQueryText(_filters) : _query.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Formula copied')));
    }
  }

  Future<void> _deleteSaved(int i) async {
    final s = _saved[i];
    final next = [..._saved.where((x) => x.name != s.name)];
    await persistSavedScreens(next);
    if (mounted) setState(() => _saved = next);
    cloudDeleteScreen(s.name).then((_) {}, onError: (_) {});
  }

  Future<void> _save() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(),
        title: Text('SAVE SCREEN', style: mono.copyWith(fontSize: 12)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: mono.copyWith(fontSize: 13),
          decoration: InputDecoration(
              hintText: 'name…',
              hintStyle: mono.copyWith(fontSize: 12, color: inkDim)),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctl.text),
              child: Text('SAVE', style: mono.copyWith(color: green))),
        ],
      ),
    );
    final trimmed = (name ?? '').trim().toUpperCase();
    if (trimmed.isEmpty) return;
    final next = [
      ..._saved.where((s) => s.name != trimmed),
      (name: trimmed, filters: List.of(_filters), sortCol: _sortCol, asc: _asc),
    ];
    await persistSavedScreens(next);
    if (mounted) setState(() => _saved = next);
    cloudSaveScreen(next.last).then((_) {}, onError: (_) {});
  }

  void _loadSaved(int i) {
    final s = _saved[i];
    setState(() {
      _sortCol = s.sortCol;
      _asc = s.asc;
    });
    _setFilters(List.of(s.filters));
  }

  static const _page = 50;

  Future<void> _run({bool more = false}) async {
    final start = more ? _rows.length : 0;
    setState(() {
      if (!more) _loading = true;
      _failed = false;
    });
    try {
      // explicit projection: only what the row renders (sort + filter
      // metrics) — 170 columns x 50 rows would be a 60 KB page (033)
      final cols = {_sortCol, for (final f in _filters) f.metric};
      var q = Supabase.instance.client.from('screener_metrics').select(
          'symbol,name,price,updated_at,${cols.join(',')}');
      for (final f in _filters) {
        q = f.gte ? q.gte(f.metric, f.value) : q.lte(f.metric, f.value);
      }
      final rows = await q
          .order(_sortCol, ascending: _asc)
          .range(start, start + _page - 1)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final fresh = [for (final r in rows) Map<String, dynamic>.from(r)];
      setState(() {
        _rows = more ? [..._rows, ...fresh] : fresh;
        _hasMore = fresh.length == _page;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  /// 033: ~170 metrics read as 12 category pills, one category open at a time.
  void _addFilter() {
    var cat = _lastCat;
    showPillSheet(
      context,
      'ADD FILTER',
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            pillRow([
              for (final c in metricCats)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: filterPill(c, c == cat, amber, () {
                    _lastCat = c;
                    setSheet(() => cat = c);
                  }),
                ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in metricDefs)
                if (m.cat == cat)
                  filterPill(m.label, false, green, () {
                    Navigator.of(ctx).pop();
                    _thresholdSheet(m);
                  }),
            ]),
          ],
        ),
      ),
    );
  }

  String _lastCat = metricCats[2]; // VALUATION opens first

  void _thresholdSheet(MetricDef m) {
            showPillSheet(
              context,
              m.label,
              (ctx2) {
                void apply(bool gte, double value) {
                  Navigator.of(ctx2).pop();
                  _setFilters([
                    ..._filters.where((f) => f.metric != m.col || f.gte != gte),
                    (metric: m.col, gte: gte, value: value),
                  ]);
                }

                final ctl = TextEditingController();
                return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: filterPill('WHAT IS ${m.label}?', false, inkDim,
                            () => showDefineSheet(context, m.term)),
                      ),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final (label, gte, value) in m.choices)
                          filterPill(label, false, green,
                              () => apply(gte, value.toDouble())),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: ctl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true, signed: true),
                            style: mono.copyWith(fontSize: 13),
                            decoration: InputDecoration(
                                isDense: true,
                                hintText: 'custom…',
                                hintStyle:
                                    mono.copyWith(fontSize: 12, color: inkDim)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        for (final (label, gte) in const [
                          ('≥', true),
                          ('≤', false)
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: filterPill(label, false, amber, () {
                              final v = double.tryParse(ctl.text.trim());
                              if (v != null) apply(gte, v);
                            }),
                          ),
                      ]),
                    ]);
              },
            );
  }

  void _pickSort() {
    showPillSheet(
      context,
      'SORT BY',
      (ctx) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in metricDefs)
          filterPill(m.label, m.col == _sortCol, amber, () {
            Navigator.of(ctx).pop();
            setState(() {
              // low-is-good columns rank ascending, the rest descending
              _asc = lowIsGood.contains(m.col);
              _sortCol = m.col;
            });
            _run();
          }),
      ]),
    );
  }

  Future<void> _openStock(String symbol) async {
    try {
      final row = await Supabase.instance.client
          .from('companies')
          .select('id,name,nse_symbol')
          .eq('nse_symbol', symbol)
          .maybeSingle();
      if (row == null || !mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => StockScreen(
              company: Company.fromJson(Map<String, dynamic>.from(row)))));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final stamp = _rows.isEmpty
        ? null
        : DateTime.tryParse('${_rows.first['updated_at'] ?? ''}');
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(widget.preset?.name ?? 'SCREENS',
            style: serif.copyWith(fontSize: 18)),
      ),
      body: _loading
          ? Center(child: appSpinner())
          : _failed
              ? Center(
                  child: GestureDetector(
                    onTap: _run,
                    child: Text('Could not run the screen — tap to retry',
                        style: mono.copyWith(fontSize: 13)),
                  ),
                )
              : ScreensBody(_rows,
                  filters: _filters,
                  sortCol: _sortCol,
                  updatedAt: stamp,
                  blurb: presetBlurbs[widget.preset?.name],
                  savedNames: [for (final s in _saved) s.name],
                  onLoadSaved: _saved.isEmpty ? null : _loadSaved,
                  onDeleteSaved: _saved.isEmpty ? null : _deleteSaved,
                  onRemoveFilter: (f) =>
                      _setFilters([..._filters.where((x) => x != f)]),
                  onAddFilter: _addFilter,
                  onSort: _pickSort,
                  onSave: widget.preset == null ? _save : null,
                  onTapRow: _openStock,
                  queryController: _query,
                  queryError: _queryError,
                  onRunQuery: _runQuery,
                  onCopyQuery: _copyQuery,
                  onMore: _hasMore ? () => _run(more: true) : null),
    );
  }
}
