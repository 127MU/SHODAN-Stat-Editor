"""Build display metadata from research tables and the user's game localization.
No game installation or network configuration is changed.
"""
import argparse
import json
import re
from pathlib import Path

# Descriptive translations where the local game's text set has no matching title.
# Keep that distinction in the UI instead of claiming they are official names.
DESCRIPTIVE = {1228:"默里迪恩黑洞",1229:"默里迪恩黑洞（增强）",1230:"默里迪恩黑洞（航行封锁）",1241:"破碎星球",1252:"破碎星球",1352:"常规黑洞",1204:"解放日庆典",1329:"解放日庆典",1395:"终结族控制系统+",1400:"超级地球武装部队重兵驻守",1203:"喷气旅",1249:"焚烧军团",1355:"重装单位激增",1357:"巨型者激增",1359:"破坏者激增",1361:"生化人",1378:"无意识集群",1379:"侵占者",1403:"选票窃取者",1407:"虚空门户",1414:"入侵舰队",1245:"掠食者变种",1310:"破裂变种",1386:"孢子爆发变种",1396:"终结族控制塔",1240:"星球危机标记",1242:"通往超级地球的航线",1330:"烟花",1362:"机器人激烈战斗标记",1376:"光能族裂隙",1408:"光能族裂隙外观",1409:"其他星球的光能族裂隙",1410:"虚空集群一",1411:"虚空集群二",1412:"裂隙源头行动",1417:"光能族裂隙",1418:"强制撤离"}


def build(effects, planets, english, strings):
    names = {k.casefold(): v for k, v in english.items() if isinstance(v, str) and re.search(r"[\u3400-\u9fff]", v)}
    output = {"source": "hd2-network-proxy / hd2-datamined, build 26088801; static display hints only", "effects": [], "planets": [], "strings": {}}
    for line in effects.splitlines():
        cells = [c.strip().replace("`", "").replace("**", "") for c in line.strip().strip("|").split("|")]
        if not cells or not cells[0].isdigit() or len(cells) < 4 or not re.fullmatch(r"[a-z][a-z0-9_]+", cells[1]):
            continue
        eid = int(cells[0])
        if any(e["id"] == eid for e in output["effects"]):
            continue
        title = cells[3] if len(cells) >= 6 else cells[2]
        if title in ("—", "-", "0") or title.isdigit():
            title = cells[1]
        translated = names.get(title.casefold())
        output["effects"].append({"id": eid, "name": translated or DESCRIPTIVE.get(eid,title), "native": cells[1], "effectType": 71, "experimental": eid not in (1373, 1386), "translated": bool(translated), "translation_source":"游戏文本" if translated else "描述性译名，待核对"})
    for line in planets.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 4 and cells[0].isdigit() and cells[1].isdigit():
            title = cells[2]
            output["planets"].append({"id": int(cells[1]), "name": names.get(title.casefold(), title), "native": title})
    # Only short UI strings, not dialogue/lip-sync or entire text resources.
    output["strings"] = {key: value for key, value in strings.items() if isinstance(value, str) and 0 < len(value) <= 160 and "\t" not in value and "\n" not in value and re.search(r"[\u3400-\u9fff]", value)}
    return output


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    for name in ("effects", "planets", "english", "strings", "output"):
        p.add_argument("--"+name, type=Path, required=True)
    a = p.parse_args()
    result = build(a.effects.read_text("utf-8-sig"), a.planets.read_text("utf-8-sig"), json.loads(a.english.read_text("utf-8")), json.loads(a.strings.read_text("utf-8")))
    a.output.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(json.dumps({k: len(result[k]) for k in ("effects", "planets", "strings")}))
