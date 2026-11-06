`timescale 1ns/1ps
module tb_coherent_word_memory;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0, mem_ready=0;
  logic [1:0] req_valid=0, req_write=0, req_ready;
  logic [63:0] req_addr=0, req_wdata=0;
  logic [7:0] req_strb=0;
  logic [1:0] rsp_valid, rsp_error, rsp_ready=2'b11;
  logic [63:0] rsp_rdata, inv_addr;
  logic [1:0] inv_valid, inv_ack=0;
  coherent_word_memory dut(.*);
  logic [31:0] oracle [0:1023];
  logic [31:0] oracle_mmio=0;
  logic [31:0] queued_addr [0:1], queued_data [0:1], queued_expected [0:1];
  logic [3:0] queued_strb [0:1];
  logic queued_write [0:1], queued_error [0:1], outstanding [0:1];
  integer checks=0, accepted=0, completed=0, cases=0, aborted=0, contention_waits=0;
  bit oracle_turn=0;
  integer seed=32'h28a6beef;
  integer cycle=0;

  initial begin
    for (integer i=0; i<1024; i=i+1) oracle[i]=0;
    outstanding[0]=0; outstanding[1]=0;
  end
  always @(posedge clk) begin
    cycle=cycle+1;
    if(cycle>20000) $fatal(1,"global timeout");
    if(!rst_n) begin
      if(outstanding[0]) aborted=aborted+1;
      if(outstanding[1]) aborted=aborted+1;
      outstanding[0]=0; outstanding[1]=0;
      oracle_mmio=0;
      oracle_turn=0;
    end else begin
      for(integer c=0;c<2;c=c+1) begin
        if(req_valid[c] && req_ready[c]) begin
          if(outstanding[c]) $fatal(1,"duplicate accept core=%0d",c);
          if(req_valid==2'b11 && c!=oracle_turn)
            $fatal(1,"round-robin grant mismatch got=%0d expected=%0d",c,oracle_turn);
          oracle_turn=1-c;
          checks=checks+1;
          outstanding[c]=1;
          queued_addr[c]=c ? req_addr[63:32] : req_addr[31:0];
          queued_data[c]=c ? req_wdata[63:32] : req_wdata[31:0];
          queued_strb[c]=c ? req_strb[7:4] : req_strb[3:0];
          queued_write[c]=req_write[c];
          queued_error[c]=(queued_addr[c][1:0]!=0)||
             (queued_addr[c]>=32'h1000 && queued_addr[c]!=32'h1000_0000);
          if(queued_error[c] || queued_write[c]) queued_expected[c]=0;
          else if(queued_addr[c]==32'h1000_0000) queued_expected[c]=oracle_mmio;
          else queued_expected[c]=oracle[queued_addr[c][11:2]];
          accepted=accepted+1;
        end
        if(rsp_valid[c] && rsp_ready[c]) begin
          if(!outstanding[c]) $fatal(1,"response without request core=%0d",c);
          if(rsp_error[c]!==queued_error[c])
            $fatal(1,"error mismatch core=%0d addr=%h got=%b expected=%b",c,queued_addr[c],rsp_error[c],queued_error[c]);
          if((c ? rsp_rdata[63:32] : rsp_rdata[31:0]) !== queued_expected[c])
            $fatal(1,"data mismatch core=%0d addr=%h got=%h expected=%h",c,queued_addr[c],
              c ? rsp_rdata[63:32] : rsp_rdata[31:0],queued_expected[c]);
          checks=checks+2;
          if(queued_write[c] && !queued_error[c]) begin
            if(queued_addr[c]==32'h1000_0000) begin
              for(integer b=0;b<4;b=b+1)
                if(queued_strb[c][b]) oracle_mmio[b*8 +:8]=queued_data[c][b*8 +:8];
            end else begin
              for(integer b=0;b<4;b=b+1)
                if(queued_strb[c][b]) oracle[queued_addr[c][11:2]][b*8 +:8]=queued_data[c][b*8 +:8];
            end
          end
          outstanding[c]=0;
          completed=completed+1;
        end
      end
    end
  end

  task automatic check_cache;
    integer address;
    for(integer c=0;c<2;c=c+1)
      for(integer j=0;j<4;j=j+1) begin
        if(dut.line_valid[c][j]) begin
          if(dut.line_state[c][j]==0) $fatal(1,"valid I line c=%0d j=%0d",c,j);
          address=(dut.line_tag[c][j]<<4)|(j<<2);
          if(address>=4096) $fatal(1,"non-RAM cache line c=%0d j=%0d",c,j);
          if(dut.line_data[c][j]!==oracle[address>>2])
            $fatal(1,"stale cache c=%0d addr=%h got=%h expected=%h",c,address,
              dut.line_data[c][j],oracle[address>>2]);
          checks=checks+3;
        end
      end
    for(integer j=0;j<4;j=j+1)
      if(dut.line_valid[0][j] && dut.line_valid[1][j] &&
         dut.line_tag[0][j]==dut.line_tag[1][j]) begin
        if(dut.line_state[0][j]!=1 || dut.line_state[1][j]!=1)
          $fatal(1,"contradictory ownership index=%0d",j);
        checks=checks+1;
      end
  endtask

  task automatic held_response;
    integer before_done;
    logic [31:0] first_data;
    before_done=completed;
    @(negedge clk); rsp_ready[0]=0; mem_ready=1;
    req_valid[0]=1; req_write[0]=0; req_addr[31:0]=32'h20;
    @(posedge clk); if(!req_ready[0]) $fatal(1,"held response request not accepted");
    @(negedge clk); req_valid[0]=0;
    begin : response_wait
      for(integer t=0;t<100;t=t+1) begin
        @(negedge clk);
        if(rsp_valid[0]) disable response_wait;
      end
      $fatal(1,"held response timeout");
    end
    first_data=rsp_rdata[31:0];
    repeat(4) begin
      @(negedge clk);
      if(!rsp_valid[0] || rsp_rdata[31:0]!==first_data || completed!=before_done)
        $fatal(1,"response not stable under backpressure");
      checks=checks+3;
    end
    rsp_ready[0]=1;
    @(negedge clk);
    if(completed!=before_done+1) $fatal(1,"held response did not complete");
    cases=cases+1; check_cache();
  endtask

  task automatic one(input integer c, input bit wr, input logic [31:0] addr,
                     input logic [31:0] data, input logic [3:0] strb,
                     input integer delay_cycles, input integer expect_inv);
    integer start_done, seen_inv;
    start_done=completed; seen_inv=0;
    @(negedge clk);
    req_valid[c]=1; req_write[c]=wr;
    if(c) begin req_addr[63:32]=addr; req_wdata[63:32]=data; req_strb[7:4]=strb; end
    else begin req_addr[31:0]=addr; req_wdata[31:0]=data; req_strb[3:0]=strb; end
    mem_ready=0; inv_ack=0;
    begin : accept_loop
      for(integer t=0;t<100;t=t+1) begin
        @(posedge clk);
        if(req_ready[c]) disable accept_loop;
      end
      $fatal(1,"request timeout c=%0d",c);
    end
    @(negedge clk); req_valid[c]=0;
    repeat(delay_cycles) begin
      if(inv_valid[1-c]) begin
        seen_inv=seen_inv+1;
        if((c ? inv_addr[31:0] : inv_addr[63:32])!==addr)
          $fatal(1,"invalidation address mismatch");
      end
      @(negedge clk);
    end
    if(expect_inv==1 && seen_inv<2) $fatal(1,"invalidation not held under backpressure c=%0d addr=%h seen=%0d",c,addr,seen_inv);
    if(expect_inv==0 && seen_inv!=0) $fatal(1,"unexpected invalidation");
    inv_ack=2'b11; mem_ready=1;
    begin : response_loop
      for(integer t=0;t<100;t=t+1) begin
        @(negedge clk);
        if(completed>start_done) disable response_loop;
      end
      $fatal(1,"response timeout c=%0d addr=%h",c,addr);
    end
    inv_ack=0; cases=cases+1; check_cache();
  endtask

  task automatic pair(input logic [31:0] a0, a1, input bit w0,w1,
                      input logic [31:0] d0,d1,input integer stall_cycles);
    integer start_done;
    bit saw0,saw1;
    start_done=completed; saw0=0; saw1=0;
    @(negedge clk);
    req_valid=2'b11; req_write={w1,w0};
    req_addr={a1,a0}; req_wdata={d1,d0}; req_strb=8'hff;
    mem_ready=0; inv_ack=2'b11;
    begin : both_loop
      for(integer t=0;t<200;t=t+1) begin
        @(posedge clk);
        if(req_ready[0]) saw0=1;
        if(req_ready[1]) saw1=1;
        @(negedge clk);
        if(saw0) req_valid[0]=0;
        if(saw1) req_valid[1]=0;
        if(t>=stall_cycles) mem_ready=1;
        else if(saw0!=saw1 && !mem_ready && req_ready==0)
          contention_waits=contention_waits+1;
        if(completed==start_done+2) disable both_loop;
      end
      $fatal(1,"simultaneous request timeout");
    end
    cases=cases+1; check_cache();
  endtask

  task automatic reset_midflight;
    integer start_done;
    start_done=completed;
    @(negedge clk); mem_ready=0; inv_ack=0;
    req_valid[0]=1; req_write[0]=1; req_addr[31:0]=32'h3c;
    req_wdata[31:0]=32'hdeadbeef; req_strb[3:0]=4'hf;
    @(posedge clk);
    if(!req_ready[0]) $fatal(1,"reset setup request not accepted");
    @(negedge clk); req_valid[0]=0;
    repeat(3) @(negedge clk);
    rst_n=0;
    repeat(3) @(negedge clk);
    if(rsp_valid!=0) $fatal(1,"reset did not cancel response");
    rst_n=1; mem_ready=1;
    repeat(3) @(negedge clk);
    if(completed!=start_done) $fatal(1,"cancelled request completed");
    check_cache(); cases=cases+1;
  endtask

  initial begin : stimulus
    repeat(4) @(negedge clk);
    rst_n=1;
    one(0,1,32'h00,32'h11223344,4'hf,3,0);
    one(1,0,32'h00,0,0,2,0);
    one(0,0,32'h00,0,0,1,0);
    one(1,1,32'h00,32'h55667788,4'hf,4,1);
    one(0,0,32'h00,0,0,2,0);
    one(0,1,32'h00,32'haabbccdd,4'b0101,3,1);
    one(1,0,32'h00,0,0,2,0);
    one(0,1,32'h04,32'h12345678,4'hf,2,0);
    one(1,1,32'h08,32'habcdef01,4'hf,2,0);
    one(0,1,32'h10,32'h99887766,4'hf,2,0); // index conflict, clean eviction
    one(0,0,32'h00,0,0,2,0);
    one(1,0,32'h08,0,0,2,0);
    pair(32'h20,32'h20,1,1,32'h1234abcd,32'h5678ef01,4);
    pair(32'h24,32'h28,1,1,32'h87654321,32'h10203040,3);
    pair(32'h20,32'h20,0,0,0,0,2);
    held_response();
    one(1,1,32'h1000_0000,32'h0badcafe,4'hf,2,0);
    one(0,0,32'h1000_0000,0,0,2,0);
    one(0,0,32'h1000_0004,0,0,0,0);
    one(1,1,32'h03,32'hffffffff,4'hf,0,0);
    for(integer i=0;i<40;i=i+1) begin
      seed=(seed*1664525)+1013904223;
      one((seed>>4)&1,(seed>>8)&1,((seed>>12)&15)*4,
          seed^32'h5a5aa5a5,4'hf,1+((seed>>20)&3),-1);
    end
    for(integer i=0;i<8;i=i+1) begin
      seed=(seed*1664525)+1013904223;
      pair(((seed>>7)&15)*4,((seed>>13)&15)*4,(seed>>3)&1,(seed>>4)&1,
           seed^32'h31415926,seed^32'h27182818,1+((seed>>20)&3));
    end
    reset_midflight();
    one(1,0,32'h3c,0,0,2,0);
    one(0,0,32'h1000_0000,0,0,2,0);
    if(accepted!=completed+aborted) $fatal(1,"accounting accepted=%0d completed=%0d aborted=%0d",accepted,completed,aborted);
    if(checks<100 || completed<80 || aborted!=1 || contention_waits<10)
      $fatal(1,"insufficient checks or backpressure contention");
    $display("PASS COHERENT cases=%0d checks=%0d accepted=%0d completed=%0d aborted=%0d contention_waits=%0d seed=0x28a6beef",cases,checks,accepted,completed,aborted,contention_waits);
    $finish;
  end
endmodule
