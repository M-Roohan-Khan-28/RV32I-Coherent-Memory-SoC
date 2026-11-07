`timescale 1ns/1ps
// Shared-reset qualification of accepted request, memory side effect,
// response availability and response consumption as distinct events.
module tb_coherent_reset_commit;
  logic clk=0,rst_n=0,mem_ready=0;
  logic [1:0] req_valid=0,req_write=0,rsp_ready=0,inv_ack=2'b11;
  logic [63:0] req_addr=0,req_wdata=0;
  logic [7:0] req_strb=0;
  wire [1:0] req_ready,rsp_valid,rsp_error,inv_valid;
  wire [63:0] rsp_rdata,inv_addr;
  coherent_word_memory dut(.*);
  always #5 clk=~clk;
  logic [31:0] model_mem[0:1023];
  logic [31:0] model_mmio=0;
  logic [31:0] pending_addr,pending_data,pending_expected;
  logic [3:0] pending_strb;
  bit pending_write,pending_mmio,outstanding,side_effect_done;
  int owner,checks=0,accepted=0,completed=0,aborted=0,commits=0,resets=0;
  initial for(int i=0;i<1024;i++) model_mem[i]=0;

  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      if(outstanding) aborted++;
      outstanding=0; side_effect_done=0;
      model_mmio=0; // RAM is intentionally retained by the design
    end else begin
      for(int c=0;c<2;c++) begin
        if(req_valid[c] && req_ready[c]) begin
          if(outstanding) $fatal(1,"RESET_COMMIT_DUPLICATE_ACCEPT");
          owner=c;
          pending_addr=c?req_addr[63:32]:req_addr[31:0];
          pending_data=c?req_wdata[63:32]:req_wdata[31:0];
          pending_strb=c?req_strb[7:4]:req_strb[3:0];
          pending_write=req_write[c];
          pending_mmio=(pending_addr==32'h1000_0000);
          pending_expected=pending_write?0:
              (pending_mmio?model_mmio:model_mem[pending_addr[11:2]]);
          outstanding=1; side_effect_done=0; accepted++;
        end
      end
      // The directed scenarios have no invalidation dependency. A memory
      // ready edge after acceptance is their independently modeled commit.
      if(outstanding && !side_effect_done && mem_ready) begin
        if(pending_write) begin
          for(int b=0;b<4;b++) if(pending_strb[b]) begin
            if(pending_mmio) model_mmio[b*8 +:8]=pending_data[b*8 +:8];
            else model_mem[pending_addr[11:2]][b*8 +:8]=pending_data[b*8 +:8];
          end
          commits++;
        end
        side_effect_done=1;
      end
      if(rsp_valid[owner] && rsp_ready[owner]) begin
        if(!outstanding || !side_effect_done || rsp_error[owner] ||
           (owner?rsp_rdata[63:32]:rsp_rdata[31:0]) !== pending_expected)
          $fatal(1,"RESET_COMMIT_RESPONSE_MISMATCH owner=%0d",owner);
        outstanding=0; completed++; checks+=4;
      end
    end
  end

  task automatic reset_system;
    @(negedge clk); rst_n=0; req_valid=0; rsp_ready=0; mem_ready=0;
    resets++;
    repeat(2) @(negedge clk);
    if(rsp_valid!==0 || req_ready!==0 || dut.memory[0]!==model_mem[0] ||
       dut.memory[1]!==model_mem[1] || dut.memory[2]!==model_mem[2] ||
       dut.mmio_doorbell!==model_mmio)
      $fatal(1,"RESET_COMMIT_RESET_STATE_MISMATCH");
    checks+=6;
    rst_n=1;
  endtask
  task automatic send(input int c,input bit wr,input logic [31:0] addr,data,
                      input logic [3:0] strobe);
    @(negedge clk);
    req_valid[c]=1; req_write[c]=wr;
    if(c) begin req_addr[63:32]=addr; req_wdata[63:32]=data; req_strb[7:4]=strobe; end
    else begin req_addr[31:0]=addr; req_wdata[31:0]=data; req_strb[3:0]=strobe; end
    @(posedge clk);
    if(!req_ready[c]) $fatal(1,"RESET_COMMIT_ACCEPT_TIMEOUT");
    @(negedge clk); req_valid[c]=0;
    checks+=3;
  endtask
  task automatic expose_response(input int c,input logic [31:0] expected);
    @(negedge clk); mem_ready=1;
    begin : response_wait
      for(int t=0;t<20;t++) begin
        @(negedge clk);
        if(rsp_valid[c]) disable response_wait;
      end
      $fatal(1,"RESET_COMMIT_RESPONSE_TIMEOUT");
    end
    if(rsp_error[c] || (c?rsp_rdata[63:32]:rsp_rdata[31:0])!==expected)
      $fatal(1,"RESET_COMMIT_DATA_MISMATCH owner=%0d expected=%08h observed=%08h",
          c,expected,c?rsp_rdata[63:32]:rsp_rdata[31:0]);
    repeat(3) begin
      @(negedge clk);
      if(!rsp_valid[c] || rsp_error[c] ||
         (c?rsp_rdata[63:32]:rsp_rdata[31:0])!==expected)
        $fatal(1,"RESET_COMMIT_HELD_RESPONSE_MISMATCH");
      checks+=3;
    end
    checks+=3;
  endtask
  task automatic consume(input int c);
    @(negedge clk); rsp_ready[c]=1;
    @(posedge clk); #1;
    @(negedge clk); rsp_ready[c]=0; mem_ready=0;
    if(rsp_valid[c]) $fatal(1,"RESET_COMMIT_DUPLICATE_RESPONSE");
    checks++;
  endtask

  initial begin
    reset_system();
    send(0,1,32'h0,32'h11223344,4'hf);
    expose_response(0,0);
    reset_system(); // RAM side effect committed, response aborted
    send(1,0,32'h0,0,4'hf);
    expose_response(1,32'h11223344); consume(1);

    send(0,1,32'h4,32'hdeadbeef,4'hf);
    repeat(3) @(negedge clk);
    if(rsp_valid!==0 || dut.memory[1]!==0)
      $fatal(1,"RESET_COMMIT_PRECOMMIT_WRITE_LEAK");
    reset_system(); // accepted but no memory commit
    send(1,0,32'h4,0,4'hf);
    expose_response(1,0); consume(1);

    send(0,1,32'h1000_0000,32'h89abcdef,4'hf);
    expose_response(0,0);
    reset_system(); // doorbell, unlike RAM, clears on reset
    send(1,0,32'h1000_0000,0,4'hf);
    expose_response(1,0); consume(1);

    send(0,1,32'h8,32'haabbccdd,4'b0101);
    expose_response(0,0); consume(0);
    reset_system(); // response already consumed; partial RAM write retained
    send(1,0,32'h8,0,4'hf);
    expose_response(1,32'h00bb00dd); consume(1);

    if(accepted!=8 || completed!=5 || aborted!=3 || commits!=3 || resets!=5 ||
       outstanding || accepted!=completed+aborted)
      $fatal(1,"RESET_COMMIT_COUNT_MISMATCH accepted=%0d completed=%0d aborted=%0d commits=%0d resets=%0d",
          accepted,completed,aborted,commits,resets);
    $display("RESET_COMMIT_PASS checks=%0d accepted=%0d completed=%0d aborted=%0d commits=%0d resets=%0d",
       checks,accepted,completed,aborted,commits,resets);
    $finish;
  end
  initial begin #100000; $fatal(1,"RESET_COMMIT_TIMEOUT"); end
endmodule
