"""Owlet.WordSpans via `owlet-document-cli estimate`: KTD1 character-weighted spans.

The estimator is pure (no engine, no GStreamer): it turns one display
sentence plus a measured PCM duration into the ordered word spans the
speech player clocks. The CLI's `estimate` stdout contract is the test
surface — the player calls the identical Owlet.WordSpans.estimate path.

    spans: N
    [0] START END T0 T1 TOKEN

START/END are GTK character offsets into the sentence (not UTF-8 bytes).
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import NamedTuple

import pytest

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "document"


class Span(NamedTuple):
    start: int
    end: int
    t0: float
    t1: float
    token: str

    @property
    def dt(self) -> float:
        return self.t1 - self.t0


def estimate(document_cli: Path, duration: str, text: str):
    result = subprocess.run(
        [str(document_cli), "estimate", duration, text],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if result.returncode != 0:
        return result.returncode, None, result.stdout, result.stderr

    lines = result.stdout.splitlines()
    assert lines and lines[0].startswith("spans: "), result.stdout
    count = int(lines[0][len("spans: ") :])
    spans = []
    for line in lines[1:]:
        m = re.fullmatch(r"\[(\d+)\] (\d+) (\d+) (\S+) (\S+) (.*)", line)
        assert m, f"malformed span line: {line!r}"
        assert int(m.group(1)) == len(spans)
        spans.append(
            Span(
                int(m.group(2)),
                int(m.group(3)),
                float(m.group(4)),
                float(m.group(5)),
                m.group(6),
            )
        )
    assert len(spans) == count, (count, spans)
    return result.returncode, spans, result.stdout, result.stderr


def test_path_mode_still_loads_a_document(document_cli):
    """`estimate` must not disturb the one-argument PATH contract."""
    result = subprocess.run(
        [str(document_cli), str(FIXTURES / "utf8.txt")],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines()[0] == "status: ok"


def test_bare_estimate_argument_is_still_a_path(document_cli):
    """argc 2 stays PATH: "estimate" is read as a (missing) file name."""
    result = subprocess.run(
        [str(document_cli), "estimate"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 5, result.stdout + result.stderr
    assert "status: io-error" in result.stdout
    assert "usage:" not in result.stderr


def test_estimate_without_text_is_usage(document_cli):
    result = subprocess.run(
        [str(document_cli), "estimate", "2.0"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert result.stderr.startswith("usage:") or "usage:" in result.stderr
    assert "spans:" not in result.stdout


def test_longer_word_gets_more_time_and_last_span_ends_at_duration(document_cli):
    rc, spans, out, _ = estimate(document_cli, "2.0", "Hi world")
    assert rc == 0, out
    assert len(spans) == 2
    assert [s.token for s in spans] == ["Hi", "world"]
    assert spans[0].dt < spans[1].dt
    assert spans[0].t0 == pytest.approx(0.0)
    assert spans[0].t1 == pytest.approx(spans[1].t0)
    # Last span absorbs the remainder, so the table matches the PCM exactly.
    assert spans[1].t1 == pytest.approx(2.0)


def test_trailing_punctuation_stays_on_its_token(document_cli):
    rc, spans, out, _ = estimate(document_cli, "1.0", "home,")
    assert rc == 0, out
    assert len(spans) == 1
    assert spans[0].token == "home,"
    assert (spans[0].start, spans[0].end) == (0, 5)


def test_punctuation_only_token_is_not_a_span(document_cli):
    rc, spans, out, _ = estimate(document_cli, "1.0", ",")
    assert rc == 0, out
    assert spans == []


def test_contraction_is_one_span(document_cli):
    rc, spans, out, _ = estimate(document_cli, "1.0", "can't")
    assert rc == 0, out
    assert len(spans) == 1
    assert (spans[0].start, spans[0].end) == (0, 5)
    assert spans[0].token == "can't"


def _token_start(document_cli: Path, offset: int, text: str):
    result = subprocess.run(
        [str(document_cli), "token-start", str(offset), text],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    line = result.stdout.strip()
    assert line.startswith("start: "), result.stdout
    return int(line[len("start: ") :])


def test_token_start_at_selected_word(document_cli):
    """Start from here slices from the selected word, not mid-token."""
    text = "one quick brown fox."
    # "quick" is [4, 9)
    assert _token_start(document_cli, 4, text) == 4
    assert _token_start(document_cli, 6, text) == 4
    assert _token_start(document_cli, 8, text) == 4
    # Whitespace before "quick" still starts at "quick".
    assert _token_start(document_cli, 3, text) == 4
    assert _token_start(document_cli, 0, text) == 0
    # Past the last token: empty slice, so playback can skip the sentence.
    assert _token_start(document_cli, len(text), text) == len(text)


def test_token_start_without_text_is_usage(document_cli):
    result = subprocess.run(
        [str(document_cli), "token-start", "0"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 2
    assert "usage:" in result.stderr


@pytest.mark.parametrize(
    "duration,text",
    [
        ("1.0", "   "),
        ("0", "Hello"),
        ("1.0", ""),
    ],
)
def test_no_spans_cases_exit_zero(document_cli, duration, text):
    rc, spans, out, _ = estimate(document_cli, duration, text)
    assert rc == 0, out
    assert spans == []
    assert out.splitlines() == ["spans: 0"]


def test_offsets_are_character_offsets_not_utf8_bytes(document_cli):
    rc, spans, out, _ = estimate(document_cli, "1.0", "Hi café")
    assert rc == 0, out
    assert len(spans) == 2
    assert spans[1].token == "café"
    # 'é' is two UTF-8 bytes; GTK character offsets must stay 3..7.
    assert (spans[1].start, spans[1].end) == (3, 7)


def test_token_without_letter_or_digit_grapheme_is_dropped(document_cli):
    rc, spans, out, _ = estimate(document_cli, "1.0", "Hi …")
    assert rc == 0, out
    assert len(spans) == 1
    assert spans[0].token == "Hi"
    assert spans[0].t1 == pytest.approx(1.0)


def test_spans_are_contiguous_and_ordered(document_cli):
    rc, spans, out, _ = estimate(
        document_cli, "3.5", "Dr. Smith paid $3.50 at acme.com."
    )
    assert rc == 0, out
    assert len(spans) == 6
    previous_end = -1
    for i, s in enumerate(spans):
        assert s.start > previous_end
        assert s.end > s.start
        previous_end = s.end
        assert s.t1 > s.t0
        if i:
            assert s.t0 == pytest.approx(spans[i - 1].t1)
    assert spans[-1].t1 == pytest.approx(3.5)
