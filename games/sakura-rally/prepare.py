#!/usr/bin/env python3
"""Turn a pristine upstream Sakura Rally checkout into the Android/touch build.

    python3 games/sakura-rally/prepare.py <path-to-upstream-checkout>

It changes one line of one upstream script (PATCHES below) and otherwise only:
  * copies mobile/ (autoload, touch controls, race layer, CI checks) and the launcher icons into
    res://mobile/;
  * adds the `Mobile` autoload and the Android-specific project settings to project.godot. Each
    one is a platform override (`.mobile`), so desktop builds of the same tree are unchanged;
  * writes export_presets.cfg with the version and package from build.env.
"""
from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# (section, key, value). Values are written verbatim in Godot's project.godot syntax.
SETTINGS = [
    ("autoload", "Mobile", '"*res://mobile/mobile.gd"'),
    # Back is handled by mobile.gd (pause / back out / quit from the title hub).
    ("application", "config/quit_on_go_back", "false"),
    ("display", "window/handheld/orientation", "4"),  # sensor landscape
    ("display", "window/size/mode.mobile", "3"),  # fullscreen (immersive)
    ("input_devices", "pointing/emulate_mouse_from_touch", "true"),
    ("input_devices", "pointing/emulate_touch_from_mouse", "false"),
    # Mobile renderer on phones, with the GLES3 Compatibility renderer as fallback where Vulkan
    # is missing. Forward+ stays the desktop renderer.
    ("rendering", "renderer/rendering_method.mobile", '"mobile"'),
    ("rendering", "rendering_device/fallback_to_opengl3", "true"),
    ("rendering", "textures/vram_compression/import_etc2_astc", "true"),
    ("rendering", "lights_and_shadows/directional_shadow/size.mobile", "2048"),
    ("rendering", "anti_aliasing/quality/msaa_3d.mobile", "0"),
    ("rendering", "textures/default_filters/anisotropic_filtering_level.mobile", "2"),
]

# (file, exact upstream text, replacement). Each must match exactly once, or the build stops.
PATCHES = [
    # Race mode: the rivals race with race_bot_plus.gd (a RaceBot subclass: attack, slipstream,
    # defence, the player-relative pace, the batched network). See docs/RACE.md.
    ("scripts/main.gd",
     "\t\tvar bot := RaceBot.new()\n",
     '\t\tvar bot: RaceBot = (load("res://mobile/race/race_bot_plus.gd") as GDScript).new()\n'),
]


def apply_patches(proj: Path) -> None:
    for rel, old, new in PATCHES:
        f = proj / rel
        text = f.read_text()
        n = text.count(old)
        if n != 1:
            raise SystemExit(f"error: patch for {rel} matches {n} times (expected 1): {old.strip()!r}")
        f.write_text(text.replace(old, new))
        print(f"patched {rel}: {old.strip()!r} -> {new.strip()!r}")


def read_env() -> dict[str, str]:
    env = {}
    for line in (HERE / "build.env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def set_setting(text: str, section: str, key: str, value: str) -> str:
    lines = text.split("\n")
    header = f"[{section}]"
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == header)
    except StopIteration:
        if lines and lines[-1].strip():
            lines.append("")
        lines += [header, "", f"{key}={value}", ""]
        return "\n".join(lines)
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^\[.+\]\s*$", lines[i])), len(lines))
    for i in range(start + 1, end):
        if lines[i].split("=", 1)[0].strip() == key:
            lines[i] = f"{key}={value}"
            return "\n".join(lines)
    # insert after the last non-blank line of the section
    insert = end
    while insert > start + 1 and not lines[insert - 1].strip():
        insert -= 1
    lines.insert(insert, f"{key}={value}")
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    proj = Path(sys.argv[1]).resolve()
    pg = proj / "project.godot"
    if not pg.is_file():
        print(f"error: {pg} not found", file=sys.stderr)
        return 1
    env = read_env()

    dst = proj / "mobile"
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(HERE / "mobile", dst)
    shutil.copytree(HERE / "android" / "icons", dst / "icons")
    # Keep the CI-only script out of the editor's export by name; it also lives under mobile/ci.
    print(f"copied mobile layer -> {dst}")

    apply_patches(proj)

    text = pg.read_text()
    for section, key, value in SETTINGS:
        text = set_setting(text, section, key, value)
    pg.write_text(text)
    print(f"patched {pg.name}: {len(SETTINGS)} settings")

    presets = (HERE / "android" / "export_presets.cfg").read_text()
    for k in ("VERSION_NAME", "VERSION_CODE", "PACKAGE"):
        presets = presets.replace(f"@{k}@", env[k])
    # preset.1: the same app for x86_64, used only by CI to run the APK in the Android emulator.
    test = (presets.replace("[preset.0]", "[preset.1]").replace("[preset.0.options]", "[preset.1.options]")
            .replace('name="Android"', 'name="Android x86_64 (emulator test)"')
            .replace("architectures/arm64-v8a=true", "architectures/arm64-v8a=false")
            .replace("architectures/x86_64=false", "architectures/x86_64=true"))
    (proj / "export_presets.cfg").write_text(presets.rstrip() + "\n\n" + test)
    print(f"wrote export_presets.cfg ({env['PACKAGE']} {env['VERSION_NAME']} / {env['VERSION_CODE']})")

    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        if (HERE / name).exists():
            shutil.copy(HERE / name, dst / name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
