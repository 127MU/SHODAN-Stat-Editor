"""Compare standalone Rust LDLD indexing with the existing format on local originals.

No Lua runtime, DLL, game process or game writes are involved.
"""
import argparse
import json
import struct
import subprocess
from pathlib import Path


def expected(data):
    magic = b"LDLD\1\0\0\0"
    at = data.find(magic, 0, 64)
    blocks = []
    while at >= 0:
        kind, size = struct.unpack_from("<II", data, at + 8)
        end = at + 24 + size
        assert end <= len(data)
        blocks.append({
            "offset": at, "type": f"{kind:08X}", "payload_offset": at + 24,
            "payload_bytes": size,
            "original_header": data[at + 16:at + 24] == b"\1\0\0\0\0\0\0\0",
        })
        if end == len(data):
            return blocks
        at = data.find(magic, end, end + 64)
    raise AssertionError("Unparsed fixture suffix")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--originals", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fixtures = sorted(args.originals.glob("*.dl_plain"))
    assert fixtures, "No original data fixtures found"
    rows = []
    for path in fixtures:
        data = path.read_bytes()
        run = subprocess.run([str(args.exe.resolve()), "inspect", str(path.resolve())],
                             capture_output=True, text=True, encoding="utf8", check=True)
        actual = json.loads(run.stdout)
        assert actual["runtime"] == "rust-native" and actual["read_only"]
        assert actual["bytes"] == len(data)
        assert actual["blocks"] == expected(data), path.name
        rows.append({"file": path.name, "bytes": len(data), "blocks": len(actual["blocks"])})
    result = {"files": rows, "total_blocks": sum(row["blocks"] for row in rows),
              "lua_loaded": False, "game_writes": 0}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
