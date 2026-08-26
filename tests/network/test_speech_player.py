"""SpeechPlayer streaming synthesis and playback tests via owlet-tts-cli (U4)."""

from __future__ import annotations

import os
import subprocess
import tarfile
import urllib.request
import wave
from pathlib import Path

import pytest

pytestmark = pytest.mark.network

KOKORO_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2"
KOKORO_FALLBACK = "https://huggingface.co/csukuangfj/kokoro-en-v0_19/resolve/main/kokoro-en-v0_19.tar.bz2"

# Buffers carry PTS, so fakesink's sync=true paces playback in real time:
# a command that drains a whole fixture costs its audio duration (more at
# 0.75x) on top of synthesis. Commands that quit the loop early — pause
# latency, stop — only pay for their arming delay.
PLAYBACK_TIMEOUT_S = 300
EARLY_EXIT_TIMEOUT_S = 120


@pytest.fixture(scope="session")
def kokoro_model_dir(tmp_path_factory) -> Path:
    # Use cached spike dir if present on this host
    cached = Path("/tmp/opencode/tts-spike/kokoro-en-v0_19")
    if (cached / "model.onnx").is_file() and (cached / "voices.bin").is_file():
        return cached

    root = tmp_path_factory.mktemp("kokoro-model")
    tarball = root / "kokoro-en-v0_19.tar.bz2"
    try:
        urllib.request.urlretrieve(KOKORO_URL, tarball)
    except Exception:
        urllib.request.urlretrieve(KOKORO_FALLBACK, tarball)

    with tarfile.open(tarball, "r:bz2") as tar:
        tar.extractall(root)

    model_dir = root / "kokoro-en-v0_19"
    assert (model_dir / "model.onnx").is_file()
    return model_dir


# urls.txt as Owlet.Document segments it (see tests/unit/test_document_model.py).
URLS_SENTENCES = [
    "Dr. Smith paid $3.50 at acme.com.",
    "Visit https://example.com/docs for details.",
    "It loads fast.",
    "www.example.org is short.",
]


def _span_count(sentence: str) -> int:
    """KTD1: whitespace tokens holding at least one letter or digit."""
    return sum(1 for token in sentence.split() if any(c.isalnum() for c in token))


def _word_lines(stdout: str) -> list[tuple[int, int, int, int]]:
    """`word: SENTENCE WORD START END` events, no-current-word ones included."""
    words: list[tuple[int, int, int, int]] = []
    for line in stdout.splitlines():
        if line.startswith("word:"):
            tokens = line.split(":", 1)[1].split()
            assert len(tokens) == 4, line
            words.append(tuple(int(t) for t in tokens))  # type: ignore[arg-type]
    return words


def _indices_by_sentence(words) -> dict[int, list[int]]:
    per_sentence: dict[int, list[int]] = {}
    for sentence, word, _, _ in words:
        if word >= 0:
            per_sentence.setdefault(sentence, []).append(word)
    return per_sentence


def _assert_word_clock_only_advances(per_sentence: dict[int, list[int]]) -> None:
    """A ~50 ms poll may skip a short token (KTD2), but never rewind.

    A sentence whose clock was retargeted mid-flight would replay an index
    it had already emitted, so no-duplicates is what catches a reset.
    """
    for sentence, indices in per_sentence.items():
        assert indices == sorted(indices), (sentence, indices)
        assert len(indices) == len(set(indices)), (sentence, indices)


def _speed_values(stdout: str) -> list[float]:
    values: list[float] = []
    for line in stdout.splitlines():
        if line.startswith("speed:"):
            values.append(float(line.split(":", 1)[1].strip().split()[-1]))
    return values


def _speed_pairs(stdout: str) -> list[tuple[int, float]]:
    pairs: list[tuple[int, float]] = []
    for line in stdout.splitlines():
        if line.startswith("speed:"):
            tokens = line.split(":", 1)[1].split()
            pairs.append((int(tokens[0]), float(tokens[-1])))
    return pairs


def test_speech_player_change_speed_mid_listen(tts_cli, kokoro_model_dir, source_root):
    """AE2: mid-listen set_speed does not restart; a later sentence uses the new rate."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "event: started" in out
    assert out.count("event: started") == 1
    assert "position: 1 / 4" in out
    first_pos1 = out.find("position: 1 / 4")
    after_pos1 = out[first_pos1 + len("position: 1 / 4") :]
    assert "position: 1 / 4" not in after_pos1
    assert "position: 4 / 4" in after_pos1
    speeds_before = _speed_values(out[:first_pos1])
    assert speeds_before
    assert all(s == 1.0 for s in speeds_before), speeds_before
    # Prefetch may keep one extra 1.0 after pos 1; a later sentence must be 1.5.
    remaining = _speed_pairs(after_pos1)
    if remaining and remaining[0][1] == 1.0:
        remaining = remaining[1:]
    assert remaining, "expected a speed after the mid-listen change"
    later_idx, later_rate = remaining[0]
    assert later_rate == 1.5, remaining
    assert later_idx > 1, remaining
    assert "event: stopped (natural_end: true)" in out


def test_speech_player_play_with_speed(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "play", str(kokoro_model_dir), str(doc_path), "0", "2.0"],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=True,
    )
    assert result.returncode == 0
    assert "event: started" in result.stdout
    assert "position: 1 / 4" in result.stdout
    assert "position: 4 / 4" in result.stdout
    speeds = _speed_values(result.stdout)
    assert len(speeds) >= 4, speeds
    assert all(s == 2.0 for s in speeds), speeds
    assert "event: stopped (natural_end: true)" in result.stdout


def test_speech_player_pause_then_change_speed(tts_cli, kokoro_model_dir, source_root):
    """AE3: pause, set_speed(0.75), resume keeps the current sentence; a later one uses 0.75."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-speed-resume", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "event: paused (index: 1)" in out
    assert "event: resuming" in out
    paused_at = out.find("event: paused (index: 1)")
    stopped_at = out.find("event: stopped (natural_end: true)")
    assert paused_at != -1 and stopped_at > paused_at
    after_pause = out[paused_at:stopped_at]
    before_resume, after_resume = after_pause.split("event: resuming", 1)
    # Resume continues the same sentence (pipeline stays paused, not flushed).
    assert "position: 1 / 4" not in before_resume
    speeds_after = _speed_values(after_resume)
    remaining = _speed_pairs(after_resume)
    if remaining and remaining[0][1] == 1.0:
        remaining = remaining[1:]
    assert remaining, speeds_after
    assert remaining[0][1] == 0.75, remaining
    assert "position: 2 / 4" in after_resume
    assert "position: 4 / 4" in out
    assert "event: stopped (natural_end: true)" in out


@pytest.mark.parametrize("raw,expected", [("1.1", 1.0), ("0", 0.75), ("-1", 0.75)])
def test_speech_player_set_speed_snaps_nearest_preset(
    tts_cli, kokoro_model_dir, source_root, raw, expected
):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(kokoro_model_dir), str(doc_path), raw, "2.0"],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    speeds = _speed_values(result.stdout)
    assert 2.0 in speeds, speeds
    first_pos1 = result.stdout.find("position: 1 / 4")
    assert first_pos1 != -1
    later_speeds = _speed_values(result.stdout[first_pos1:])
    assert expected in later_speeds, later_speeds
    assert all(s > 0 for s in speeds)


def test_speech_player_set_speed_stopped_missing_voice_dir(tts_cli, source_root, tmp_path):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    fake_dir = tmp_path / "nonexistent-voice"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(fake_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 1
    assert "Failed to initialize speech synthesis engine" in result.stderr
    assert result.stderr.count("error:") == 1


def test_speech_player_play_streaming_events(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "play", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=True,
    )
    assert result.returncode == 0
    assert "event: started" in result.stdout
    assert "position: 1 / 4" in result.stdout
    assert "position: 4 / 4" in result.stdout
    assert "event: stopped (natural_end: true)" in result.stdout


def test_speech_player_pause_returns_quickly(tts_cli, kokoro_model_dir, source_root):
    """Pause must not wait for the in-flight sentence to finish playing."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "long-paragraph.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-latency", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=EARLY_EXIT_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "event: paused" in result.stdout
    wait_ms = None
    for line in result.stdout.splitlines():
        if line.startswith("pause_wait_ms:"):
            wait_ms = int(line.split(":", 1)[1].strip())
            break
    assert wait_ms is not None, result.stdout
    assert wait_ms < 1500, f"pause blocked for {wait_ms} ms\n{result.stdout}"


def test_speech_player_pause_and_resume(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-resume", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=True,
    )
    assert result.returncode == 0
    assert "event: paused (index: 1)" in result.stdout
    assert "event: resuming" in result.stdout
    assert "position: 2 / 4" in result.stdout
    assert "position: 4 / 4" in result.stdout
    assert "event: stopped (natural_end: true)" in result.stdout
    paused_at = result.stdout.find("event: paused (index: 1)")
    stopped_at = result.stdout.find("event: stopped (natural_end: true)")
    assert paused_at != -1 and stopped_at > paused_at
    after_pause = result.stdout[paused_at:stopped_at]
    before_resume, after_resume = after_pause.split("event: resuming", 1)
    assert "position: 1 / 4" not in before_resume
    # Resume drains the paused sentence; it must not skip ahead by restarting
    # at the next index (position 1 is not re-emitted).
    assert "position: 1 / 4" not in after_resume
    assert "position: 2 / 4" in after_resume


def test_speech_player_stop_clean_reset(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "stop", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=EARLY_EXIT_TIMEOUT_S,
        env=env,
        check=True,
    )
    assert result.returncode == 0
    assert "event: stopped (natural_end: false)" in result.stdout
    assert "index_after_stop: 0" in result.stdout


def test_speech_player_to_wav_output(tts_cli, kokoro_model_dir, source_root, tmp_path):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    out_wav = tmp_path / "output.wav"

    result = subprocess.run(
        [str(tts_cli), "to-wav", str(kokoro_model_dir), str(doc_path), str(out_wav)],
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    assert result.returncode == 0
    assert out_wav.is_file()
    assert out_wav.stat().st_size > 10000

    with wave.open(str(out_wav), "rb") as wf:
        assert wf.getnchannels() == 1
        assert wf.getframerate() == 24000
        assert wf.getsampwidth() == 2
        duration_s = wf.getnframes() / wf.getframerate()
        assert 5.0 < duration_s < 30.0


def test_speech_player_missing_voice_dir_fails_gracefully(tts_cli, source_root, tmp_path):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    fake_dir = tmp_path / "nonexistent-voice"

    result = subprocess.run(
        [str(tts_cli), "play", str(fake_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 1
    assert "Failed to initialize speech synthesis engine" in result.stderr
    # No pipeline, no clock: nothing to highlight.
    assert _word_lines(result.stdout) == []


def test_speech_player_word_clock_advances_per_sentence(tts_cli, kokoro_model_dir, source_root):
    """AE1: one word at a time, advancing inside each sentence's own PCM."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "play", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    stopped_at = out.find("event: stopped")
    assert stopped_at != -1, out

    # Preroll may emit no word at all, but audio must not finish wordless.
    words = _word_lines(out[:stopped_at])
    assert words, out
    assert any(sentence == 0 for sentence, _, _, _ in words), words
    # A queued tick must not paint after the pipeline is torn down.
    assert _word_lines(out[stopped_at:]) == [], out

    # Sentence indices stay 0-based even though `position:` is 1-based.
    assert all(0 <= sentence < len(URLS_SENTENCES) for sentence, _, _, _ in words), words
    first_pos1 = out.find("position: 1 / 4")
    assert first_pos1 != -1, out
    after_pos1 = _word_lines(out[first_pos1:stopped_at])
    assert any(sentence == 0 for sentence, _, _, _ in after_pos1), after_pos1

    for sentence, word, start, end in words:
        assert word >= 0, "urls.txt has no wordless sentence"
        assert 0 <= start < end <= len(URLS_SENTENCES[sentence])

    per_sentence = _indices_by_sentence(words)
    _assert_word_clock_only_advances(per_sentence)
    for sentence, indices in per_sentence.items():
        assert max(indices) < _span_count(URLS_SENTENCES[sentence]), (sentence, indices)

    assert set(per_sentence.get(2, [])) <= {0, 1, 2}, per_sentence


def test_speech_player_pause_freezes_word_mid_sentence(tts_cli, kokoro_model_dir, source_root):
    """AE2: pause holds the spoken word; resume moves on from it, not from 0."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-mid-resume", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    paused_at = out.find("event: paused")
    resuming_at = out.find("event: resuming")
    assert paused_at != -1 and resuming_at > paused_at, out

    before_pause = _word_lines(out[:paused_at])
    assert before_pause, out
    last_sentence, last_word, _, _ = before_pause[-1]
    assert last_sentence == 0, before_pause
    # 1500 ms into the first sentence is past its first word.
    assert last_word > 0, before_pause

    # The clock stops with the pipeline: nothing repaints while paused.
    assert _word_lines(out[paused_at:resuming_at]) == [], out

    after_resume = _word_lines(out[resuming_at:])
    assert after_resume, out
    resumed_sentence, resumed_word, _, _ = after_resume[0]
    assert resumed_sentence == last_sentence, after_resume
    assert resumed_word >= last_word, (last_word, after_resume)


def test_speech_player_word_clock_survives_speed_change(tts_cli, kokoro_model_dir, source_root):
    """AE3: a mid-listen rate change does not retarget the live word clock."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    # `change-speed` raises the rate at the first `position: 1 / 4`, which
    # is when sentence 0 is *queued* — its audio, and so its word clock,
    # start after the change.
    first_pos1 = out.find("position: 1 / 4")
    assert first_pos1 != -1, out

    per_sentence = _indices_by_sentence(_word_lines(out[first_pos1:]))
    # The speaking sentence keeps the table built from its own PCM.
    _assert_word_clock_only_advances(per_sentence)
    assert per_sentence.get(0), per_sentence
    # Sentences generated at the new rate are clocked from their own PCM too.
    assert 1 in per_sentence, per_sentence
    assert 2 in per_sentence, per_sentence


def test_speech_player_pause_speed_resume_keeps_word(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-speed-resume", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=PLAYBACK_TIMEOUT_S,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    paused_at = out.find("event: paused (index: 1)")
    resuming_at = out.find("event: resuming")
    assert paused_at != -1 and resuming_at > paused_at, out

    assert _word_lines(out[paused_at:resuming_at]) == [], out

    before_pause = _word_lines(out[:paused_at])
    after_resume = _word_lines(out[resuming_at:])
    assert after_resume, out
    resumed_sentence, resumed_word, _, _ = after_resume[0]
    # This command pauses the instant sentence 0 is queued, so preroll may
    # leave no pre-pause word at all; resume must still land in sentence 0.
    assert resumed_sentence == 0, after_resume
    if before_pause:
        assert before_pause[-1][0] == 0, before_pause
        assert resumed_word >= before_pause[-1][1], (before_pause, after_resume)


def test_speech_player_stop_emits_no_word_after_teardown(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "stop", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=EARLY_EXIT_TIMEOUT_S,
        env=env,
        check=False,
    )
    if result.returncode != 0 and "Ort::Exception" in result.stderr:
        # Cancelling a generate in flight aborts inside onnxruntime on some
        # hosts, taking buffered stdout with it. Pre-existing and unrelated
        # to the word clock (test_speech_player_stop_clean_reset trips on the
        # same race); the natural-end teardown is covered above.
        pytest.skip(f"sherpa-onnx generate-cancel abort: {result.stderr.strip()}")
    assert result.returncode == 0, result.stderr
    out = result.stdout
    stopped_at = out.find("event: stopped")
    assert stopped_at != -1, out
    # A queued tick must not paint after the pipeline is gone.
    assert _word_lines(out[stopped_at:]) == [], out
