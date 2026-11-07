"""Rebuild the release MaterialIcons subset so every icon used by the app exists.

`flutter build --tree-shake-icons` can miss icons added since the previous
build, which renders them as blank squares.  The packaging script repaired that
through fontTools, but this machine has no pip; the Flutter SDK ships the same
`font-subset` tool, so use it instead.

Usage: python tools/repair_material_icons.py [--check]
"""
import argparse
import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def cmap_codepoints(path: Path) -> set[int]:
    data = path.read_bytes()
    tables = struct.unpack_from(">H", data, 4)[0]
    offset = 12
    cmap_offset = None
    for _ in range(tables):
        tag, _, off, _ = struct.unpack_from(">4sIII", data, offset)
        if tag == b"cmap":
            cmap_offset = off
        offset += 16
    if cmap_offset is None:
        raise ValueError(f"no cmap table in {path}")
    count = struct.unpack_from(">H", data, cmap_offset + 2)[0]
    points: set[int] = set()
    for i in range(count):
        # Encoding record: platformID (u16), encodingID (u16), offset (u32).
        sub = cmap_offset + struct.unpack_from(">I", data, cmap_offset + 4 + i * 8 + 4)[0]
        fmt = struct.unpack_from(">H", data, sub)[0]
        if fmt == 4:
            segx2 = struct.unpack_from(">H", data, sub + 6)[0]
            seg = segx2 // 2
            end = struct.unpack_from(f">{seg}H", data, sub + 14)
            start = struct.unpack_from(f">{seg}H", data, sub + 16 + segx2)
            delta = struct.unpack_from(f">{seg}h", data, sub + 16 + 2 * segx2)
            range_off = struct.unpack_from(f">{seg}H", data, sub + 16 + 3 * segx2)
            for i in range(seg):
                for code in range(start[i], min(end[i], 0xFFFE) + 1):
                    if range_off[i] == 0:
                        glyph = (code + delta[i]) & 0xFFFF
                    else:
                        at = sub + 16 + 3 * segx2 + 2 * i + range_off[i] + 2 * (code - start[i])
                        glyph = struct.unpack_from(">H", data, at)[0]
                        if glyph:
                            glyph = (glyph + delta[i]) & 0xFFFF
                    if glyph:
                        points.add(code)
        elif fmt == 12:
            groups = struct.unpack_from(">I", data, sub + 12)[0]
            for i in range(groups):
                lo, hi, _ = struct.unpack_from(">III", data, sub + 16 + i * 12)
                points.update(range(lo, hi + 1))
    return points


def flutter_root() -> Path:
    config = (ROOT / "desktop/morrow/windows/flutter/ephemeral/generated_config.cmake").read_text(
        encoding="utf8"
    )
    match = re.search(r'set\(FLUTTER_ROOT "([^"]+)"', config) or re.search(
        r'file\(TO_CMAKE_PATH "([^"]+)" FLUTTER_ROOT\)', config
    )
    if not match:
        raise SystemExit("Flutter SDK path not found in generated_config.cmake")
    return Path(match.group(1).replace("\\", "/"))


def icon_definitions(root: Path) -> dict[str, int]:
    source = (root / "packages/flutter/lib/src/material/icons.dart").read_text(encoding="utf8")
    return {
        name: int(value, 16)
        for name, value in re.findall(
            r"static const IconData (\w+) = IconData\(\s*0x([0-9a-f]+),\s*fontFamily: 'MaterialIcons'",
            source,
        )
    }


def used_icons() -> dict[str, set[str]]:
    used: dict[str, set[str]] = {}
    for path in (ROOT / "desktop/morrow/lib").rglob("*.dart"):
        for name in re.findall(r"\bIcons\.(\w+)", path.read_text(encoding="utf8")):
            used.setdefault(name, set()).add(path.name)
    return used


def release_font() -> Path:
    return (
        ROOT
        / "desktop/morrow/build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf"
    )


def repair(check_only: bool = False) -> int:
    root = flutter_root()
    codes = icon_definitions(root)
    used = used_icons()
    font = release_font()
    if not font.is_file():
        raise SystemExit(f"release font missing: {font}")
    present = cmap_codepoints(font)
    missing = {name: files for name, files in used.items() if codes.get(name, 1 << 31) not in present}
    if not missing:
        print(f"MaterialIcons complete ({len(present)} codepoints)")
        return 0
    for name, files in sorted(missing.items()):
        print(f"missing {name} U+{codes[name]:04X} ({', '.join(sorted(files))})")
    if check_only:
        return 1
    wanted = sorted(present | {codes[name] for name in used if name in codes})
    subset = root / "bin/cache/artifacts/engine/windows-x64/font-subset.exe"
    source = root / "bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"
    if not subset.is_file() or not source.is_file():
        raise SystemExit(f"font-subset or source font missing under {root}")
    staged = font.with_suffix(".repaired.otf")
    payload = " ".join(f"0x{code:X}" for code in wanted) + "\n"
    result = subprocess.run(
        [str(subset), str(staged), str(source)],
        input=payload,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0 or not staged.is_file():
        raise SystemExit(f"font-subset failed: {result.stderr.strip() or result.stdout.strip()}")
    staged.replace(font)
    present = cmap_codepoints(font)
    still = [name for name in used if name in codes and codes[name] not in present]
    if still:
        raise SystemExit("icons still missing: " + ", ".join(sorted(still)))
    print(f"MaterialIcons repaired: {len(present)} codepoints, {font.stat().st_size} bytes")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    return repair(parser.parse_args().check)


if __name__ == "__main__":
    sys.exit(main())
