"""MPRIS name ownership and Close-release tests (media-key transport)."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.ui

MPRIS_NAME = "org.mpris.MediaPlayer2.im.apodaca.owlet"
MPRIS_PATH = "/org/mpris/MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
HARD_CRITICALS = (
    "Gtk-CRITICAL",
    "Adwaita-CRITICAL",
    "GLib-CRITICAL",
)
SIGRTMIN_NOISE = (
    "g_unix_signal_source_new",
    "g_source_set_callback: assertion 'source != NULL'",
    "g_source_attach: assertion 'source != NULL'",
    "g_source_unref: assertion 'source != NULL'",
)
POLL_APP = r"""
app_owned=no
for i in $(seq 1 50); do
    if busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s im.apodaca.owlet \
            | grep -q 'true'; then
        app_owned=yes
        break
    fi
    sleep 0.1
done
"""
POLL_OWNED = r"""
owned=no
for i in $(seq 1 50); do
    if busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s """ + MPRIS_NAME + r""" \
            | grep -q 'true'; then
        owned=yes
        break
    fi
    sleep 0.1
done
"""
POLL_RELEASED = r"""
released=no
for i in $(seq 1 50); do
    if busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s """ + MPRIS_NAME + r""" \
            | grep -q 'false'; then
        released=yes
        break
    fi
    sleep 0.1
done
"""


def _unexpected_criticals(stderr: str) -> list[str]:
    hits = []
    for line in stderr.splitlines():
        if not any(tag in line for tag in HARD_CRITICALS):
            continue
        if any(n in line for n in SIGRTMIN_NOISE):
            continue
        hits.append(line)
    return hits


def _require_mpris_harness() -> None:
    if shutil.which("xvfb-run") is None:
        pytest.skip("xvfb-run not installed")
    if shutil.which("dbus-run-session") is None:
        pytest.skip("dbus-run-session not installed")
    if shutil.which("busctl") is None:
        pytest.skip("busctl not installed")


def _seed_dummy_voice(xdg_home: Path) -> None:
    voice_dir = (
        xdg_home / ".local" / "share" / "owlet" / "models" / "voices" / "kokoro-en-v0_19"
    )
    voice_dir.mkdir(parents=True, exist_ok=True)
    (voice_dir / "model.onnx").write_bytes(b"dummy-model")
    (voice_dir / "voices.bin").write_bytes(b"dummy-voices")
    (voice_dir / "tokens.txt").write_bytes(b"dummy-tokens")
    (voice_dir / "espeak-ng-data").mkdir(exist_ok=True)
    (voice_dir / "espeak-ng-data" / "dict").write_bytes(b"dummy-dict")


def _base_env(schema_dir, xdg_home) -> dict[str, str]:
    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(xdg_home)
    env["XDG_DATA_HOME"] = str(xdg_home / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(xdg_home / ".config")
    env["GDK_BACKEND"] = "x11"
    env["GTK_A11Y"] = "none"
    return env


def _run_session(script: str, env: dict[str, str], timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "xvfb-run",
            "-a",
            "-s",
            "-screen 0 1280x1024x24",
            "dbus-run-session",
            "--",
            "bash",
            "-c",
            script,
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


@pytest.mark.parametrize(
    "open_name",
    [None, "empty.txt"],
    ids=["no-document", "empty-document"],
)
def test_mpris_absent_when_not_readable(
    owlet_bin, schema_dir, xdg_home, source_root, tmp_path, open_name
):
    _require_mpris_harness()
    log_path = tmp_path / "mpris-absent-stderr.log"
    env = _base_env(schema_dir, xdg_home)
    if open_name is not None:
        env["OWLET_TEST_OPEN"] = str(
            source_root / "tests" / "fixtures" / "document" / open_name
        )

    script = f"""
set -e
{owlet_bin} > /dev/null 2>{log_path} &
APP_PID=$!
{POLL_APP}
sleep 0.5
owned=no
if busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus NameHasOwner s {MPRIS_NAME} | grep -q 'true'; then
    owned=yes
fi
echo "RESULT owned=$owned app_owned=$app_owned pid_alive=$(kill -0 $APP_PID && echo yes || echo no)"
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = _run_session(script, env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert "RESULT owned=no" in result.stdout, result.stdout
    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, "unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"


def test_mpris_present_then_in_process_close_releases(
    owlet_bin, schema_dir, xdg_home, source_root, tmp_path
):
    _require_mpris_harness()
    _seed_dummy_voice(xdg_home)
    log_path = tmp_path / "mpris-close-stderr.log"
    close_path = tmp_path / "close-doc"
    env = _base_env(schema_dir, xdg_home)
    env["OWLET_TEST_OPEN"] = str(source_root / "tests" / "fixtures" / "document" / "utf8.txt")
    env["OWLET_TEST_CLOSE"] = str(close_path)
    env["OWLET_TTS_SINK"] = "fakesink"

    script = f"""
set -e
{owlet_bin} > /dev/null 2>{log_path} &
APP_PID=$!
{POLL_OWNED}
echo "RESULT before_close owned=$owned pid_alive=$(kill -0 $APP_PID && echo yes || echo no)"
touch {close_path}
{POLL_RELEASED}
echo "RESULT after_close released=$released pid_alive=$(kill -0 $APP_PID && echo yes || echo no)"
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = _run_session(script, env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert "RESULT before_close owned=yes" in result.stdout, result.stdout
    assert "RESULT after_close released=yes pid_alive=yes" in result.stdout, result.stdout
    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, "unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"


def test_mpris_next_and_stop_are_successful_noops(
    owlet_bin, schema_dir, xdg_home, source_root, tmp_path
):
    _require_mpris_harness()
    _seed_dummy_voice(xdg_home)
    log_path = tmp_path / "mpris-noop-stderr.log"
    env = _base_env(schema_dir, xdg_home)
    env["OWLET_TEST_OPEN"] = str(source_root / "tests" / "fixtures" / "document" / "utf8.txt")
    env["OWLET_TTS_SINK"] = "fakesink"

    script = f"""
set -e
{owlet_bin} > /dev/null 2>{log_path} &
APP_PID=$!
{POLL_OWNED}
test "$owned" = yes
status_before=$(busctl --user get-property {MPRIS_NAME} {MPRIS_PATH} {PLAYER_IFACE} PlaybackStatus)
busctl --user call {MPRIS_NAME} {MPRIS_PATH} {PLAYER_IFACE} Next
busctl --user call {MPRIS_NAME} {MPRIS_PATH} {PLAYER_IFACE} Stop
status_after=$(busctl --user get-property {MPRIS_NAME} {MPRIS_PATH} {PLAYER_IFACE} PlaybackStatus)
echo "RESULT owned=$owned status_before=$status_before status_after=$status_after"
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = _run_session(script, env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert "RESULT owned=yes" in result.stdout, result.stdout
    # Dummy voice may fail synthesis; Next/Stop must not change whatever status we had.
    line = [ln for ln in result.stdout.splitlines() if ln.startswith("RESULT ")][-1]
    before = line.split("status_before=", 1)[1].split(" status_after=", 1)[0]
    after = line.split("status_after=", 1)[1]
    assert before == after, result.stdout
    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, "unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"
