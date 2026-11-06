`timescale 1ns/1ps
module tb_two_core_programs;
  logic clk=0;
  always #5 clk=~clk;
  logic mem_reset=0;
  logic [1:0] core_reset=0;
  logic [31:0] program0 [0:255], program1 [0:255];
  wire [31:0] pc0,pc1;
  wire [31:0] inst0=(pc0<1024) ? program0[pc0[9:2]] : 32'h00000013;
  wire [31:0] inst1=(pc1<1024) ? program1[pc1[9:2]] : 32'h00000013;
  wire req0,we0,req1,we1,ack0,ack1,err0,err1;
  wire [31:0] addr0,data0,read0,addr1,data1,read1;
  wire [3:0] mask0,mask1;
  wire [1:0] req_ready,rsp_valid,rsp_error,inv_valid;
  wire [63:0] rsp_rdata,inv_addr;
  wire [1:0] req_valid, req_write;
  wire [63:0] req_addr,req_wdata;
  wire [7:0] req_strb;
  logic mem_ready=0;
  wire [1:0] rsp_ready;
  wire [1:0] inv_ack=2'b11;
  integer cycles=0,checks=0,accepted=0,completed=0,wait_edges=0;
  integer program_stage=0;
  logic pending=0,pending_owner=0,pending_write=0;
  logic [31:0] pending_expected=0,pending_data=0,reference_word=0;
  logic [31:0] prior_pc0=0,prior_pc1=0;
  logic stalled0=0,stalled1=0;

  rv32i_core core0(.clk(clk),.rst_n(core_reset[0]),.imem_addr(pc0),.imem_rdata(inst0),
    .dmem_req(req0),.dmem_we(we0),.dmem_addr(addr0),.dmem_wdata(data0),.dmem_wmask(mask0),
    .dmem_rdata(read0),.dmem_ack(ack0),.dmem_err(err0));
  rv32i_core core1(.clk(clk),.rst_n(core_reset[1]),.imem_addr(pc1),.imem_rdata(inst1),
    .dmem_req(req1),.dmem_we(we1),.dmem_addr(addr1),.dmem_wdata(data1),.dmem_wmask(mask1),
    .dmem_rdata(read1),.dmem_ack(ack1),.dmem_err(err1));
  coherent_word_memory memory_system(.clk(clk),.rst_n(mem_reset),.req_valid(req_valid),
    .req_write(req_write),.req_addr(req_addr),.req_wdata(req_wdata),.req_strb(req_strb),
    .req_ready(req_ready),.rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata),
    .rsp_ready(rsp_ready),.mem_ready(mem_ready),.inv_valid(inv_valid),.inv_addr(inv_addr),.inv_ack(inv_ack));
  core_request_bridge bridge0(.clk(clk),.rst_n(core_reset[0]),
    .core_req(req0),.core_we(we0),.core_addr(addr0),.core_wdata(data0),.core_wmask(mask0),
    .core_ack(ack0),.core_err(err0),.core_rdata(read0),
    .req_valid(req_valid[0]),.req_write(req_write[0]),.req_addr(req_addr[31:0]),
    .req_wdata(req_wdata[31:0]),.req_strb(req_strb[3:0]),.req_ready(req_ready[0]),
    .rsp_valid(rsp_valid[0]),.rsp_error(rsp_error[0]),.rsp_rdata(rsp_rdata[31:0]),
    .rsp_ready(rsp_ready[0]));
  core_request_bridge bridge1(.clk(clk),.rst_n(core_reset[1]),
    .core_req(req1),.core_we(we1),.core_addr(addr1),.core_wdata(data1),.core_wmask(mask1),
    .core_ack(ack1),.core_err(err1),.core_rdata(read1),
    .req_valid(req_valid[1]),.req_write(req_write[1]),.req_addr(req_addr[63:32]),
    .req_wdata(req_wdata[63:32]),.req_strb(req_strb[7:4]),.req_ready(req_ready[1]),
    .rsp_valid(rsp_valid[1]),.rsp_error(rsp_error[1]),.rsp_rdata(rsp_rdata[63:32]),
    .rsp_ready(rsp_ready[1]));

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
    cycles=cycles+1;
    if(cycles>2000) $fatal(1,"two-core program timeout stage=%0d",program_stage);
    prior_pc0=pc0; prior_pc1=pc1;
    stalled0=core_reset[0] && core0.core_state==1 && !ack0;
    stalled1=core_reset[1] && core1.core_state==1 && !ack1;
    if(mem_reset) begin
      if((req_valid & req_ready)!=0) begin
        if(pending) $fatal(1,"overlapping accepted program operations");
        pending=1;
        pending_owner=req_ready[1];
        pending_write=req_write[pending_owner];
        pending_data=pending_owner ? req_wdata[63:32] : req_wdata[31:0];
        if((pending_owner ? req_addr[63:32] : req_addr[31:0])!==0)
          $fatal(1,"unexpected program address");
        if((pending_owner ? req_strb[7:4] : req_strb[3:0])!==4'hf)
          $fatal(1,"unexpected program byte mask");
        pending_expected=pending_write ? 0 : reference_word;
        accepted=accepted+1;
        checks=checks+2;
      end
      if((rsp_valid & rsp_ready)!=0) begin
        if(!pending || rsp_valid[pending_owner]!==1 || rsp_error[pending_owner]!==0)
          $fatal(1,"program response ownership/error");
        if((pending_owner ? rsp_rdata[63:32] : rsp_rdata[31:0])!==pending_expected)
          $fatal(1,"program read mismatch expected=%h got=%h",pending_expected,
            pending_owner ? rsp_rdata[63:32] : rsp_rdata[31:0]);
        if(pending_write) reference_word=pending_data;
        completed=completed+1; checks=checks+2;
        pending=0;
      end
    end
  end
  always @(negedge clk) begin
    mem_ready=(cycles%7)==0;
    if(stalled0) begin
      if(pc0!==prior_pc0) $fatal(1,"core0 PC advanced while memory stalled");
      wait_edges=wait_edges+1; checks=checks+1;
    end
    if(stalled1) begin
      if(pc1!==prior_pc1) $fatal(1,"core1 PC advanced while memory stalled");
      wait_edges=wait_edges+1; checks=checks+1;
    end
  end
  task automatic wait_reg(input integer core_id, reg_id,input logic [31:0] value);
    begin : bounded
      for(integer t=0;t<300;t=t+1) begin
        @(negedge clk);
        if((core_id==0 ? core0.u_rf.regs[reg_id] : core1.u_rf.regs[reg_id])===value)
          disable bounded;
      end
      $fatal(1,"register timeout core=%0d x%0d expected=%h got=%h pc0=%h pc1=%h",core_id,reg_id,value,
        core_id==0 ? core0.u_rf.regs[reg_id] : core1.u_rf.regs[reg_id],pc0,pc1);
    end
    checks=checks+1;
  endtask

  initial begin
    for(integer i=0;i<256;i=i+1) begin program0[i]=32'h00000013;program1[i]=32'h00000013;end
    program0[0]=addi(1,0,0); program0[1]=addi(2,0,42);
    program0[2]=sw(2,1,0);   program0[3]=lw(3,1,0);
    program0[4]=32'h0000006f; // JAL x0,0: wait for core 1
    program1[0]=addi(1,0,0); program1[1]=lw(2,1,0);
    program1[2]=addi(3,2,1); program1[3]=sw(3,1,0);
    program1[4]=lw(4,1,0);   program1[5]=32'h0000006f;
    repeat(4) @(negedge clk);
    mem_reset=1; core_reset[0]=1;
    program_stage=1;
    wait_reg(0,3,42);
    if(reference_word!==42 || completed!=2) $fatal(1,"core0 seed program did not commit store/load");
    checks=checks+2;
    core_reset[1]=1;
    program_stage=2;
    wait_reg(1,4,43);
    if(core1.u_rf.regs[2]!==42 || core1.u_rf.regs[3]!==43 || reference_word!==43)
      $fatal(1,"core1 program result mismatch");
    checks=checks+3;
    program0[4]=lw(5,1,0); program0[5]=32'h0000006f;
    program_stage=3;
    wait_reg(0,5,43);
    if(memory_system.memory[0]!==43 || core0.u_rf.regs[2]!==42 ||
       core0.u_rf.regs[3]!==42 || completed!=6 || accepted!=6 || wait_edges<6)
      $fatal(1,"two-core architectural/memory/accounting mismatch accepted=%0d completed=%0d waits=%0d mem=%h",accepted,completed,wait_edges,memory_system.memory[0]);
    checks=checks+6;
    if(pc0!==32'd20 || pc1!==32'd20) $fatal(1,"programs did not reach terminal loops pc0=%h pc1=%h",pc0,pc1);
    checks=checks+2;
    for(integer r=0;r<32;r=r+1) begin
      if(core0.u_rf.regs[r] !== (r==2 ? 32'd42 : r==3 ? 32'd42 : r==5 ? 32'd43 : 32'd0))
        $fatal(1,"core0 architectural register x%0d unexpected=%h",r,core0.u_rf.regs[r]);
      if(core1.u_rf.regs[r] !== (r==2 ? 32'd42 : r==3 ? 32'd43 : r==4 ? 32'd43 : 32'd0))
        $fatal(1,"core1 architectural register x%0d unexpected=%h",r,core1.u_rf.regs[r]);
      checks=checks+2;
    end
    $display("PASS TWO_CORE_PROGRAMS checks=%0d accepted=%0d completed=%0d waits=%0d",checks,accepted,completed,wait_edges);
    $finish;
  end
endmodule
