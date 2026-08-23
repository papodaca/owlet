"""Owlet TTS engine integration via owlet-engine-cli: symbol resolution + error paths."""

from __future__ import annotations

import subprocess
from pathlib import Path


def test_engine_cli_usage_error(engine_cli):
    result = subprocess.run(
        [str(engine_cli)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 2
    assert "usage:" in result.stderr


def test_engine_cli_nonexistent_model_dir_fails_gracefully(engine_cli, tmp_path):
    fake_dir = tmp_path / "nonexistent-model-dir"
    result = subprocess.run(
        [str(engine_cli), str(fake_dir)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 1
    assert "failed to initialize offline TTS engine" in result.stderr
