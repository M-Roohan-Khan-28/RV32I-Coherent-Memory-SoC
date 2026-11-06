# Verification status

## New bounded subsystem

Required command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_coherent.ps1 -OutputDir <fresh-directory>` with `MODELSIM_BIN` pointing to ModelSim Intel FPGA Starter Edition 2020.1. The wrapper requires an actual pass marker, zero simulator errors, at least 63 scenarios, at least 100 checks and the expected reset-aborted transaction. It checks the process exit codes and times out each tool after 120 seconds. The bench has its own 20,000-cycle timeout and per-transaction bounds. ModelSim itself can return process exit 0 after `$fatal`, so transcript errors and the marker are required too.

The independent oracle is a byte-addressable word array plus a doorbell value. It takes requests at acceptance and applies writes only at successful response. It does not use the DUT's RAM, cache data, FSM or pending registers to form expected data. After every directed or seeded operation it additionally checks each cache line against the oracle and checks that two caches never both own the same address exclusively.

Directed scenarios cover cross-core visibility, shared reads, ownership transfer, held invalidation, alternating and simultaneous same-address writes, independent addresses, conflicting tags and clean eviction, byte strobes, MMIO bypass, address errors, stalled memory and response, and reset cancellation. Forty deterministic operations use seed `0x28A6BEEF`. The concurrent pairs are checked in observed acceptance order with an independent round-robin assertion. This is scenario/check-count evidence, not measured functional or code coverage.

Publication evidence will record the exact tested commit and clean-clone result. Until then, local uncommitted runs are development evidence only.

## Inherited full SoC

The pinned reference revision is `fe127cc508dda01851fd4c705f04aeaf62c4ecca`. Its original `Makefile` pointed to a nonexistent directed bench path. The actual `tb/tb_directed_final.sv` includes seven unconditional `pass = 1'b1` cases and other prose claims that are not evidence. This original bench remains unchanged as historical source. The inherited RTL initially failed ModelSim compilation because `shared_sram.sv` referenced `write_enable` before its declaration; the declaration was moved in this milestone. With that repair, all local RTL compiles with 0 errors and 0 warnings, but this is **compile only**.

Attempting to compile the inherited full-SoC directed bench with ModelSim 2020.1 produced exit 2 and 24 errors, including illegal declarations after statements and implicitly static initialized task variables (`build/full-soc-preflight-2/compile.log` in the development workspace). The original UVM environment and end-to-end two-core programs have not been run. Upstream claims in older reports and historical physical-design artifacts have not been reproduced by this work. No processor, timing, synthesis, FPGA or full-system result is claimed.

Remaining work: repair the inherited directed environment without deleting its historical source, replace each placeholder with a real comparison, run two-core programs with an architectural reference, and validate the integrated bus/cache subsystem. A separate synthesis flow would be required for implementation claims.
