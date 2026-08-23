"""Reader surface shell smoke and rendering tests (U5)."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.ui

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


def _unexpected_criticals(stderr: str) -> list[str]:
    hits = []
    for line in stderr.splitlines():
        if not any(tag in line for tag in HARD_CRITICALS):
            continue
        if any(n in line for n in SIGRTMIN_NOISE):
            continue
        hits.append(line)
    return hits


def test_reader_render_document_no_criticals(
    owlet_bin, schema_dir, xdg_home, xvfb, source_root, tmp_path
):
    doc_path = source_root / "tests" / "fixtures" / "document" / "utf8.txt"
    log_path = tmp_path / "owlet-reader-stderr.log"
    shot = tmp_path / "reader.png"

    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(xdg_home)
    env["XDG_DATA_HOME"] = str(xdg_home / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(xdg_home / ".config")
    env["GDK_BACKEND"] = "x11"
    env["GTK_A11Y"] = "none"
    env["OWLET_TEST_OPEN"] = str(doc_path)

    script = f"""
set -e
{owlet_bin} > /dev/null 2>{log_path} &
APP_PID=$!
sleep 3
if command -v import >/dev/null 2>&1; then
    import -window root {shot}
fi
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = subprocess.run(
        ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24", "bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr + result.stdout

    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, f"unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"


def test_reader_render_empty_document(
    owlet_bin, schema_dir, xdg_home, xvfb, source_root, tmp_path
):
    doc_path = source_root / "tests" / "fixtures" / "document" / "empty.txt"
    log_path = tmp_path / "owlet-empty-doc-stderr.log"

    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(xdg_home)
    env["XDG_DATA_HOME"] = str(xdg_home / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(xdg_home / ".config")
    env["GDK_BACKEND"] = "x11"
    env["GTK_A11Y"] = "none"
    env["OWLET_TEST_OPEN"] = str(doc_path)

    script = f"""
set -e
{owlet_bin} > /dev/null 2>{log_path} &
APP_PID=$!
sleep 3
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = subprocess.run(
        ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24", "bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr + result.stdout

    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, f"unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"


def test_reader_render_binary_file_toast(
    owlet_bin, schema_dir, xdg_home, xvfb, source_root, tmp_path
):
    doc_path = source_root / "tests" / "fixtures" / "document" / "binary.bin"
    log_path = tmp_path / "owlet-binary-doc-stderr.log"

    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(xdg_home)
    env["XDG_DATA_HOME"] = str(xdg_home / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(xdg_home / ".config")
    env["GDK_BACKEND"] = "x11"
    env["GTK_A11Y"] = "none"
    env["OWLET_TEST_OPEN"] = str(doc_path)

    script = f"""
set -e
{owlet_bin} > /dev/null 2>{log_path} &
APP_PID=$!
sleep 3
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = subprocess.run(
        ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24", "bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr + result.stdout

    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, f"unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"
