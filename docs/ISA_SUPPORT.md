# Processor instruction evidence boundary

The executed staged and concurrent actual-core programs use `ADDI`, `LW`,
`SW` and `JAL` within the small directed subset described in
[ARCHITECTURE.md](ARCHITECTURE.md). Register comparisons and final memory
checks validate those particular programs and operand values. They do not
constitute an instruction retirement trace or complete ISA compliance.

The inherited core source contains further decode/ALU paths, but this task
has not independently verified every immediate, branch, signed/unsigned
corner, alignment/exception or privileged/CSR behavior. Those paths are
**implemented or inherited but unqualified** until a separate instruction
matrix and retirement-based reference model run. Full RV32I verification
remains a separate milestone; no general ISA badge is inferred from the
coherent-memory regressions.
