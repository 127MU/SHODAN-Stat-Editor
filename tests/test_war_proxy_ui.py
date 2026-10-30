"""Native variants UI smoke test with isolated profile; never starts the proxy."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    profile = out / "profile"
    profile.mkdir()
    (profile / "huskar-ui.ini").write_text("[General]\nqaWarProxyOnly=true\n", encoding="utf-8")
    env = dict(os.environ, SHODAN_PROFILE=str(profile), SHODAN_HUSKAR_QA=str(out), SHODAN_QA_OUTPUT=str(out), TEMP=str(out), TMP=str(out))
    proc = subprocess.Popen([str(args.exe.resolve())], cwd=args.exe.resolve().parent, env=env)
    try:
        code = proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
        raise
    result = json.loads((out / "report.json").read_text(encoding="utf-8"))
    assert code == 0 and not result["error"], result
    log = (profile / "Logs/huskar-startup.log").read_text(encoding="utf-8", errors="replace")
    problems = [line for line in log.splitlines() if any(s in line for s in ("ReferenceError:", "TypeError:", "Binding loop", "Unable to assign", "Cannot assign", "Failed to link shader"))]
    assert not problems, problems
    assert len(list(out.glob("war-proxy-*.png"))) == 5
    saved=json.loads((profile/"war-targets.json").read_text("utf-8"))
    assert len(saved["targets"])==2 and saved["targets"][1]["enabled"] is False
    defense=next(t for t in saved["targets"] if t["planet"]==93)
    assert defense["campaign_type"]==4 and defense["defense_level"]==38 and defense["defense_source"]==157
    assert not (profile / "war-proxy/ca").exists(), "UI smoke test must not start MITM/certificate generation"
    print(json.dumps({"variants_page": True, "dark_light": True, "saved_plan": True, "auto_start": False, "game_writes": 0}))


if __name__ == "__main__":
    main()
