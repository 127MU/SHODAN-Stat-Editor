"""Standalone native JSON editing regression. Writes only an isolated temp folder."""
import json
import pathlib
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
(ROOT / "dist/build-temp-r19").mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="native-api-", dir=ROOT / "dist/build-temp-r19") as folder:
    folder = pathlib.Path(folder)
    disk = folder / "fixture.plain"
    original = b"LDLD\x01\0\0\0" + struct.pack("<IIQ", 1, 32, 0)
    original += struct.pack("<QIIIfIf", 0, 2, 0, 5, 1.3, 9, -2.5)
    disk.write_bytes(original)
    process = subprocess.Popen([str(ROOT / "target/release/shodan-native.exe"), "--stdio"],
                               cwd=folder, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               text=True, encoding="utf-8")
    serial = 0
    def call(method, **params):
        global serial
        serial += 1
        process.stdin.write(json.dumps(dict(id=serial, method=method, params=params)) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response["id"] == serial
        return response
    try:
        assert call("info")["result"]["lua"] is False
        assert call("open", path=str(disk))["ok"]
        assert call("index", block=0, layout="rows", stride=8, id_offset=0)["ok"]
        field = dict(block=0, record="id:9", relative=4, kind="f32")
        assert call("get", **field)["result"] == dict(value=-2.5, original=None)
        assert not call("restore", **field)["ok"]
        assert call("set", **field, value=1000000)["ok"]
        assert not call("apply-batch", fields=[dict(field,value=20),dict(field,value=30)])["ok"]
        assert call("get", **field)["result"]["value"] == 1000000
        assert not call("apply-batch", fields=[dict(field,value=20),dict(field,record="id:999",value=30)])["ok"]
        assert call("get", **field)["result"]["value"] == 1000000
        portable = "SHODAN-PRESET 1\nkind full\nname e4b8ade69687\narmor 7061737369766573\nvalue FFFFFFFFFFFFFFFF slot1_strength 0.125\n"
        preset = call("preset-inspect", text=portable)
        assert preset["ok"] and preset["result"]["name"] == "中文"
        assert preset["result"]["values"][0]["owner"] == "FFFFFFFFFFFFFFFF"
        assert call("preset-inspect", text=preset["result"]["normalized"])["result"] == preset["result"]
        exported = folder / "edited.plain"
        response = call("export-copy", path=str(exported))
        assert response["ok"], response
        expected = original[:52] + struct.pack("<f", 1000000)
        assert exported.read_bytes() == expected
        assert disk.read_bytes() == original
        assert not call("export-copy", path=str(exported))["ok"]
        disk.write_bytes(expected)
        assert not call("export-copy", path=str(folder / "stale.plain"))["ok"]
        assert not (folder / "stale.plain").exists()
        assert not call("open", path=str(folder / "missing"))["ok"]
        assert call("get", **field)["result"]["value"] == 1000000
        assert call("close")["ok"]
        assert not call("get", **field)["ok"]
    finally:
        process.stdin.close()
        assert process.wait(timeout=10) == 0
print("Native API: isolated edit/export, overwrite refusal, stale snapshot and recovery passed")
