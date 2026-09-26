"""corp_actions.py: pure checks. Run: cd pipeline && py -3 -m pytest test_corp_actions.py"""
from datetime import date

import pytest

import corp_actions as ca
from market import parse_nse_date

TODAY = date(2026, 9, 26)


@pytest.mark.parametrize("subject,kind,detail", [
    ("Dividend - Re 1 Per Share", "dividend", "₹1"),
    ("Interim Dividend - Rs 12.50 Per Share", "dividend", "₹12.5"),
    ("Bonus 1:1", "bonus", "1:1"),
    ("Bonus Issue 3:2", "bonus", "3:2"),
    ("Face Value Split (Sub-Division) - From Rs 10/- Per Share To Rs 2/- Per Share", "split", "₹10 → ₹2"),
    ("Rights 1:4 @ Premium Rs 45/- Per Share", "rights", "1:4"),
    ("Buyback of Shares", "buyback", None),
    ("Annual General Meeting", "agm", None),
    ("Extra Ordinary General Meeting", "egm", None),
    ("Something odd", "other", None),
    (None, "other", None),
])
def test_normalise(subject, kind, detail):
    assert ca.normalise(subject) == (kind, detail)


def test_shape_actions_window_dedupe_and_meetings():
    rows = [
        {"symbol": "BDL", "comp": "Bharat Dynamics", "subject": "Dividend - Re 0.40 Per Share",
         "exDate": "21-Sep-2026", "recDate": "21-Sep-2026", "series": "EQ"},
        {"symbol": "BDL", "comp": "Bharat Dynamics", "subject": "Dividend - Re 0.40 Per Share",
         "exDate": "21-Sep-2026", "recDate": "21-Sep-2026", "series": "EQ"},          # duplicate row
        {"symbol": "OLD", "comp": "Old", "subject": "Bonus 1:1", "exDate": "01-Jan-2026", "recDate": "-"},  # outside window
        {"symbol": "UNK", "comp": "Unknown", "subject": "Bonus 1:1", "exDate": "30-Sep-2026", "recDate": "-"},  # not known
        {"symbol": "TCS", "comp": "TCS", "subject": "Bonus 1:1", "exDate": "30-Sep-2026", "recDate": "01-Oct-2026"},
    ]
    meetings = [
        {"symbol": "TCS", "company": "TCS", "purpose": "Financial Results", "date": "09-Oct-2026"},
        {"symbol": "TCS", "company": "TCS", "purpose": "Financial Results", "date": "09-Oct-2026"},
        {"bm_symbol": "BDL", "sm_name": "BDL", "bm_purpose": "Fund Raising", "bm_date": "20-Sep-2026"},  # past
    ]
    blob = ca.shape_actions(rows, meetings, {"BDL", "TCS"}, TODAY, parse_nse_date)
    assert blob["asof"] == "2026-09-26"
    assert [(i["symbol"], i["kind"], i["detail"], i["ex"], i["rec"]) for i in blob["items"]] == [
        ("BDL", "dividend", "₹0.4", "2026-09-21", "2026-09-21"),
        ("TCS", "bonus", "1:1", "2026-09-30", "2026-10-01")]
    assert blob["meetings"] == [{"symbol": "TCS", "name": "TCS", "date": "2026-10-09", "purpose": "Financial Results"}]
    per = {r["symbol"]: r["actions"] for r in ca.per_symbol_rows(blob)}
    assert [a["kind"] for a in per["TCS"]] == ["bonus", "board_meeting"]
    assert per["BDL"][0]["ex"] == "2026-09-21" and "actions" in ca.per_symbol_rows(blob)[0]
