# Bounded coherent word-memory architecture

The tested subsystem is a separate reference implementation. It does not replace the inherited `riscv_soc_top` integration. Its interface uses two request and response lanes, an external memory-ready input, and explicit invalidation-valid/acknowledge lanes. All request and response payloads are 32-bit words; byte strobes apply to writes. The global address space is 32 bits.

## Storage and ordering

RAM occupies aligned addresses `0x0000_0000` through `0x0000_0ffc` (1024 words). Each requester has four direct-mapped cache entries. An entry covers one 32-bit word, with index `addr[3:2]` and tag `addr[31:4]`. `0x1000_0000` is one uncached doorbell word. Other addresses and unaligned accesses return an error without changing state.

`req_valid && req_ready` is the global ordering point. Arbitration alternates the preferred requester after each acceptance. The machine accepts no other request until the first response is consumed. `mem_ready` controls when RAM or doorbell operation completes. A response remains valid until its owner asserts `rsp_ready`. This bounded serialization gives a total order without assuming a predetermined winner for simultaneous requests.

The cache states are `I` (invalid), `S` (shared clean) and `E` (clean exclusive-owner). `E` is **not dirty**: every accepted write updates RAM before its response. A write to an address present in the other cache holds an invalidation request until `inv_ack`; only then does it update RAM and its own cache. A miss that reads a word owned in `E` by the other cache changes that line to `S` and fills the requesting cache in `S`. A read hit returns its own line. A conflicting tag replaces a line without a writeback. No snoop race occurs because the request engine is serialized.

Reset clears arbitration, pending response, cache entries and doorbell. RAM persists. An outstanding request is cancelled; if reset arrives after an accepted invalidation but before the memory write, the other cache may have been invalidated, while RAM retains its previous value. The test covers reset during a stalled write before invalidation or RAM update.

## Processor program harness

`tb/tb_two_core_programs.sv` connects two inherited `rv32i_core` instances through separate `core_request_bridge` instances to the requester lanes, with private instruction arrays and a deterministic delayed `mem_ready`. The inherited core emits a one-cycle request while entering its stall state. The bridge captures address, data, strobe and direction, holds them until `req_valid && req_ready`, then tracks the distinct response handshake before asserting the core acknowledge. Core 0 first stores 42, then loads 42. Core 1 is released after that handshake and loads 42, increments it to 43, stores it, and loads 43. The test then changes core 0's terminal loop instruction into one final load, which must read 43. The instruction words use ADDI, SW, LW and JAL; no other ISA behavior is claimed. The core's PC holds while its memory request waits, and load writeback occurs on the response handshake.

The staged program test checks all 32 registers of each core, the final shared RAM word, six accepted/completed memory operations, read data against a separate software word model, response ownership, and PC stability during observed wait cycles. A second actual-core program starts both processors together; each stores and loads a different word. It requires exactly two acceptances and completions per core, both requesters valid together, observed busy wait edges, correct final RAM/registers and bounded progress. The separate synthetic request-generator test remains and covers simultaneous same-address requests, eight seeded simultaneous pairs and arbitration while memory is not ready. The pending lane remains valid until it receives a round-robin grant; the scoreboard follows the observed acceptance order.

This is a behavioral simulation milestone. It is not an AXI adapter, production SRAM macro, write-back coherence protocol or verified integration of the inherited full processor/peripheral top.
