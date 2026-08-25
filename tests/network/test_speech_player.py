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
