`timescale 1ns/1ps
// Captures the inherited core's one-cycle memory request and presents a
// held valid/payload until the coherent subsystem accepts it. Acceptance
// and the later response are separate events; only the response acks the core.
module core_request_bridge (
  input  logic        clk, rst_n,
  input  logic        core_req, core_we,
  input  logic [31:0] core_addr, core_wdata,
  input  logic [3:0]  core_wmask,
  output logic        core_ack, core_err,
  output logic [31:0] core_rdata,
  output logic        req_valid, req_write,
  output logic [31:0] req_addr, req_wdata,
  output logic [3:0]  req_strb,
  input  logic        req_ready,
  input  logic        rsp_valid, rsp_error,
  input  logic [31:0] rsp_rdata,
  output logic        rsp_ready
);
  logic pending, in_flight;
  assign req_valid = core_req;
  assign rsp_ready = in_flight;
  assign core_ack = in_flight && rsp_valid;
  assign core_err = core_ack && rsp_error;
  assign core_rdata = rsp_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending <= 0;
      in_flight <= 0;
      req_write <= 0;
      req_addr <= 0;
      req_wdata <= 0;
      req_strb <= 0;
    end else begin
      if (core_req && !pending && !in_flight) begin
        req_write <= core_we;
        req_addr <= core_addr;
        req_wdata <= core_wdata;
        req_strb <= core_wmask;
        pending <= 1;
      end
      if (pending && req_ready) begin
        pending <= 0;
        in_flight <= 1;
      end
      if (in_flight && rsp_valid && rsp_ready) in_flight <= 0;
    end
  end
endmodule
