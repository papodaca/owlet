"""gresource paths baked into the owlet binary (docs/testing.md §9)."""

from __future__ import annotations

import subprocess


EXPECTED_PATHS = [
    "/im/apodaca/owlet/preferences.ui",
    "/im/apodaca/owlet/shortcuts-dialog.ui",
    "/im/apodaca/owlet/test-sample.wav",
    "/im/apodaca/owlet/window.ui",
]


def test_gresource_paths_in_binary(owlet_bin):
    result = subprocess.run(
        ["strings", str(owlet_bin)],
        capture_output=True,
        text=True,
        check=True,
    )
    lines = set(result.stdout.splitlines())
    missing = [p for p in EXPECTED_PATHS if p not in lines]
    assert not missing, f"missing gresource paths in {owlet_bin}: {missing}"
