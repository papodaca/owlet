"""Owlet.Document via owlet-document-cli: KTD-8 acceptance rules + segmentation.

The CLI's stdout contract (status line, sentence count, one "[i] text"
line per segment) is the test surface — the app and these tests run
the identical Owlet.Document.load path.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "document"

# Kept in sync with Owlet.Document.MAX_SEGMENT_CHARS.
MAX_SEGMENT_CHARS = 300


def load_document(document_cli: Path, path: Path):
    result = subprocess.run(
        [str(document_cli), str(path)],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    lines = result.stdout.splitlines()
    assert len(lines) >= 2, f"missing stdout header: {result.stdout!r}"
    assert lines[0].startswith("status: "), lines[0]
    status = lines[0][len("status: ") :]
    assert lines[1].startswith("sentences: "), lines[1]
    count = int(lines[1][len("sentences: ") :])
    sentences = []
    for line in lines[2:]:
        m = re.fullmatch(r"\[(\d+)\] (.*)", line)
        assert m, f"malformed sentence line: {line!r}"
        assert int(m.group(1)) == len(sentences)
        sentences.append(m.group(2))
    assert len(sentences) == count, (count, sentences)
    return result.returncode, status, sentences, result.stderr


def test_utf8_bom_stripped_on_load(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "utf8bom.txt")
    assert (rc, status) == (0, "ok")
    assert sentences == [
        "First sentence with BOM.",
        "Second one.",
    ]


def test_plain_utf8_sentences(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "utf8.txt")
    assert (rc, status) == (0, "ok")
    assert sentences == [
        "First sentence here.",
        "Second sentence!",
        "A new paragraph begins.",
        "Does it work?",
        # "…" is a sentence terminator; a mid-sentence ellipsis is a
        # v1 false split by design (verbatim segmentation).
        "Yes…",
        "indeed.",
        "Last line without terminator",
    ]


def test_markdown_fenced_block_verbatim(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "fenced.md")
    assert (rc, status) == (0, "ok")
    # KTD-4: the fence is read verbatim; its content is present in a
    # segment (single newlines collapse into spaces).
    assert sentences == [
        "# Birds of Owlet",
        "Owlets are small owls.",
        "They hunt at night.",
        '```python def hoot(): return "hoot" ```',
        "The code above sings.",
        "The end.",
    ]


def test_abbreviations_never_split_mid_sentence(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "abbreviations.txt")
    assert (rc, status) == (0, "ok")
    assert sentences == [
        "Dr. Smith met Mr. Jones at St. Patrick's.",
        "They discussed Prof. Lee's fig. tree vs. mine, i.e. yours.",
        "The end.",
        "MR. BEAN went home.",
        # "etc." never ends a sentence (accepted false merge per plan).
        "We bought pens, paper, etc. Then we left.",
        "It was, e.g., red.",
        "And blue.",
        # "p." behaves like an initial (single letter + period).
        "See p. 12.",
        "Then stop.",
        # Possessive apostrophes still split correctly.
        "James's book fell.",
        "It hit the floor.",
    ]


def test_numbers_never_split_mid_sentence(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "numbers.txt")
    assert (rc, status) == (0, "ok")
    assert sentences == [
        "The value is 3.5 and pi is 3.14.",
        "It costs $1,000.50.",
        "Done.",
        "See section 2.",
        "It continues.",
    ]


def test_urls_never_split_mid_sentence(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "urls.txt")
    assert (rc, status) == (0, "ok")
    assert sentences == [
        "Dr. Smith paid $3.50 at acme.com.",
        "Visit https://example.com/docs for details.",
        "It loads fast.",
        "www.example.org is short.",
    ]


def test_crlf_line_endings_normalized(document_cli, tmp_path):
    path = tmp_path / "crlf.txt"
    path.write_bytes(b"Line one.\r\nLine two.\r\n\r\nLine three.\r\n")
    rc, status, sentences, _ = load_document(document_cli, path)
    assert (rc, status) == (0, "ok")
    assert sentences == ["Line one.", "Line two.", "Line three."]


def test_empty_file_is_empty(document_cli):
    rc, status, sentences, stderr = load_document(document_cli, FIXTURES / "empty.txt")
    assert (rc, status) == (0, "empty")
    assert sentences == []
    assert stderr == ""


def test_whitespace_only_is_empty(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "whitespace.txt")
    assert (rc, status) == (0, "empty")
    assert sentences == []


def test_nul_bytes_are_not_text(document_cli):
    rc, status, sentences, stderr = load_document(document_cli, FIXTURES / "binary.bin")
    assert (rc, status) == (3, "not-text")
    assert sentences == []
    assert stderr != ""


def test_latin1_without_bom_is_not_text(document_cli, tmp_path):
    # Tested both against fixture and dynamically written bytes
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "latin1.txt")
    assert (rc, status) == (3, "not-text")
    assert sentences == []

    dynamic = tmp_path / "latin1_dyn.txt"
    dynamic.write_bytes(b"Caf\xe9 au lait.\nSee you.\n")
    rc2, status2, sentences2, _ = load_document(document_cli, dynamic)
    assert (rc2, status2) == (3, "not-text")
    assert sentences2 == []


def test_utf16le_bom_is_unsupported_encoding(document_cli):
    rc, status, sentences, stderr = load_document(document_cli, FIXTURES / "utf16le.txt")
    assert (rc, status) == (4, "unsupported-encoding")
    assert sentences == []
    assert stderr != ""


def test_utf16be_bom_is_unsupported_encoding(document_cli):
    rc, status, sentences, stderr = load_document(document_cli, FIXTURES / "utf16be.txt")
    assert (rc, status) == (4, "unsupported-encoding")
    assert sentences == []
    assert stderr != ""


def test_utf32le_bom_is_unsupported_encoding(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "utf32le.txt")
    assert (rc, status) == (4, "unsupported-encoding")
    assert sentences == []


def test_utf32be_bom_is_unsupported_encoding(document_cli):
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "utf32be.txt")
    assert (rc, status) == (4, "unsupported-encoding")
    assert sentences == []


def test_missing_path_is_io_error(document_cli, tmp_path):
    rc, status, sentences, stderr = load_document(
        document_cli, tmp_path / "does-not-exist.txt"
    )
    assert (rc, status) == (5, "io-error")
    assert sentences == []
    assert stderr != ""


def test_long_paragraph_split_at_word_boundaries(document_cli):
    raw = (FIXTURES / "long-paragraph.txt").read_text(encoding="utf-8").strip()
    assert len(raw) > MAX_SEGMENT_CHARS * 3
    rc, status, sentences, _ = load_document(document_cli, FIXTURES / "long-paragraph.txt")
    assert (rc, status) == (0, "ok")
    assert len(sentences) >= 3
    for s in sentences:
        assert len(s) <= MAX_SEGMENT_CHARS, f"over budget ({len(s)}): {s[:50]}…"
    # No content lost: the segment stream reassembles the paragraph.
    assert " ".join(sentences) == raw


def test_budget_hard_cut_without_spaces(document_cli, tmp_path):
    token = "a" * 350
    path = tmp_path / "spaceless.txt"
    path.write_text(token, encoding="utf-8")
    rc, status, sentences, _ = load_document(document_cli, path)
    assert (rc, status) == (0, "ok")
    assert len(sentences) == 2
    assert sentences == ["a" * 300, "a" * 50]


def test_budget_multibyte_utf8(document_cli, tmp_path):
    # 'é' is 2 bytes in UTF-8; ensure segment budget counts unichars, not bytes.
    # 10 words of 35 'é's separated by spaces = 350 'é's + 9 spaces = 359 unichars (709 bytes).
    word = "é" * 35
    text = " ".join([word] * 10)
    path = tmp_path / "multibyte.txt"
    path.write_text(text, encoding="utf-8")
    rc, status, sentences, _ = load_document(document_cli, path)
    assert (rc, status) == (0, "ok")
    assert len(sentences) == 2
    for s in sentences:
        # Each segment must be <= 300 unichars
        assert len(s) <= MAX_SEGMENT_CHARS
    assert " ".join(sentences) == text


def test_multimegabyte_file_loads(document_cli, tmp_path):
    sentence = "The quick brown fox jumps over the lazy dog. "
    repeats = 30000  # ~1.35 MB
    path = tmp_path / "big.txt"
    path.write_text(sentence * repeats, encoding="utf-8")
    assert path.stat().st_size > 1_000_000
    rc, status, sentences, _ = load_document(document_cli, path)
    assert (rc, status) == (0, "ok")
    assert sentences == [sentence.strip()] * repeats
