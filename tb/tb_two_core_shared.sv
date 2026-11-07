`timescale 1ns/1ps
module tb_two_core_shared;
  logic clk=0;
  always #5 clk=~clk;
  logic reset_n=0, mem_ready=0;
  logic [31:0] program0[0:255],program1[0:255];
  wire [31:0] pc0,pc1;
  wire [31:0] inst0=(pc0<1024)?program0[pc0[9:2]]:32'h00000013;
  wire [31:0] inst1=(pc1<1024)?program1[pc1[9:2]]:32'h00000013;
  wire [1:0] core_req,core_we,core_ack,core_err;
  wire [63:0] core_addr,core_wdata,core_rdata;
  wire [7:0] core_mask;
  wire [1:0] req_valid,req_write,req_ready,rsp_valid,rsp_error,rsp_ready,inv_valid;
  wire [63:0] req_addr,req_wdata,rsp_rdata,inv_addr;
  wire [7:0] req_strb;
  integer cycles=0,checks=0,simultaneous=0,busy_waits=0,invalid_waits=0;
  integer inv_age=0;
  wire [1:0] inv_ack=(inv_age>=3) ? 2'b11 : 2'b00;
  integer accepted[0:1],completed[0:1];
  bit stalled[0:1];
  logic [31:0] held_addr[0:1],held_data[0:1];
  logic [3:0] held_strb[0:1];
  logic held_write[0:1];
  logic [31:0] oracle_word=0,expected_response[0:1],expected_load[0:1];
  bit mode_read_write=0;

  rv32i_core core0(.clk(clk),.rst_n(reset_n),.imem_addr(pc0),.imem_rdata(inst0),
    .dmem_req(core_req[0]),.dmem_we(core_we[0]),.dmem_addr(core_addr[31:0]),
    .dmem_wdata(core_wdata[31:0]),.dmem_wmask(core_mask[3:0]),
    .dmem_rdata(core_rdata[31:0]),.dmem_ack(core_ack[0]),.dmem_err(core_err[0]));
  rv32i_core core1(.clk(clk),.rst_n(reset_n),.imem_addr(pc1),.imem_rdata(inst1),
    .dmem_req(core_req[1]),.dmem_we(core_we[1]),.dmem_addr(core_addr[63:32]),
    .dmem_wdata(core_wdata[63:32]),.dmem_wmask(core_mask[7:4]),
    .dmem_rdata(core_rdata[63:32]),.dmem_ack(core_ack[1]),.dmem_err(core_err[1]));
  for(genvar c=0;c<2;c++) begin: bridges
    core_request_bridge bridge(.clk(clk),.rst_n(reset_n),.core_req(core_req[c]),
      .core_we(core_we[c]),.core_addr(core_addr[c*32 +: 32]),
      .core_wdata(core_wdata[c*32 +: 32]),.core_wmask(core_mask[c*4 +: 4]),
      .core_ack(core_ack[c]),.core_err(core_err[c]),.core_rdata(core_rdata[c*32 +: 32]),
      .req_valid(req_valid[c]),.req_write(req_write[c]),.req_addr(req_addr[c*32 +: 32]),
      .req_wdata(req_wdata[c*32 +: 32]),.req_strb(req_strb[c*4 +: 4]),
      .req_ready(req_ready[c]),.rsp_valid(rsp_valid[c]),.rsp_error(rsp_error[c]),
      .rsp_rdata(rsp_rdata[c*32 +: 32]),.rsp_ready(rsp_ready[c]));
  end
  coherent_word_memory memory_system(.clk(clk),.rst_n(reset_n),.req_valid(req_valid),
    .req_write(req_write),.req_addr(req_addr),.req_wdata(req_wdata),.req_strb(req_strb),
    .req_ready(req_ready),.rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata),
    .rsp_ready(rsp_ready),.mem_ready(mem_ready),.inv_valid(inv_valid),.inv_addr(inv_addr),
    .inv_ack(inv_ack));

  function automatic [31:0] addi(input [4:0] rd,rs1,input [11:0] imm);
    addi={imm,rs1,3'b000,rd,7'h13};
  endfunction
  function automatic [31:0] sw(input [4:0] rs2,rs1,input [11:0] imm);
    sw={imm[11:5],rs2,rs1,3'b010,imm[4:0],7'h23};
  endfunction
  function automatic [31:0] lw(input [4:0] rd,rs1,input [11:0] imm);
    lw={imm,rs1,3'b010,rd,7'h03};
  endfunction
  always @(posedge clk) begin
    cycles++;
    if(cycles>1000) $fatal(1,"shared core timeout accepted=%0d/%0d completed=%0d/%0d",
                          accepted[0],accepted[1],completed[0],completed[1]);
    if(reset_n) begin
      if(req_valid==2'b11) simultaneous++;
      if(|(req_valid & ~req_ready)) busy_waits++;
      if(|inv_valid && !(|(inv_valid & inv_ack))) invalid_waits++;
      for(integer c=0;c<2;c++) begin
        if(stalled[c] && (!req_valid[c] || req_addr[c*32 +: 32]!==held_addr[c] ||
                          req_wdata[c*32 +: 32]!==held_data[c] ||
                          req_strb[c*4 +: 4]!==held_strb[c] || req_write[c]!==held_write[c]))
          $fatal(1,"core%0d bridge payload changed while waiting",c);
        stalled[c]=req_valid[c] && !req_ready[c];
        if(stalled[c]) begin
          held_addr[c]=req_addr[c*32 +: 32];
          held_data[c]=req_wdata[c*32 +: 32];
          held_strb[c]=req_strb[c*4 +: 4];
          held_write[c]=req_write[c];
        end
        if(core_req[c] && (req_valid[c] || rsp_ready[c]))
          $fatal(1,"core%0d issued while bridge occupied",c);
        if(req_valid[c] && req_ready[c]) begin
          if(accepted[c]>=2 || completed[c]!=accepted[c] ||
             req_addr[c*32 +: 32] !== 32'd0 ||
             req_write[c] !== ((c==0 || !mode_read_write) ?
                               (accepted[c]==0) : (accepted[c]==1)) ||
             req_strb[c*4 +: 4]!==4'hf)
            $fatal(1,"core%0d duplicate or incorrect acceptance index=%0d",c,accepted[c]);
          if(req_write[c] && req_wdata[c*32 +: 32] !== (c==0?32'd17:32'd29))
            $fatal(1,"core%0d write payload incorrect",c);
          // Global acceptance order defines the serial reference history.
          // The subsystem commits each request before accepting the next.
          if(req_write[c]) begin
            oracle_word=req_wdata[c*32 +: 32];
            expected_response[c]=0;
          end else begin
            expected_response[c]=oracle_word;
            expected_load[c]=oracle_word;
          end
          accepted[c]++;
          checks+=5;
        end
        if(rsp_valid[c] && rsp_ready[c]) begin
          if(completed[c]>=accepted[c] || rsp_error[c] ||
             rsp_rdata[c*32 +: 32] !== expected_response[c])
            $fatal(1,"core%0d response mismatch index=%0d data=%h",c,completed[c],rsp_rdata[c*32 +: 32]);
          completed[c]++;
          checks+=3;
        end
      end
    end
  end
  always @(negedge clk) begin
    mem_ready=(cycles%11)==0;
    if(|inv_valid) inv_age++;
    else inv_age=0;
  end
  initial begin
    string mode_label;
    mode_read_write=$test$plusargs("READ_WRITE");
    mode_label=mode_read_write?"read_write":"store_store";
    for(integer i=0;i<256;i++) begin program0[i]=32'h00000013;program1[i]=32'h00000013;end
    program0[0]=addi(1,0,0); program0[1]=addi(2,0,17);
    program0[2]=sw(2,1,0); program0[3]=lw(3,1,0); program0[4]=32'h0000006f;
    program1[0]=addi(1,0,0); program1[1]=addi(2,0,29);
    if(mode_read_write) begin
      program1[1]=addi(0,0,0); program1[2]=lw(3,1,0);
      program1[3]=addi(2,0,29); program1[4]=sw(2,1,0);
      program1[5]=32'h0000006f;
    end else begin
      program1[2]=sw(2,1,0); program1[3]=lw(3,1,0);
      program1[4]=32'h0000006f;
    end
    accepted[0]=0;accepted[1]=0;completed[0]=0;completed[1]=0;
    stalled[0]=0;stalled[1]=0;
    repeat(4) @(negedge clk);
    reset_n=1;
    begin: bounded
      for(integer t=0;t<500;t++) begin
        @(negedge clk);
        if(completed[0]==2 && completed[1]==2 &&
           core0.u_rf.regs[3]===expected_load[0] &&
           core1.u_rf.regs[3]===expected_load[1])
          disable bounded;
      end
      $fatal(1,"concurrent programs did not complete");
    end
    repeat(12) @(negedge clk);
    if(accepted[0]!=2 || accepted[1]!=2 || completed[0]!=2 || completed[1]!=2 ||
       simultaneous==0 || busy_waits<2 || (!mode_read_write && invalid_waits<1) ||
       memory_system.memory[0]!==oracle_word || pc0!==32'd16 ||
       pc1!==(mode_read_write?32'd20:32'd16))
      $fatal(1,"shared accounting/memory/progress mismatch accepted=%0d/%0d completed=%0d/%0d simultaneous=%0d busy=%0d inv=%0d mem=%0d expected=%0d pc=%0d/%0d",
        accepted[0],accepted[1],completed[0],completed[1],simultaneous,busy_waits,
        invalid_waits,memory_system.memory[0],oracle_word,pc0,pc1);
    checks+=10;
    for(integer r=0;r<32;r++) begin
      if(core0.u_rf.regs[r] !== (r==2 ? 32'd17 : r==3 ? expected_load[0] : 32'd0) ||
         core1.u_rf.regs[r] !== (r==2 ? 32'd29 : r==3 ? expected_load[1] : 32'd0))
        $fatal(1,"concurrent register mismatch x%0d",r);
      checks+=2;
    end
    $display("PASS TWO_CORE_SHARED mode=%s checks=%0d accepted=%0d/%0d completed=%0d/%0d simultaneous=%0d busy_waits=%0d invalidation_waits=%0d final=%0d load0=%0d load1=%0d",
             mode_label,
             checks,accepted[0],accepted[1],completed[0],completed[1],simultaneous,busy_waits,
             invalid_waits,oracle_word,expected_load[0],expected_load[1]);
    $finish;
  end
endmodule
