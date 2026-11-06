"""Run native reference edits and legacy preset replay against isolated game data."""
import argparse
import gzip
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--exe", type=pathlib.Path, default=ROOT / "target/debug/shodan-native.exe")
parser.add_argument("--inventory", type=pathlib.Path, default=ROOT / "dist/native-catalog-inventory-9")
parser.add_argument("--catalog", type=pathlib.Path, default=ROOT / "dist/native-catalog-compiled-9/catalog.json.gz")
args = parser.parse_args()
catalog = json.loads(gzip.decompress(args.catalog.read_bytes()))
inventory = json.loads((args.inventory / "catalog.json").read_text(encoding="utf8"))
originals = ROOT / "offline/originals"
names = {binding["file"] for field in catalog["fields"] for binding in field["bindings"]}
files = []
for name in sorted(names):
    fixture = inventory["fixtures"][name]["name"]
    path = (args.inventory / "sources" / fixture).resolve()
    original = originals / fixture
    files.append(dict(name=name, path=str(path), **(
        dict(baseline_path=str(original), baseline_name=original.name) if original.exists() else {}
    )))
process = subprocess.Popen([str(args.exe.resolve()), "--stdio"], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, text=True, encoding="utf8")


def call(method, ok=True, **params):
    process.stdin.write(json.dumps(dict(id=method, method=method, params=params)) + "\n")
    process.stdin.flush()
    result = json.loads(process.stdout.readline())
    assert result["ok"] is ok, result
    return result["result"] if ok else result["error"]


def rows(owner):
    return {row["id"]: row for row in call("catalog-read-rows", owner=owner)}


def change(owner, key, value, ok=True):
    return call("catalog-set", owner=owner, key=key, value=value, ok=ok)


def preset(owner, **values):
    return ("SHODAN-PRESET 1\nkind weapon\nname e6b58be8af95\nweapon " + owner + "\n"
            + "".join(f"value {owner} {key} {value}\n" for key, value in values.items()))


try:
    call("catalog-load", path=str(args.catalog.resolve()))
    opened = call("workspace-open", files=files)
    assert not opened["problems"], opened
    weapon = "A8A91EB54892B6B2"  # AR-11 Adjudicator
    before = rows(weapon)
    original_projectile = before["projectile"]["value"]
    shot = "F100000000000043"
    blast = "F200000000000043"
    assert original_projectile != 67
    choices = call("catalog-reference-choices", owner=weapon, key="projectile")
    assert choices[0]["id"] != 0 and next(row for row in choices if row["id"] == 67)["owner"] == shot
    change(weapon, "projectile", 67)
    assert rows(weapon)["projectile"]["reference"]["owner"] == shot
    assert rows(weapon)["damage"]["value"] == before["damage"]["value"]
    assert any(node["key"] == "shot:67" for node in call("catalog-references", owner=weapon)["entries"])
    change(shot, "impact_explosion", 67)
    assert rows(shot)["impact_explosion"]["reference"]["owner"] == blast
    details = call("catalog-reference-detail", owner=shot, key="impact_explosion")
    assert details["reference"]["owner"] == blast
    assert any(row["id"] == "inner" and row["value"] is not None for row in details["rows"])
    assert any(node["key"] == "blast:67" and node["parent"] == "shot:67"
               for node in call("catalog-references", owner=weapon)["entries"])
    change(blast, "shrapnel_projectile", int(original_projectile))
    assert rows(blast)["shrapnel_projectile"]["reference"]["id"] == original_projectile
    assert call("workspace-undo") is True
    assert call("workspace-redo") is True
    change(weapon, "projectile", 4294967295, ok=False)
    assert rows(weapon)["projectile"]["value"] == 67
    call("workspace-open", files=files)

    options = call("catalog-reference-choices", owner=weapon, key="slot4")
    assert next(row for row in options if row["id"] == 5)["disabled"]
    change(weapon, "slot4", 5, ok=False)
    for index, effect in enumerate([5, 38, 43, 45], 1):
        change(weapon, f"slot{index}", effect)
    status = rows(weapon)
    assert status["slot4"]["value"] == 45
    assert status["slot4_strength"]["value"] == 100
    change(weapon, "slot2", 0, ok=False)
    assert call("workspace-undo") is True and rows(weapon)["slot4"]["value"] == 0
    assert call("workspace-redo") is True and rows(weapon)["slot4"]["value"] == 45
    call("workspace-open", files=files)

    text = preset(weapon, slot1=5, slot2=38, status38_strength=13.5, slot1_strength=4, f018=2)
    call("catalog-preset-preview", text=text, ok=False)
    preview = call("catalog-preset-preview", text=text, skip_missing=True)
    assert len(preview["warnings"]) == 1 and "f018" in preview["warnings"][0]
    assert rows(weapon)["slot1"]["value"] == before["slot1"]["value"]
    applied = call("catalog-preset-apply", text=text, skip_missing=True)
    assert applied["changes"] == preview["changes"]
    status = rows(weapon)
    assert status["slot2_strength"]["value"] == 13.5 and status["slot1_strength"]["value"] == 4
    saved = call("catalog-preset-export", name="测试", kind="weapon", owner=weapon)["text"]
    assert " slot2_strength 13.5" in saved and "status38_strength" not in saved
    assert call("workspace-undo") is True and rows(weapon)["slot2"]["value"] == before["slot2"]["value"]
    call("catalog-preset-apply", text=saved)
    assert rows(weapon)["slot2_strength"]["value"] == 13.5
    state = call("workspace-preview")
    call("catalog-preset-apply", text=preset(weapon, slot1=38, slot2=38, status38_strength=7), ok=False)
    call("catalog-preset-apply", text=preset(weapon, slot1=0, slot2=0, slot3=5), ok=False)
    assert call("workspace-preview") == state

    barrage120 = "000000003F6103F6"
    barrage380 = "00000000B948340B"
    choices = call("catalog-reference-choices", owner=barrage120, key="extra")
    assert next(choice for choice in choices if choice["id"] == 139)["disabled"]
    assert not next(choice for choice in choices if choice["id"] == 86)["disabled"]
    change(barrage120, "extra", 86)
    duplicate = preset(barrage380, extra=86)
    assert call("catalog-preset-preview", text=duplicate)["warnings"]
    call("catalog-preset-apply", text=duplicate, ok=False)
    assert rows(barrage380)["extra"]["value"] == 0
    assert call("catalog-preset-apply", text=duplicate, accept_warnings=True)["warnings"]
    assert rows(barrage380)["extra"]["value"] == 86
    change("000000005D020FDD", "extra", 139, ok=False)
    assert rows("000000005D020FDD")["extra"]["value"] == 0
finally:
    process.stdin.close()
    assert process.wait(timeout=15) == 0
print("Native reference and legacy preset regression passed; game writes 0")
