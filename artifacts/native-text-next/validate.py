"""Run C/D regressions, then serialized real host and Pad++ workflows."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/"vendor/aurora-d-0.4.5"
BUILD=ROOT/"build-validation/native-text-next/validation"


def run(command,cwd=ROOT,env=None):
    r=subprocess.run([str(x) for x in command],cwd=cwd,env=env,capture_output=True,
                     text=True,encoding="utf-8",errors="replace")
    return {"command":[str(x) for x in command],"exit_code":r.returncode,"output":r.stdout+r.stderr}


def environment(profile):
    env=os.environ.copy()
    for name in ("AURORA_HINTING","AURORA_TEXT_COVERAGE","AURORA_TEXT_CONTRAST","AURORA_TEXT_EXPERIMENT"):
        env.pop(name,None)
    if profile=="D":env["AURORA_TEXT_EXPERIMENT"]="native-next"
    return env


def focused(name,source,unit=False):
    out=BUILD/name;out.mkdir(parents=True,exist_ok=True);exe=out/(name+".exe")
    command=["dmd","-i","-I"+str(CORE/"source"),"-od="+str(out),"-of="+str(exe)]
    command += ["-unittest","-main"] if unit else ["-version=AuroraHeadless"]
    records=[run([*command,str(CORE/source),"user32.lib","gdi32.lib"],CORE)]
    if records[-1]["exit_code"]==0:
        for profile in (("C",) if unit else ("C","D")):
            record=run([exe],CORE,environment(profile));record["profile"]=profile;records.append(record)
    print(name,"passed" if all(r["exit_code"]==0 for r in records) else "FAILED",flush=True)
    return {"name":name,"records":records}


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures=[pool.submit(focused,*case) for case in (
            ("coverage","tests/text_coverage.d"),("font-quality","tests/font_quality_regression.d"),
            ("dpi","tests/dpi_rendering.d"),("window-dpi","tests/window_dpi_regression.d"),
            ("hinter-unit","source/aurora/text/hinter.d",True),
            ("rasterizer-unit","source/aurora/text/rasterizer.d",True),
            ("hinting-windows","tests/hinting_windows_regression.d"))]
        checks=[future.result() for future in futures]
    for name,command in (("standards",[sys.executable,"scripts/audit-aurora-standards.py"]),
                         ("python",[sys.executable,"-W","ignore","-m","unittest",
                                    "scripts.tests.test_font_comparison","scripts.tests.test_aurora_standards_audit"])):
        record=run(command);checks.append({"name":name,"records":[record]})
        print(name,record["exit_code"],flush=True)
    host=ROOT/"build-validation/native-text-next/host-release/aurora-host-experiment.exe"
    for profile in ("C","D"):
        env=environment(profile)
        record=run([sys.executable,"experiments/aurora-host/tools/verify_experiment.py"],env=env)
        checks.append({"name":"host-verifier-"+profile,"records":[record]})
        print("host",profile,record["exit_code"],flush=True)
        env["AURORA_HOST_EXE"]=str(host)
        record=run([sys.executable,"-u","-B","padpp.py","--self-test","--host",host],
                   ROOT/"experiments/aurora-host-notepadpp",env)
        checks.append({"name":"padpp-"+profile,"records":[record]})
        print("Pad++",profile,record["exit_code"],flush=True)
        for suffix in (".png","-metrics.json"):
            source=ROOT/("experiments/aurora-host-notepadpp/build/padpp"+suffix)
            if source.exists():(HERE/("padpp-live-"+profile+suffix)).write_bytes(source.read_bytes())
    data={"default":"approved C","D_override":"AURORA_TEXT_EXPERIMENT=native-next","checks":checks,
          "host_release_sha256":hashlib.sha256(host.read_bytes()).hexdigest(),
          "known_failure":"Older Notepad's existing drag/restore full-smoke failure remains outside this text work."}
    (HERE/"validation.json").write_text(json.dumps(data,indent=2),encoding="utf-8")
    return int(any(r["exit_code"] for c in checks for r in c["records"]))


if __name__=="__main__":raise SystemExit(main())
