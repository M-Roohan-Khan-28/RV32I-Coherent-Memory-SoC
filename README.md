# RV32I Coherent Memory SoC

This repository preserves the [Talib reference project](https://github.com/sha1kh-talib/RISC-V-SoC-with-Coherent-Memory-Subsystem) and its Git history under Apache-2.0. The **tested milestone** is a bounded two-requester coherent word-memory subsystem in `rtl/coherent/coherent_word_memory.sv`. The inherited full processor SoC remains experimental and is **not** included in the passing claim.

## Tested scope

- Two requesters, one globally ordered request at a time, round-robin selection when both request together.
- 4 KiB shared behavioral RAM with byte writes and two four-line, direct-mapped, one-word caches.
- Write-through updates; `I` invalid, `S` shared clean and `E` clean exclusive-owner state. This is not an MSI write-back implementation.
- A write waits for an acknowledged invalidation of the other cache's matching line. Read sharing downgrades an exclusive line to shared. Cache lines evict cleanly.
- The single `0x1000_0000` doorbell word bypasses both caches. Other out-of-range or unaligned addresses return an error. Reset cancels an in-flight request, clears cache state and doorbell, and preserves RAM.
- `mem_ready`, invalidation acknowledgement and response ready can stall independently. The behavioral RAM initializes to zero for deterministic simulation; no synthesis claim is made.

The accepted request is the ordering point. Because only one request can be outstanding, response and memory updates follow that order. Requesters hold payloads until `req_ready`; they consume responses with `rsp_ready`. See [architecture](docs/ARCHITECTURE.md).

## Reproduce

On Windows with ModelSim Intel FPGA Starter Edition 2020.1:

```powershell
$env:MODELSIM_BIN = 'C:\intelFPGA\20.1\modelsim_ase\win32aloem'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_coherent.ps1 -OutputDir build/coherent-fresh-1
```

Choose a new output directory for each run. The script writes `compile.log`, `simulation.log` and `results.json`, and returns nonzero for a compile error, fatal test, missing result marker, timeout or missing simulator. The test uses a separate reference memory and checks accepted requests, responses, cached data and ownership. The published `c228a38` clean-clone run passed 63 scenarios and 1,254 checks; see [verification status](docs/VERIFICATION_STATUS.md) for raw evidence and gaps.

## Source and limitations

The original `rtl/`, `tb/tb_directed_final.sv`, `tb/uvm/`, physical-design files and reports remain in their Git ancestry. The original directed bench contains unconditional passing placeholders and does not compile under the available ModelSim version; it is excluded from the verified milestone. The new test does not establish full SoC behavior, processor program execution, AXI protocol compliance, timing closure, synthesis or hardware operation. See [provenance](docs/PROVENANCE.md) and the repository [LICENSE](LICENSE).
