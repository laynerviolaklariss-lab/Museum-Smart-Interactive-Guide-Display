`timescale 1ns/1ps

// 1024 x 32 asynchronous FIFO between the 100 MHz SDRAM application port
// and the proven 125 MHz/5-phase HDMI transmitter.  AF is deliberately
// early so controller read latency cannot overrun the RAM after throttling.
module video_async_fifo(
    input  wire        rst,
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        wr_almost_full,
    output wire        wr_full,
    input  wire        rd_clk,
    input  wire        rd_en,
    output wire [31:0] rd_data,
    output wire        rd_empty,
    output wire        rd_almost_empty
);
    EG_LOGIC_FIFO #(
        .DATA_WIDTH_W(32), .DATA_DEPTH_W(1024),
        .DATA_WIDTH_R(32), .DATA_DEPTH_R(1024),
        .MODE("FIFO8K"), .REGMODE_W("NOREG"), .REGMODE_R("NOREG"),
        .E(0), .AE(128), .AF(896), .F(1024),
        .GSR("ENABLE"), .RESETMODE("ASYNC"),
        .ASYNC_RESET_RELEASE("SYNC"), .ENDIAN("LITTLE")
    ) u_fifo (
        .rst(rst), .di(wr_data), .clkw(wr_clk), .we(wr_en), .csw(3'b111),
        .do(rd_data), .clkr(rd_clk), .re(rd_en), .csr(3'b111), .ore(1'b1),
        .empty_flag(rd_empty), .aempty_flag(rd_almost_empty),
        .full_flag(wr_full), .afull_flag(wr_almost_full)
    );
endmodule

// Two deterministic scan-line buffers.  Port A is filled from SDRAM at
// 100 MHz; port B is read by the 125 MHz/5-phase HDMI engine.  Each bank is
// replaced only after the HDMI side reports that its previous line was used.
module video_line_buffer(
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire        wr_bank,
    input  wire [9:0]  wr_addr,
    input  wire [31:0] wr_data,
    input  wire        rd_clk,
    input  wire        rd_bank,
    input  wire [9:0]  rd_addr,
    output wire [31:0] rd_data
);
    wire [31:0] bank0_q,bank1_q;
    reg rd_bank_q;
    always @(posedge rd_clk) rd_bank_q<=rd_bank;

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),
        .ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),
        .DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),
        .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
        .FORCE_KEEP("ON"),.INIT_FILE("NONE"),.FILL_ALL("NONE"),
        .IMPLEMENT("32K")
    ) u_line0 (
        .doa(),.dob(bank0_q),.dia(wr_data),.dib(32'd0),
        .cea(1'b1),.ocea(1'b1),.clka(wr_clk),.wea(wr_en&&!wr_bank),.rsta(1'b0),.bea(1'b0),
        .ceb(1'b1),.oceb(1'b1),.clkb(rd_clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
        .addra(wr_addr),.addrb(rd_addr)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),
        .ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),
        .DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),
        .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
        .FORCE_KEEP("ON"),.INIT_FILE("NONE"),.FILL_ALL("NONE"),
        .IMPLEMENT("32K")
    ) u_line1 (
        .doa(),.dob(bank1_q),.dia(wr_data),.dib(32'd0),
        .cea(1'b1),.ocea(1'b1),.clka(wr_clk),.wea(wr_en&&wr_bank),.rsta(1'b0),.bea(1'b0),
        .ceb(1'b1),.oceb(1'b1),.clkb(rd_clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
        .addra(wr_addr),.addrb(rd_addr)
    );
    assign rd_data=rd_bank_q?bank1_q:bank0_q;
endmodule
