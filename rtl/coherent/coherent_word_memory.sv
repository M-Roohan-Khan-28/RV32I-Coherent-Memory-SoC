// Copyright (c) M. Roohan Khan and Talib. Apache-2.0; see repository LICENSE.
// Bounded two-requester, write-through coherent word memory reference implementation.
// The accepted request is the global ordering point. One request is outstanding.
module coherent_word_memory (
  input  logic        clk, rst_n,
  input  logic [1:0]  req_valid, req_write,
  input  logic [63:0] req_addr, req_wdata,
  input  logic [7:0]  req_strb,
  output logic [1:0]  req_ready,
  output logic [1:0]  rsp_valid, rsp_error,
  output logic [63:0] rsp_rdata,
  input  logic [1:0]  rsp_ready,
  input  logic        mem_ready,
  output logic [1:0]  inv_valid,
  output logic [63:0] inv_addr,
  input  logic [1:0]  inv_ack
);
  localparam logic [1:0] I=2'b00, S=2'b01, E=2'b10;
  typedef enum logic [1:0] {IDLE, WAIT_INV, WAIT_MEM, RESP} phase_t;
  phase_t phase;
  logic turn, owner, pending_write, pending_error, pending_mmio;
  logic [31:0] pending_addr, pending_data, response_data;
  logic [3:0] pending_strb;
  logic [31:0] memory [0:1023];
  logic [31:0] mmio_doorbell;
  logic [31:0] line_data [0:1][0:3];
  logic [27:0] line_tag [0:1][0:3];
  logic [1:0] line_state [0:1][0:3];
  logic line_valid [0:1][0:3];
  logic grant_valid, grant;
  logic [31:0] chosen_addr;
  logic chosen_write, chosen_error, chosen_mmio, other_hit;
  logic [1:0] chosen_idx;
  logic [27:0] chosen_tag;

  // Behavioral memory initializes for reproducible simulation; no hardware claim.
  initial begin
    for (integer k=0; k<1024; k=k+1) memory[k]=32'b0;
  end

  always_comb begin
    grant_valid = |req_valid;
    grant = turn;
    if (!req_valid[turn]) grant = ~turn;
    req_ready = 2'b00;
    if (phase == IDLE && grant_valid) req_ready[grant] = 1'b1;
    chosen_addr = grant ? req_addr[63:32] : req_addr[31:0];
    chosen_write = req_write[grant];
    chosen_mmio = (chosen_addr == 32'h1000_0000);
    chosen_error = (chosen_addr[1:0] != 2'b00) ||
                   ((chosen_addr >= 32'h0000_1000) && !chosen_mmio);
    chosen_idx = chosen_addr[3:2];
    chosen_tag = chosen_addr[31:4];
    other_hit = line_valid[~grant][chosen_idx] &&
                line_tag[~grant][chosen_idx] == chosen_tag &&
                line_state[~grant][chosen_idx] != I;
    inv_valid = 2'b00;
    inv_addr = 64'b0;
    if (phase == WAIT_INV) begin
      inv_valid[~owner] = 1'b1;
      if (owner) inv_addr[31:0] = pending_addr;
      else       inv_addr[63:32] = pending_addr;
    end
    rsp_valid = 2'b00;
    rsp_error = 2'b00;
    rsp_rdata = 64'b0;
    if (phase == RESP) begin
      rsp_valid[owner] = 1'b1;
      rsp_error[owner] = pending_error;
      if (owner) rsp_rdata[63:32] = response_data;
      else       rsp_rdata[31:0] = response_data;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= IDLE;
      turn <= 1'b0;
      owner <= 1'b0;
      pending_write <= 1'b0;
      pending_error <= 1'b0;
      pending_mmio <= 1'b0;
      pending_addr <= 32'b0;
      pending_data <= 32'b0;
      pending_strb <= 4'b0;
      response_data <= 32'b0;
      mmio_doorbell <= 32'b0;
      for (integer c=0; c<2; c=c+1)
        for (integer j=0; j<4; j=j+1) begin
          line_valid[c][j] <= 1'b0;
          line_state[c][j] <= I;
          line_tag[c][j] <= 28'b0;
          line_data[c][j] <= 32'b0;
        end
    end else begin
      case (phase)
        IDLE: if (grant_valid) begin
          owner <= grant;
          turn <= ~grant;
          pending_addr <= chosen_addr;
          pending_data <= grant ? req_wdata[63:32] : req_wdata[31:0];
          pending_strb <= grant ? req_strb[7:4] : req_strb[3:0];
          pending_write <= chosen_write;
          pending_error <= chosen_error;
          pending_mmio <= chosen_mmio;
          if (chosen_error) begin
            response_data <= 32'b0;
            phase <= RESP;
          end else if (chosen_write && !chosen_mmio && other_hit) begin
            phase <= WAIT_INV;
          end else begin
            phase <= WAIT_MEM;
          end
        end
        WAIT_INV: if (inv_ack[~owner]) begin
          line_valid[~owner][pending_addr[3:2]] <= 1'b0;
          line_state[~owner][pending_addr[3:2]] <= I;
          phase <= WAIT_MEM;
        end
        WAIT_MEM: if (mem_ready) begin
          if (pending_mmio) begin
            if (pending_write) begin
              for (integer b=0; b<4; b=b+1)
                if (pending_strb[b]) mmio_doorbell[b*8 +: 8] <= pending_data[b*8 +: 8];
              response_data <= 32'b0;
            end else response_data <= mmio_doorbell;
          end else if (pending_write) begin
            for (integer b=0; b<4; b=b+1)
              if (pending_strb[b]) memory[pending_addr[11:2]][b*8 +: 8] <= pending_data[b*8 +: 8];
            // Fill from merged data, independent of whether this was a cache hit.
            for (integer b=0; b<4; b=b+1)
              line_data[owner][pending_addr[3:2]][b*8 +: 8] <=
                pending_strb[b] ? pending_data[b*8 +: 8] : memory[pending_addr[11:2]][b*8 +: 8];
            line_tag[owner][pending_addr[3:2]] <= pending_addr[31:4];
            line_valid[owner][pending_addr[3:2]] <= 1'b1;
            line_state[owner][pending_addr[3:2]] <= E;
            response_data <= 32'b0;
          end else begin
            if (line_valid[owner][pending_addr[3:2]] &&
                line_tag[owner][pending_addr[3:2]] == pending_addr[31:4] &&
                line_state[owner][pending_addr[3:2]] != I)
              response_data <= line_data[owner][pending_addr[3:2]];
            else begin
              response_data <= memory[pending_addr[11:2]];
              line_data[owner][pending_addr[3:2]] <= memory[pending_addr[11:2]];
              line_tag[owner][pending_addr[3:2]] <= pending_addr[31:4];
              line_valid[owner][pending_addr[3:2]] <= 1'b1;
              line_state[owner][pending_addr[3:2]] <= S;
              if (line_valid[~owner][pending_addr[3:2]] &&
                  line_tag[~owner][pending_addr[3:2]] == pending_addr[31:4] &&
                  line_state[~owner][pending_addr[3:2]] == E)
                line_state[~owner][pending_addr[3:2]] <= S;
            end
          end
          phase <= RESP;
        end
        RESP: if (rsp_ready[owner]) phase <= IDLE;
        default: phase <= IDLE;
      endcase
    end
  end
endmodule
