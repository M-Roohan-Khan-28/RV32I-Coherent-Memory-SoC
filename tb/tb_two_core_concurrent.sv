`timescale 1ns/1ps
module tb_two_core_concurrent;
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
  wire [1:0] inv_ack=2'b11;
  integer cycles=0,checks=0,simultaneous=0,busy_waits=0;
  integer accepted[0:1],completed[0:1];
  bit stalled[0:1];
  logic [31:0] held_addr[0:1],held_data[0:1];
  logic [3:0] held_strb[0:1];
  logic held_write[0:1];

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
    if(cycles>1000) $fatal(1,"concurrent core timeout accepted=%0d/%0d completed=%0d/%0d",
                          accepted[0],accepted[1],completed[0],completed[1]);
    if(reset_n) begin
      if(req_valid==2'b11) simultaneous++;
      if(|(req_valid & ~req_ready)) busy_waits++;
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
        if(req_valid[c] && req_ready[c]) begin
          if(accepted[c]>=2 || completed[c]!=accepted[c] ||
             req_addr[c*32 +: 32] !== (c==0?32'd0:32'd4) ||
             req_write[c] !== (accepted[c]==0) || req_strb[c*4 +: 4]!==4'hf)
            $fatal(1,"core%0d duplicate or incorrect acceptance index=%0d",c,accepted[c]);
          if(accepted[c]==0 && req_wdata[c*32 +: 32] !== (c==0?32'd17:32'd29))
            $fatal(1,"core%0d write payload incorrect",c);
          accepted[c]++;
          checks+=5;
        end
        if(rsp_valid[c] && rsp_ready[c]) begin
          if(completed[c]>=accepted[c] || rsp_error[c] ||
             rsp_rdata[c*32 +: 32] !== (completed[c]==0?32'd0:(c==0?32'd17:32'd29)))
            $fatal(1,"core%0d response mismatch index=%0d data=%h",c,completed[c],rsp_rdata[c*32 +: 32]);
          completed[c]++;
          checks+=3;
        end
      end
    end
  end
  always @(negedge clk) mem_ready=(cycles%11)==0;
  initial begin
    for(integer i=0;i<256;i++) begin program0[i]=32'h00000013;program1[i]=32'h00000013;end
    program0[0]=addi(1,0,0); program0[1]=addi(2,0,17);
    program0[2]=sw(2,1,0); program0[3]=lw(3,1,0); program0[4]=32'h0000006f;
    program1[0]=addi(1,0,4); program1[1]=addi(2,0,29);
    program1[2]=sw(2,1,0); program1[3]=lw(3,1,0); program1[4]=32'h0000006f;
    accepted[0]=0;accepted[1]=0;completed[0]=0;completed[1]=0;
    stalled[0]=0;stalled[1]=0;
    repeat(4) @(negedge clk);
    reset_n=1;
    begin: bounded
      for(integer t=0;t<500;t++) begin
        @(negedge clk);
        if(completed[0]==2 && completed[1]==2 &&
           core0.u_rf.regs[3]===32'd17 && core1.u_rf.regs[3]===32'd29)
          disable bounded;
      end
      $fatal(1,"concurrent programs did not complete");
    end
    repeat(12) @(negedge clk);
    if(accepted[0]!=2 || accepted[1]!=2 || completed[0]!=2 || completed[1]!=2 ||
       simultaneous==0 || busy_waits<2 || memory_system.memory[0]!==32'd17 ||
       memory_system.memory[1]!==32'd29 || pc0!==32'd16 || pc1!==32'd16)
      $fatal(1,"concurrent accounting/memory/progress mismatch");
    checks+=10;
    for(integer r=0;r<32;r++) begin
      if(core0.u_rf.regs[r] !== (r==2 || r==3 ? 32'd17 : 32'd0) ||
         core1.u_rf.regs[r] !== (r==1 ? 32'd4 : r==2 || r==3 ? 32'd29 : 32'd0))
        $fatal(1,"concurrent register mismatch x%0d",r);
      checks+=2;
    end
    $display("PASS TWO_CORE_CONCURRENT checks=%0d accepted=%0d/%0d completed=%0d/%0d simultaneous=%0d busy_waits=%0d",
             checks,accepted[0],accepted[1],completed[0],completed[1],simultaneous,busy_waits);
    $finish;
  end
endmodule
