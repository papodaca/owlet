"""Owlet.VoiceModels integration tests via owlet-voice-cli."""

from __future__ import annotations

import hashlib
import io
import subprocess
import tarfile
from pathlib import Path


def create_tarball(files: dict[str, bytes], root_dir: str = "kokoro-en-v0_19") -> tuple[bytes, str]:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:bz2") as tar:
        for name, data in files.items():
            path = f"{root_dir}/{name}" if root_dir else name
            ti = tarfile.TarInfo(name=path)
            ti.size = len(data)
            tar.addfile(ti, io.BytesIO(data))
    payload = buf.getvalue()
    digest = hashlib.sha256(payload).hexdigest()
    return payload, digest


def valid_voice_payload(root_dir: str = "kokoro-en-v0_19") -> tuple[bytes, str]:
    return create_tarball({
        "model.onnx": b"onnx-weights-data",
        "voices.bin": b"voice-embeddings-data",
        "tokens.txt": b"token-map-data",
        "espeak-ng-data/dict": b"espeak-dict-data",
    }, root_dir=root_dir)


def test_voice_status_not_installed_initially(voice_cli, xdg_home):
    result = subprocess.run(
        [str(voice_cli), "status"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "status: not-installed" in result.stdout


def test_voice_download_and_extract_happy_path(voice_cli, http_server, xdg_home):
    payload, digest = valid_voice_payload()
    http_server.configure(get_body=payload)

    result = subprocess.run(
        [str(voice_cli), "download", f"{http_server.url}/voice.tar.bz2", digest],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )
    assert result.returncode == 0
    assert "completed:" in result.stdout

    voice_dir = xdg_home / ".local" / "share" / "owlet" / "models" / "voices" / "kokoro-en-v0_19"
    assert voice_dir.is_dir()
    assert (voice_dir / "model.onnx").read_bytes() == b"onnx-weights-data"
    assert (voice_dir / "voices.bin").read_bytes() == b"voice-embeddings-data"
    assert (voice_dir / "tokens.txt").read_bytes() == b"token-map-data"
    assert (voice_dir / "espeak-ng-data" / "dict").read_bytes() == b"espeak-dict-data"

    # Status should now be installed
    st = subprocess.run(
        [str(voice_cli), "status"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "status: installed" in st.stdout


def test_voice_redownload_over_existing_voice_dir(voice_cli, http_server, xdg_home):
    # First download
    payload1, digest1 = valid_voice_payload()
    http_server.configure(get_body=payload1)
    subprocess.run(
        [str(voice_cli), "download", f"{http_server.url}/voice1.tar.bz2", digest1],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )

    # Second download with new contents
    payload2, digest2 = create_tarball({
        "model.onnx": b"onnx-v2-weights",
        "voices.bin": b"voice-v2-embeddings",
        "tokens.txt": b"token-v2-map",
        "espeak-ng-data/dict": b"espeak-v2-dict",
    })
    http_server.configure(get_body=payload2)
    res2 = subprocess.run(
        [str(voice_cli), "download", f"{http_server.url}/voice2.tar.bz2", digest2],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )
    assert res2.returncode == 0

    voice_dir = xdg_home / ".local" / "share" / "owlet" / "models" / "voices" / "kokoro-en-v0_19"
    assert (voice_dir / "model.onnx").read_bytes() == b"onnx-v2-weights"
    assert not (voice_dir.parent / "kokoro-en-v0_19.new").exists()
    assert not (voice_dir.parent / "kokoro-en-v0_19.old").exists()


def test_voice_debris_sweep_after_simulated_crash(voice_cli, xdg_home):
    voices_dir = xdg_home / ".local" / "share" / "owlet" / "models" / "voices"
    voices_dir.mkdir(parents=True, exist_ok=True)
    (voices_dir / "kokoro-en-v0_19.new").mkdir(exist_ok=True)
    (voices_dir / "kokoro-en-v0_19.old").mkdir(exist_ok=True)

    # Calling status triggers debris sweep
    result = subprocess.run(
        [str(voice_cli), "status"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "status: not-installed" in result.stdout
    assert not (voices_dir / "kokoro-en-v0_19.new").exists()
    assert not (voices_dir / "kokoro-en-v0_19.old").exists()


def test_voice_sha256_mismatch_fails_and_cleans_up(voice_cli, http_server, xdg_home):
    payload, _ = valid_voice_payload()
    http_server.configure(get_body=payload)
    bad_digest = "0000000000000000000000000000000000000000000000000000000000000000"

    result = subprocess.run(
        [str(voice_cli), "download", f"{http_server.url}/voice.tar.bz2", bad_digest],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode != 0
    assert "SHA256 mismatch" in result.stderr

    voices_dir = xdg_home / ".local" / "share" / "owlet" / "models" / "voices"
    assert not (voices_dir / "kokoro-en-v0_19").exists()
    assert not (voices_dir / "kokoro-en-v0_19.tar.bz2").exists()


def test_voice_corrupted_tarball_fails_and_cleans_up(voice_cli, http_server, xdg_home):
    corrupt_payload = b"not-a-valid-tar-bz2-file-content-at-all"
    corrupt_digest = hashlib.sha256(corrupt_payload).hexdigest()
    http_server.configure(get_body=corrupt_payload)

    result = subprocess.run(
        [str(voice_cli), "download", f"{http_server.url}/corrupt.tar.bz2", corrupt_digest],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode != 0
    assert "Failed to extract voice archive" in result.stderr

    voices_dir = xdg_home / ".local" / "share" / "owlet" / "models" / "voices"
    assert not (voices_dir / "kokoro-en-v0_19").exists()
    assert not (voices_dir / "kokoro-en-v0_19.new").exists()


def test_voice_cancel_download_fails_gracefully(voice_cli, http_server, xdg_home):
    payload, digest = valid_voice_payload()
    http_server.configure(get_body=payload)

    result = subprocess.run(
        [str(voice_cli), "cancel", f"{http_server.url}/voice.tar.bz2", digest],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert "failed: cancelled" in result.stdout

    voices_dir = xdg_home / ".local" / "share" / "owlet" / "models" / "voices"
    assert not (voices_dir / "kokoro-en-v0_19").exists()


def test_voice_double_download_busy_guard(voice_cli, http_server, xdg_home):
    payload, digest = valid_voice_payload()
    http_server.configure(get_body=payload)

    result = subprocess.run(
        [str(voice_cli), "double-download",
         f"{http_server.url}/voice1.tar.bz2", digest,
         f"{http_server.url}/voice2.tar.bz2", digest],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )
    assert "second_error: A download is already in progress" in result.stdout


def test_voice_incomplete_tarball_results_in_broken_status(voice_cli, http_server, xdg_home):
    # Archive missing tokens.txt
    payload, digest = create_tarball({
        "model.onnx": b"weights-only",
        "voices.bin": b"voices-only",
    })
    http_server.configure(get_body=payload)

    result = subprocess.run(
        [str(voice_cli), "download", f"{http_server.url}/broken.tar.bz2", digest],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode != 0
    assert "Voice archive is missing required files" in result.stderr


def test_voice_sid_known_name(voice_cli):
    result = subprocess.run(
        [str(voice_cli), "sid", "af_bella"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "name: af_bella" in result.stdout
    assert "sid: 1" in result.stdout


def test_voice_sid_roster_edges(voice_cli):
    af = subprocess.run(
        [str(voice_cli), "sid", "af"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "name: af\n" in af.stdout
    assert "sid: 0" in af.stdout

    lewis = subprocess.run(
        [str(voice_cli), "sid", "bm_lewis"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "name: bm_lewis" in lewis.stdout
    assert "sid: 10" in lewis.stdout


def test_voice_sid_unknown_name_snaps_to_default(voice_cli):
    result = subprocess.run(
        [str(voice_cli), "sid", "not-a-voice"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    assert "name: af_bella" in result.stdout
    assert "sid: 1" in result.stdout


def test_voice_sid_missing_name_is_usage_error(voice_cli):
    result = subprocess.run(
        [str(voice_cli), "sid"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 2
    assert "usage:" in result.stderr
