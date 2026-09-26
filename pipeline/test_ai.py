"""ai.py pacing + concall summariser: no network. Run: cd pipeline && py -3 -m pytest test_ai.py"""
import json

import pytest

import ai


def test_hourly_pace_gate_blocks_past_the_cap(monkeypatch):
    monkeypatch.setattr(ai, "AI_CALLS_PER_HOUR", 3)
    ai._recent.clear()
    for _ in range(3):
        ai._pace()
    with pytest.raises(ai.QuotaExhausted):
        ai._pace()
    # an hour later the window has drained and calls flow again
    for i in range(len(ai._recent)):
        ai._recent[i] -= 3601
    ai._pace()
    assert len(ai._recent) == 1


def test_summarise_transcript_shapes_and_caps(monkeypatch):
    seen = {}

    def fake_gemini(prompt):
        seen["prompt"] = prompt
        return json.dumps({"summary": "Solid quarter.", "guidance": ["rev +12%"] * 9,
                           "risks": [], "qa_highlights": ["Q: capex? A: 5k cr"], "sentiment": "confident"})

    monkeypatch.setattr(ai, "_gemini", fake_gemini)
    out = ai.summarise_transcript("x" * 50000)
    assert out["summary"] == "Solid quarter." and len(out["guidance"]) == 6
    assert out["sentiment"] == "confident" and out["qa_highlights"] == ["Q: capex? A: 5k cr"]
    assert len(seen["prompt"]) < ai.CONCALL_CHARS + len(ai.CONCALL_PROMPT)


def test_summarise_transcript_rejects_empty(monkeypatch):
    monkeypatch.setattr(ai, "_gemini", lambda p: json.dumps({"summary": ""}))
    with pytest.raises(ai.AIError):
        ai.summarise_transcript("t")
