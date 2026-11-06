/**
 * @file rv32i_core.sv
 * @brief RV32I Single-Cycle CPU Core (2 instances for dual-core SoC)
 * @project Dual-Core RV32I SoC with Coherent Memory Subsystem
 * @doc_ref logic_design/03_core_datapath_and_control.md
 * @date Day 1, Tasks T1.10–T1.11
 * 
 * Integrates:
 * - ALU (arithmetic/logical operations)
 * - Register File (x0–x31)
 * - Control Unit (instruction decoder)
 * - PC Logic (program counter mux + register)
 * 
 * Implements single-cycle datapath with req/ack stall on memory operations.
 * Synchronous execution: all register updates on clock edge.
 * Memory operations stall the core (RUN/STALL_MEM 2-state FSM).
 */

module rv32i_core #(
  parameter RESET_PC = 32'h0000_0000   // Reset program counter
) (
  input  logic        clk,              // System clock
  input  logic        rst_n,            // Async reset (active-low)

  // Instruction Memory Interface (private I-SRAM, async read)
  output logic [31:0] imem_addr,        // Instruction fetch address
  input  logic [31:0] imem_rdata,       // Instruction data (combinational)

  // Data Memory Interface (to cache manager, req/ack)
  output logic        dmem_req,         // Data memory request
  output logic        dmem_we,          // Write enable (1=store, 0=load)
  output logic [31:0] dmem_addr,        // Address
  output logic [31:0] dmem_wdata,       // Write data
  output logic [3:0]  dmem_wmask,       // Byte write mask
  input  logic [31:0] dmem_rdata,       // Read data
  input  logic        dmem_ack,         // Acknowledgment (transaction complete)
  input  logic        dmem_err          // Error flag
);

  // ==================== Internal Registers & Wires ====================

  // Program Counter (registered)
  logic [31:0] pc_current;              // PC in current cycle
  logic [31:0] pc_next;                 // PC for next cycle
  logic [31:0] pc_plus_4;               // PC + 4 (for link register)

  // Instruction word (latched from I-SRAM)
  logic [31:0] instr;                   // Current instruction

  // Register File signals
  logic [31:0] rs1_data, rs2_data;      // Register file read outputs
  logic [4:0]  rs1_addr, rs2_addr;      // Register file read addresses
  logic [4:0]  rd_addr;                 // Register write address
  logic [31:0] rd_data;                 // Register write data
  logic        rd_we;                   // Register write enable

  // ALU signals
  logic [31:0] alu_operand_a;
  logic [31:0] alu_operand_b;
  logic [3:0]  alu_func;
  logic [31:0] alu_result;
  logic        alu_zero;

  // Control signals
  logic [3:0]  alu_func_cu;
  logic        rf_we_cu;
  logic [4:0]  rf_wa_cu;
  logic [1:0]  rf_wd_sel_cu;
  logic        dmem_req_cu;
  logic        dmem_we_cu;
  logic [1:0]  pc_sel_cu;
  logic [31:0] imm_cu;
  logic [3:0]  ls_ctrl;
  logic        is_branch;
  logic        is_jump;

  // Load/Store processing
  logic [31:0] dmem_wdata_processed;    // Byte-rotated store data
  logic [3:0]  dmem_wmask_processed;    // Byte mask for store
  logic [31:0] dmem_rdata_resized;      // Load data resized/sign-extended

  // Branch condition resolution
  logic        branch_taken;
  logic [2:0]  func3;

  // Core FSM (RUN/STALL_MEM)
  typedef enum logic {
    RUN       = 1'b0,
    STALL_MEM = 1'b1
  } core_state_t;

  core_state_t core_state;
  core_state_t core_state_next;

  // ==================== PC Management ====================

  // Instruction fetch address (combinational from current PC)
  assign imem_addr = pc_current;

  // PC is updated synchronously at end of cycle
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_current <= RESET_PC;
    end else if ((core_state == RUN && (!dmem_req_cu || dmem_ack)) ||
                 (core_state == STALL_MEM && dmem_ack)) begin
      pc_current <= pc_next;
    end
  end

  // Latch instruction on fetch (combinational for single-cycle, but registered in practice)
  assign instr = imem_rdata;

  // ==================== Instruction Field Extraction ====================

  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign func3    = instr[14:12];

  // ==================== Register File ====================

  reg_file u_rf (
    .clk   (clk),
    .rst_n (rst_n),
    .wa    (rd_addr),
    .wd    (rd_data),
    .we    (rd_we),
    .ra    (rs1_addr),
    .rd_a  (rs1_data),
    .rb    (rs2_addr),
    .rd_b  (rs2_data)
  );

  // ==================== Control Unit (Instruction Decoder) ====================

  control_unit u_cu (
    .instr      (instr),
    .alu_func   (alu_func_cu),
    .rf_we      (rf_we_cu),
    .rf_wa      (rd_addr),  // Already extracted
    .rf_wd_sel  (rf_wd_sel_cu),
    .dmem_req   (dmem_req_cu),
    .dmem_we    (dmem_we_cu),
    .pc_sel     (pc_sel_cu),
    .imm        (imm_cu),
    .ls_ctrl    (ls_ctrl),
    .is_branch  (is_branch),
    .is_jump    (is_jump)
  );

  // ==================== ALU ====================

  // ALU operands:
  // - Operand A: always RS1
  // - Operand B: RS2 for R-type, immediate for I-type (control_unit determines which to pass)
  
  assign alu_operand_a = rs1_data;
  
  // Operand B selection (simplified: assume control unit sets imm field appropriately)
  // Full implementation would have a MUX here, but we delegate to control_unit
  assign alu_operand_b = (instr[6:0] == 7'b0110011) ? rs2_data : imm_cu;  // R-type uses rs2, others use imm

  assign alu_func = alu_func_cu;

  alu u_alu (
    .a      (alu_operand_a),
    .b      (alu_operand_b),
    .func   (alu_func),
    .result (alu_result),
    .zero   (alu_zero)
  );

  // ==================== PC Mux (Branch/Jump Resolution) ====================

  // Branch condition resolution (check func3 and ALU result)
  always_comb begin
    branch_taken = 1'b0;

    if (is_branch) begin
      case (func3)
        3'b000:  branch_taken = alu_zero;           // BEQ: take if equal (zero)
        3'b001:  branch_taken = ~alu_zero;          // BNE: take if not equal
        3'b100:  branch_taken = alu_result[0];      // BLT: take if a < b (SLT result)
        3'b101:  branch_taken = ~alu_result[0];     // BGE: take if a >= b
        3'b110:  branch_taken = alu_result[0];      // BLTU: take if a < b unsigned
        3'b111:  branch_taken = ~alu_result[0];     // BGEU: take if a >= b unsigned
        default: branch_taken = 1'b0;
      endcase
    end
  end

  // PC mux: select next PC
  logic [1:0] pc_sel_final;
  assign pc_sel_final = (is_branch && !branch_taken) ? 2'b00 : pc_sel_cu;  // If branch not taken, PC+4

  // PC+4 calculation
  assign pc_plus_4 = pc_current + 32'd4;

  // PC mux logic
  always_comb begin
    case (pc_sel_final)
      2'b00:   pc_next = pc_plus_4;                        // Sequential (PC+4)
      2'b01:   pc_next = pc_current + imm_cu;              // Branch or JAL
      2'b10:   pc_next = rs1_data + imm_cu;                // JALR
      2'b11:   pc_next = RESET_PC;                         // Reset
      default: pc_next = pc_plus_4;
    endcase
  end

  // ==================== Data Memory Interface ====================

  // Load/Store data processing
  // Extract address and data based on instruction type

  // Store data rotation (based on addr[1:0] and store size)
  logic [1:0] addr_offset;
  assign addr_offset = alu_result[1:0];

  always_comb begin
    // Default: word-sized, no rotation
    dmem_wdata_processed = rs2_data;
    dmem_wmask_processed = 4'b1111;

    if (dmem_we_cu && instr[6:0] == 7'b0100011) begin  // STORE
      case (func3)
        3'b000: begin  // SB (byte store)
          dmem_wmask_processed = 4'b0001 << addr_offset;
          case (addr_offset)
            2'b00:   dmem_wdata_processed = {24'b0, rs2_data[7:0]};
            2'b01:   dmem_wdata_processed = {16'b0, rs2_data[7:0], 8'b0};
            2'b10:   dmem_wdata_processed = {8'b0, rs2_data[7:0], 16'b0};
            2'b11:   dmem_wdata_processed = {rs2_data[7:0], 24'b0};
          endcase
        end
        3'b001: begin  // SH (halfword store)
          dmem_wmask_processed = 4'b0011 << {addr_offset[1], 1'b0};
          if (addr_offset[1]) begin
            dmem_wdata_processed = {rs2_data[15:0], 16'b0};
          end else begin
            dmem_wdata_processed = {16'b0, rs2_data[15:0]};
          end
        end
        3'b010: begin  // SW (word store)
          dmem_wmask_processed = 4'b1111;
          dmem_wdata_processed = rs2_data;
        end
      endcase
    end
  end

  // Load data resizing and sign-extension
  always_comb begin
    dmem_rdata_resized = dmem_rdata;  // Default: full word

    if (!dmem_we_cu && instr[6:0] == 7'b0000011) begin  // LOAD
      case (func3)
        3'b000: begin  // LB (byte load, signed)
          case (addr_offset)
            2'b00:   dmem_rdata_resized = {{24{dmem_rdata[7]}}, dmem_rdata[7:0]};
            2'b01:   dmem_rdata_resized = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
            2'b10:   dmem_rdata_resized = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
            2'b11:   dmem_rdata_resized = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
          endcase
        end
        3'b001: begin  // LH (halfword load, signed)
          if (addr_offset[1]) begin
            dmem_rdata_resized = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
          end else begin
            dmem_rdata_resized = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
          end
        end
        3'b010: begin  // LW (word load)
          dmem_rdata_resized = dmem_rdata;
        end
        3'b100: begin  // LBU (byte load, unsigned)
          case (addr_offset)
            2'b00:   dmem_rdata_resized = {24'b0, dmem_rdata[7:0]};
            2'b01:   dmem_rdata_resized = {24'b0, dmem_rdata[15:8]};
            2'b10:   dmem_rdata_resized = {24'b0, dmem_rdata[23:16]};
            2'b11:   dmem_rdata_resized = {24'b0, dmem_rdata[31:24]};
          endcase
        end
        3'b101: begin  // LHU (halfword load, unsigned)
          if (addr_offset[1]) begin
            dmem_rdata_resized = {16'b0, dmem_rdata[31:16]};
          end else begin
            dmem_rdata_resized = {16'b0, dmem_rdata[15:0]};
          end
        end
      endcase
    end
  end

  // ==================== Write-Back Mux ====================
  // Select source of register write data based on rf_wd_sel

  always_comb begin
    case (rf_wd_sel_cu)
      2'b00:   rd_data = alu_result;              // ALU result
      2'b01:   rd_data = dmem_rdata_resized;      // Load data
      2'b10:   rd_data = pc_plus_4;               // PC+4 (JAL/JALR link)
      2'b11:   rd_data = 32'b0;                   // Reserved
      default: rd_data = 32'b0;
    endcase
  end

  // ==================== Core FSM (RUN / STALL_MEM) ====================

  // 2-state FSM: RUN (fetch/decode/execute) or STALL_MEM (wait for dmem_ack)

  always_comb begin
    core_state_next = core_state;

    case (core_state)
      RUN: begin
        // If instruction requests memory and no ack yet, go to STALL_MEM
        if (dmem_req_cu && !dmem_ack) begin
          core_state_next = STALL_MEM;
        end
      end

      STALL_MEM: begin
        // Wait for memory acknowledge
        if (dmem_ack) begin
          core_state_next = RUN;
        end
      end
    endcase
  end

  // FSM register update
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_state <= RUN;
    end else begin
      core_state <= core_state_next;
    end
  end

  // ==================== Output Assignments ====================

  // Data memory interface (only assert dmem_req when in RUN state)
  assign dmem_req   = dmem_req_cu && (core_state == RUN);
  assign dmem_we    = dmem_we_cu && (core_state == RUN);
  assign dmem_addr  = alu_result;
  assign dmem_wdata = dmem_wdata_processed;
  assign dmem_wmask = dmem_wmask_processed;

  // Register write enable (only when not stalled)
  assign rd_we = rf_we_cu && !dmem_err &&
                 ((core_state == RUN && !dmem_req_cu) ||
                  (core_state == STALL_MEM && dmem_ack));

  // ==================== Debug / Visibility (optional synthesis warnings ignored) ====================
  // These would be useful for simulation/debugging but removed for synthesis

  // pragma translate_off
  // Uncomment for debug output:
  // always @(posedge clk) begin
  //   if (rf_we) $display("[Core] WB: x%0d = 0x%08x @ PC=0x%08x", rd_addr, rd_data, pc_current);
  // end
  // pragma translate_on

endmodule
