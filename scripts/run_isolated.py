#!/usr/bin/env python3
"""Run one bounded coherent/bridge scenario with optional fault source or VCD."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def tool(name):
    prefix = os.environ.get("MODELSIM_BIN")
    choices = ([str(Path(prefix) / (name + ".exe")), str(Path(prefix) / name)]
               if prefix else []) + [name, name + ".exe"]
    for choice in choices:
        found = shutil.which(choice)
        if found:
            return found
    raise RuntimeError("Missing simulator tool: " + name)


def invoke(argv, cwd, logfile, timeout=120):
    try:
        process = subprocess.run(argv, cwd=cwd, capture_output=True,
                                 timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        logfile.write_bytes((exc.stdout or b"") + (exc.stderr or b""))
        raise RuntimeError("Command timed out after %d seconds" % timeout) from exc
    raw = process.stdout + process.stderr
    logfile.write_bytes(raw)
    return process.returncode, raw.decode("utf-8", errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output-dir", type=Path, required=True)
    ap.add_argument("--top", choices=("bridge", "reset_commit", "shared_store", "shared_read_write"),
                    required=True)
    ap.add_argument("--bridge-source", type=Path, help="disposable fault override")
    ap.add_argument("--memory-source", type=Path, help="disposable fault override")
    ap.add_argument("--capture-wave", action="store_true")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    if out.exists():
        raise RuntimeError("Output directory exists: " + str(out))
    out.mkdir(parents=True)
    bridge = (args.bridge_source or root / "rtl/coherent/core_request_bridge.sv").resolve()
    memory = (args.memory_source or root / "rtl/coherent/coherent_word_memory.sv").resolve()
    sources = [root / "rtl/core" / name for name in
               ("alu.sv", "reg_file.sv", "control_unit.sv", "rv32i_core.sv")]
    sources += [memory, bridge, root / "tb/tb_core_request_bridge.sv",
                root / "tb/tb_coherent_reset_commit.sv", root / "tb/tb_two_core_shared.sv"]
    top = {"bridge": "tb_core_request_bridge",
           "reset_commit": "tb_coherent_reset_commit",
           "shared_store": "tb_two_core_shared",
           "shared_read_write": "tb_two_core_shared"}[args.top]
    report = {
        "repository": "RV32I-Coherent-Memory-SoC",
        "source_revision": subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
        "source_dirty": bool(subprocess.check_output(
            ["git", "-C", str(root), "status", "--porcelain"])),
        "sources": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                    for p in sources],
        "case": args.top, "timeout_seconds_per_command": 120,
        "simulations": [], "overall": "FAIL"
    }
    started = time.monotonic()
    try:
        vlib, vlog, vsim = (tool(n) for n in ("vlib", "vlog", "vsim"))
        report["simulator_version"] = invoke([vsim, "-version"], out,
                                              out / "version.log")[1].strip()
        if invoke([vlib, "work"], out, out / "library.log")[0]:
            raise RuntimeError("vlib failed")
        code, log = invoke([vlog, "-sv", *map(str, sources)], out,
                           out / "compile.log")
        if code or "Errors: 0, Warnings: 0" not in log:
            raise RuntimeError("vlog failed or reported diagnostics")
        command = [vsim, "-c", "-onfinish", "exit", top]
        if args.top == "shared_read_write":
            command.append("+READ_WRITE")
        do = "run -all; quit -code 0"
        if args.capture_wave:
            pins = ({
                "bridge": "clk rst_n core_req core_we req_valid req_ready rsp_valid rsp_ready core_ack core_err",
                "reset_commit": "clk rst_n mem_ready req_valid req_ready rsp_valid rsp_ready inv_valid",
                "shared_store": "clk reset_n mem_ready core_req req_valid req_ready rsp_valid rsp_ready core_ack inv_valid inv_ack",
                "shared_read_write": "clk reset_n mem_ready core_req req_valid req_ready rsp_valid rsp_ready core_ack inv_valid inv_ack",
            })[args.top].split()
            do = ("vcd file scenario.vcd; " + "; ".join(
                "vcd add /" + top + "/" + pin for pin in pins) + "; " + do)
        command += ["-do", do]
        code, log = invoke(command, out, out / "simulation.log")
        item = {"top": top, "command": command, "simulator_exit_code": code,
                "status": "FAIL"}
        report["simulations"].append(item)
        markers = {
            "bridge": r"BRIDGE_CONTRACT_PASS checks=159 accepted=4 completed=3 aborted=1 stalls=14",
            "reset_commit": r"RESET_COMMIT_PASS checks=163 accepted=8 completed=5 aborted=3 commits=3 resets=5",
            "shared_store": r"PASS TWO_CORE_SHARED mode=store_store checks=106 accepted=2/2 completed=2/2 simultaneous=1 busy_waits=26 invalidation_waits=2",
            "shared_read_write": r"PASS TWO_CORE_SHARED mode=read_write checks=106 accepted=2/2 completed=2/2 simultaneous=1 busy_waits=25 invalidation_waits=2",
        }
        marker = markers[args.top]
        if (code or re.search(r"\*\*\s+(?:Error|Fatal):", log) or
                "# Errors: 0, Warnings: 0" not in log or "$finish" not in log or
                len(re.findall(marker, log)) != 1):
            raise RuntimeError("Simulation failed or exact scenario marker missing")
        item["status"] = "PASS"
        item["marker"] = marker
        if args.capture_wave:
            vcd = out / "scenario.vcd"
            if not vcd.is_file() or not vcd.stat().st_size:
                raise RuntimeError("Requested VCD missing")
            report["waveform"] = {"path": str(vcd),
                                  "sha256": hashlib.sha256(vcd.read_bytes()).hexdigest()}
            names = [top + "." + pin + ("*" if pin in
                     {"req_valid", "req_ready", "rsp_valid", "rsp_ready", "inv_valid",
                      "inv_ack", "core_req", "core_ack"} else "") for pin in pins]
            render = [sys.executable, str(root / "tools/vcd_to_svg.py"),
                      "--vcd", str(vcd), "--signals", *names,
                      "--output", str(out / "scenario.svg"), "--origin", "simulator",
                      "--title", "Measured coherent " + args.top]
            if invoke(render, out, out / "render.log")[0]:
                raise RuntimeError("VCD render failed")
        report["overall"] = "PASS"
        print("COHERENT_ISOLATED_PASS " + args.top)
    except Exception as exc:
        report["error"] = str(exc)
        print("FAIL: " + str(exc), file=sys.stderr)
    finally:
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n",
                                          encoding="utf-8")
    return 0 if report["overall"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
