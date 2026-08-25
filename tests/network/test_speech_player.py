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


def _speed_values(stdout: str) -> list[float]:
    values: list[float] = []
    for line in stdout.splitlines():
        if line.startswith("speed:"):
            values.append(float(line.split(":", 1)[1].strip().split()[0]))
    return values


def test_speech_player_change_speed_mid_listen(tts_cli, kokoro_model_dir, source_root):
    """AE2: mid-listen set_speed does not restart; a later sentence uses the new rate."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=60,
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
    speeds = _speed_values(out)
    assert any(s in (1.5, 2.0) for s in speeds), speeds
    assert "event: stopped (natural_end: true)" in out


def test_speech_player_play_with_speed(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "play", str(kokoro_model_dir), str(doc_path), "0", "2.0"],
        capture_output=True,
        text=True,
        timeout=60,
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
    """AE3: pause, set_speed(0.75), resume re-synthesizes the flushed sentence at 0.75."""
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-speed-resume", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "event: paused (index: 1)" in out
    assert "event: resuming" in out
    after_resume = out.split("event: resuming", 1)[1]
    speeds_after = _speed_values(after_resume)
    assert any(s == 0.75 for s in speeds_after), speeds_after
    assert "position: 4 / 4" in out
    assert "event: stopped (natural_end: true)" in out


def test_speech_player_set_speed_snaps_nearest_preset(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(kokoro_model_dir), str(doc_path), "1.1", "2.0"],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    speeds = _speed_values(result.stdout)
    assert 2.0 in speeds, speeds
    first_pos1 = result.stdout.find("position: 1 / 4")
    assert first_pos1 != -1
    later_speeds = _speed_values(result.stdout[first_pos1:])
    assert 1.0 in later_speeds, later_speeds
    assert all(s > 0 for s in speeds)


@pytest.mark.parametrize("raw", ["0", "-1"])
def test_speech_player_set_speed_snaps_non_positive(tts_cli, kokoro_model_dir, source_root, raw):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "change-speed", str(kokoro_model_dir), str(doc_path), raw, "2.0"],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    speeds = _speed_values(result.stdout)
    assert all(s > 0 for s in speeds), speeds
    assert 2.0 in speeds, speeds
    first_pos1 = result.stdout.find("position: 1 / 4")
    assert first_pos1 != -1
    later_speeds = _speed_values(result.stdout[first_pos1:])
    assert 0.75 in later_speeds, later_speeds


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
        timeout=60,
        env=env,
        check=True,
    )
    assert result.returncode == 0
    assert "event: started" in result.stdout
    assert "position: 1 / 4" in result.stdout
    assert "position: 4 / 4" in result.stdout
    assert "event: stopped (natural_end: true)" in result.stdout


def test_speech_player_pause_and_resume(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "pause-resume", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
        check=True,
    )
    assert result.returncode == 0
    assert "event: paused (index: 1)" in result.stdout
    assert "event: resuming" in result.stdout
    # Resume re-synthesizes the flushed in-flight sentence, then continues.
    assert "position: 2 / 4" in result.stdout
    assert "position: 4 / 4" in result.stdout
    assert "event: stopped (natural_end: true)" in result.stdout
    paused_at = result.stdout.find("event: paused (index: 1)")
    stopped_at = result.stdout.find("event: stopped (natural_end: true)")
    assert paused_at != -1 and stopped_at > paused_at
    after_pause = result.stdout[paused_at:stopped_at]
    before_resume, after_resume = after_pause.split("event: resuming", 1)
    assert "position: 1 / 4" not in before_resume
    # Resume re-synthesizes the flushed in-flight sentence (index 1).
    assert "position: 1 / 4" in after_resume


def test_speech_player_stop_clean_reset(tts_cli, kokoro_model_dir, source_root):
    doc_path = source_root / "tests" / "fixtures" / "document" / "urls.txt"
    env = os.environ.copy()
    env["OWLET_TTS_SINK"] = "fakesink"

    result = subprocess.run(
        [str(tts_cli), "stop", str(kokoro_model_dir), str(doc_path)],
        capture_output=True,
        text=True,
        timeout=30,
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
