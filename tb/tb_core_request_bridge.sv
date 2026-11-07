`timescale 1ns/1ps
// One-cycle core pulse -> held subsystem request -> later core completion.
module tb_core_request_bridge;
  logic clk=0,rst_n=0,core_req=0,core_we=0;
  logic [31:0] core_addr=0,core_wdata=0;
  logic [3:0] core_wmask=0;
  wire core_ack,core_err;
  wire [31:0] core_rdata;
  wire req_valid,req_write,rsp_ready;
  wire [31:0] req_addr,req_wdata;
  wire [3:0] req_strb;
  logic req_ready=0,rsp_valid=0,rsp_error=0;
  logic [31:0] rsp_rdata=0;
  core_request_bridge dut(.*);
  always #5 clk=~clk;
  int checks=0,accepted=0,completed=0,aborted=0,stalls=0;
  bit holding=0,outstanding=0;
  logic [31:0] held_addr,held_data;
  logic [3:0] held_mask;
  bit held_write;

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      if(outstanding) aborted++;
      outstanding=0; holding=0;
    end else begin
      if(holding && (!req_valid || req_addr!==held_addr ||
                     req_wdata!==held_data || req_strb!==held_mask ||
                     req_write!==held_write))
        $fatal(1,"BRIDGE_HOLD_MISMATCH");
      holding=req_valid && !req_ready;
      if(holding) begin
        held_addr=req_addr; held_data=req_wdata;
        held_mask=req_strb; held_write=req_write;
        stalls++;
      end
      if(req_valid && req_ready) begin
        if(outstanding || core_ack) $fatal(1,"BRIDGE_ACCEPTANCE_COMPLETION_CONFUSED");
        outstanding=1; accepted++;
      end
      if(rsp_valid && rsp_ready) begin
        if(!outstanding || !core_ack) $fatal(1,"BRIDGE_RESPONSE_WITHOUT_ACCEPTANCE");
        outstanding=0; completed++;
      end
    end
  end

  task automatic pulse(input bit wr,input logic [31:0] addr,data,
                       input logic [3:0] mask);
    @(negedge clk);
    core_we=wr; core_addr=addr; core_wdata=data; core_wmask=mask;
    core_req=1;
    @(posedge clk); #1;
    @(negedge clk); core_req=0;
    if(!req_valid || req_write!==wr || req_addr!==addr ||
       req_wdata!==data || req_strb!==mask || core_ack || rsp_ready)
      $fatal(1,"BRIDGE_CAPTURE_MISMATCH addr=%h",addr);
    checks+=7;
  endtask
  task automatic hold_for(input int n,input logic [31:0] addr,data,
                          input logic [3:0] mask,input bit wr);
    repeat(n) begin
      @(negedge clk);
      if(!req_valid || req_addr!==addr || req_wdata!==data ||
         req_strb!==mask || req_write!==wr || core_ack || rsp_ready)
        $fatal(1,"BRIDGE_STALL_MISMATCH addr=%h",addr);
      checks+=7;
    end
  endtask
  task automatic accept_request;
    @(negedge clk); req_ready=1;
    @(posedge clk); #1;
    if(req_valid || !rsp_ready || core_ack)
      $fatal(1,"BRIDGE_ACCEPTANCE_NOT_DISTINCT");
    checks+=3;
    @(negedge clk); req_ready=0;
  endtask
  task automatic respond(input bit err,input logic [31:0] data);
    repeat(3) begin
      @(negedge clk);
      if(core_ack || !rsp_ready) $fatal(1,"BRIDGE_PREMATURE_ACK");
      checks+=2;
    end
    rsp_error=err; rsp_rdata=data; rsp_valid=1;
    #1;
    if(!core_ack || core_err!==err || core_rdata!==data || !rsp_ready)
      $fatal(1,"BRIDGE_RESPONSE_MISMATCH");
    checks+=4;
    @(posedge clk); #1;
    @(negedge clk); rsp_valid=0;
    if(core_ack || rsp_ready) $fatal(1,"BRIDGE_DUPLICATE_COMPLETION");
    checks+=2;
  endtask
  task automatic reset_bridge;
    @(negedge clk); rst_n=0; req_ready=0; rsp_valid=0;
    repeat(2) @(negedge clk);
    if(req_valid || rsp_ready || core_ack) $fatal(1,"BRIDGE_RESET_NOT_CLEAN");
    checks+=3;
    rst_n=1;
  endtask

  initial begin
    reset_bridge();
    pulse(1,32'h0000003c,32'h12345678,4'b0101);
    rsp_valid=1; rsp_rdata=32'hbad0bad0; // spurious before acceptance
    #1; if(rsp_ready || core_ack) $fatal(1,"BRIDGE_SPURIOUS_RESPONSE_ACK");
    checks+=2; rsp_valid=0;
    hold_for(5,32'h3c,32'h12345678,4'b0101,1);
    accept_request();
    respond(0,32'h0);

    pulse(0,32'h00000080,32'hfacecafe,4'b1111);
    hold_for(2,32'h80,32'hfacecafe,4'hf,0);
    accept_request();
    respond(1,32'hdeadc0de);

    pulse(1,32'h00000004,32'habcdef01,4'hf);
    hold_for(2,32'h04,32'habcdef01,4'hf,1);
    reset_bridge(); // captured but not accepted
    if(outstanding) $fatal(1,"BRIDGE_PENDING_RESET_ACCOUNTING");

    pulse(0,32'h00000008,0,4'hf);
    accept_request();
    reset_bridge(); // accepted but response not delivered
    rsp_valid=1; #1;
    if(core_ack || rsp_ready) $fatal(1,"BRIDGE_STALE_RESPONSE_AFTER_RESET");
    checks+=2; rsp_valid=0;

    pulse(1,32'h0000000c,32'h55aa33cc,4'hf);
    accept_request();
    respond(0,0);
    if(accepted!=4 || completed!=3 || aborted!=1 || stalls<9)
      $fatal(1,"BRIDGE_COUNT_MISMATCH accepted=%0d completed=%0d aborted=%0d stalls=%0d",
          accepted,completed,aborted,stalls);
    $display("BRIDGE_CONTRACT_PASS checks=%0d accepted=%0d completed=%0d aborted=%0d stalls=%0d",
       checks,accepted,completed,aborted,stalls);
    $finish;
  end
  initial begin #100000; $fatal(1,"BRIDGE_TIMEOUT"); end
endmodule
