#!/usr/bin/env python3
"""Smoke-test the JSON generator embedded in install.sh."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text(encoding="utf-8")
MARKER = """python - "$CONFIG_PATH" "$PROFILE_DESKTOP" "${PACKAGE_LIST[@]}" <<'PY'
"""
if MARKER not in INSTALLER:
    raise SystemExit("Could not locate the embedded Archinstall JSON generator")

generator_start = INSTALLER.index(MARKER) + len(MARKER)
generator_end = INSTALLER.find("\nPY\n", generator_start)
if generator_end < 0:
    raise SystemExit("Could not find the end of the embedded JSON generator")
generator = INSTALLER[generator_start:generator_end]


def build_config(desktop: str, packages: list[str]) -> dict:
    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "archinstall-config.json"
        subprocess.run(
            [sys.executable, "-", str(config_path), desktop, *packages],
            input=generator,
            text=True,
            check=True,
        )
        return json.loads(config_path.read_text(encoding="utf-8"))


minimal = build_config("", [])
assert minimal["network_config"] == {"type": "nm"}
assert minimal["profile_config"] is None
assert minimal["packages"] == []
assert "audio_config" not in minimal

for desktop in ("GNOME", "KDE Plasma", "Xfce4", "Cinnamon"):
    config = build_config(desktop, ["firefox", "git", "git", "custom-tool"])
    assert config["profile_config"]["profile"]["main"] == "Desktop"
    assert config["profile_config"]["profile"]["details"] == [desktop]
    assert config["audio_config"] == {"audio": "pipewire"}
    assert config["packages"] == ["firefox", "git", "custom-tool"]
    assert config["network_config"] == {"type": "nm"}

print("Archinstall profile configuration smoke tests passed.")
