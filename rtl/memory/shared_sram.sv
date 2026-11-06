/**
 * @file shared_sram.sv
 * @brief Shared Data SRAM (4 KB, 1024×32) with AXI4-Lite slave interface
 * @project Dual-Core RV32I SoC with Coherent Memory Subsystem
 * @doc_ref logic_design/08_memory_subsystem.md §8.3
 * @date Day 2, Task T2.3
 * 
 * The single source of truth for all coherent shared data (FR-5.1).
 * AXI4-Lite slave interface (write-through semantics).
 * Synchronous read (1-cycle latency absorbed by cache FSM).
 * Byte-writable via wstrb mask.
 * 
 * Size: 4 KB = 1024 × 32-bit words
 * Address: word-addressed via addr[11:2]
 * Responses: bvalid/rvalid assert 1 cycle after handshake
 */

module shared_sram (
  input  logic        clk,
  input  logic        rst_n,
  
  // AXI4-Lite Write Address Channel
  input  logic        awvalid,
  input  logic [31:0] awaddr,
  output logic        awready,
  
  // AXI4-Lite Write Data Channel
  input  logic        wvalid,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,     // Byte write mask
  output logic        wready,
  
  // AXI4-Lite Write Response Channel
  output logic        bvalid,
  output logic [1:0]  bresp,     // Always OKAY (2'b00)
  input  logic        bready,
  
  // AXI4-Lite Read Address Channel
  input  logic        arvalid,
  input  logic [31:0] araddr,
  output logic        arready,
  
  // AXI4-Lite Read Data Channel
  output logic        rvalid,
  output logic [31:0] rdata,
  output logic [1:0]  rresp,     // Always OKAY (2'b00)
  input  logic        rready
);

  // ==================== Memory Instance ====================
  logic [10:0] waddr_word;     // Word address (11-bit from addr[11:2] + extra)
  logic [10:0] raddr_word;     // Word address
  logic [31:0] rdata_internal;
  logic write_enable;
  
  // Extract word address (byte address [11:2] → word index [9:0])
  assign waddr_word = awaddr[11:2];
  assign raddr_word = araddr[11:2];

  sram_reg_array #(
    .DEPTH(1024),
    .WIDTH(32),
    .ASYNC_READ(0)        // Synchronous read (1-cycle latency)
  ) u_sram (
    .clk   (clk),
    .rst_n (rst_n),
    .raddr (raddr_word),
    .rdata (rdata_internal),
    .waddr (waddr_word),
    .wdata (wdata),
    .wmask (wstrb),
    .we    (write_enable)
  );

  // ==================== AXI Write Path ====================
  // Write happens when both AW and W channels are valid
  logic aw_ready_d;
  logic w_ready_d;
  logic write_occurred;

  // Write address handshake
  assign awready = ~aw_ready_d;  // Accept next AW if not already latched

  // Write data handshake
  assign wready = ~w_ready_d;    // Accept next W if not already latched

  // Write occurs when both channels have valid data and both are ready
  assign write_enable = (awvalid && aw_ready_d) && (wvalid && w_ready_d);
  assign write_occurred = write_enable;

  // Latch AW and W channels until write is complete
  logic [31:0] awaddr_q;
  logic [31:0] wdata_q;
  logic [3:0]  wstrb_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_ready_d <= 1'b0;
      w_ready_d  <= 1'b0;
      awaddr_q   <= 32'b0;
      wdata_q    <= 32'b0;
      wstrb_q    <= 4'b0;
    end else begin
      // Accept AW if valid and not already holding
      if (awvalid && !aw_ready_d) begin
        aw_ready_d <= 1'b1;
        awaddr_q   <= awaddr;
      end else if (write_occurred) begin
        aw_ready_d <= 1'b0;
      end

      // Accept W if valid and not already holding
      if (wvalid && !w_ready_d) begin
        w_ready_d <= 1'b1;
        wdata_q   <= wdata;
        wstrb_q   <= wstrb;
      end else if (write_occurred) begin
        w_ready_d <= 1'b0;
      end
    end
  end

  // Write response (bvalid asserts 1 cycle after write)
  logic bvalid_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bvalid_d <= 1'b0;
    end else begin
      bvalid_d <= write_occurred;
    end
  end

  assign bvalid = bvalid_d;
  assign bresp = 2'b00;  // Always OKAY

  // ==================== AXI Read Path ====================
  logic ar_ready_d;
  logic rvalid_d;
  logic [31:0] rdata_q;

  // Read address handshake
  assign arready = ~ar_ready_d;  // Accept next AR if not already latched

  // Latch AR channel
  logic [31:0] araddr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_ready_d <= 1'b0;
      araddr_q   <= 32'b0;
    end else begin
      if (arvalid && !ar_ready_d) begin
        ar_ready_d <= 1'b1;
        araddr_q   <= araddr;
      end else if (rvalid_d && rready) begin
        ar_ready_d <= 1'b0;
      end
    end
  end

  // Read data valid (1 cycle after AR handshake)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rvalid_d <= 1'b0;
      rdata_q  <= 32'b0;
    end else begin
      if (arvalid && !ar_ready_d) begin
        rvalid_d <= 1'b1;
        rdata_q  <= rdata_internal;
      end else if (rready) begin
        rvalid_d <= 1'b0;
      end
    end
  end

  assign rvalid = rvalid_d;
  assign rdata  = rdata_q;
  assign rresp  = 2'b00;  // Always OKAY

endmodule
