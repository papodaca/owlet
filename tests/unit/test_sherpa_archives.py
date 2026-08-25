"""U6: sherpa-onnx configure-time archives are in package custody."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

SOURCE_ROOT = Path(
    os.environ.get("OWLET_SOURCE_ROOT", Path(__file__).resolve().parents[2])
)
HELPER = SOURCE_ROOT / "packaging" / "sherpa-onnx-archives.sh"


def _dump_manifest() -> list[dict[str, str]]:
    result = subprocess.run(
        ["bash", str(HELPER), "dump"],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = []
    for line in result.stdout.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        filename, sha256, url, arch = line.split("\t")
        rows.append(
            {
                "filename": filename,
                "sha256": sha256,
                "url": url,
                "arch": arch,
            }
        )
    return rows


def test_helper_lists_pinned_archives():
    rows = _dump_manifest()
    names = {r["filename"] for r in rows}
    assert "espeak-ng-ed530aa113046142eb5115cf2fc9157854d0ffe1.zip" in names
    assert "piper-phonemize-f3ff95afc03640bc1399e113e83361192a2fafb4.zip" in names
    assert any(n.startswith("onnxruntime-linux-") for n in names)
    for row in rows:
        assert len(row["sha256"]) == 64
        assert row["url"].startswith("https://")
        assert row["arch"] in {"any", "x86_64", "aarch64"}


def test_arch_pkgbuild_declares_helper_archives():
    pkgbuild = (SOURCE_ROOT / "packaging" / "arch" / "PKGBUILD").read_text()
    assert "sherpa-onnx-archives.sh" in pkgbuild
    assert "owlet_sherpa_seed" in pkgbuild


def test_debian_and_appimage_seed_sidecar_builddir():
    rules = (SOURCE_ROOT / "packaging" / "debian" / "rules").read_text()
    appimage = (SOURCE_ROOT / "packaging" / "appimage" / "build.sh").read_text()
    assert "sherpa-onnx-archives.sh" in rules
    assert "seed" in rules
    assert "sherpa-onnx-archives.sh" in appimage
    assert "seed" in appimage


def test_seed_copies_named_files(tmp_path):
    src = tmp_path / "from"
    dest = tmp_path / "sidecar"
    src.mkdir()
    rows = _dump_manifest()
    host = subprocess.check_output(["uname", "-m"], text=True).strip()
    copied = []
    for row in rows:
        if row["arch"] not in {"any", host}:
            continue
        (src / row["filename"]).write_bytes(b"stub")
        copied.append(row["filename"])
    subprocess.run(
        ["bash", str(HELPER), "seed", "--from", str(src), str(dest)],
        check=True,
        capture_output=True,
        text=True,
    )
    for name in copied:
        assert (dest / name).is_file()
