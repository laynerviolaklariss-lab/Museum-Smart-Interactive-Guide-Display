`timescale 1ns/1ps

// 512-word block FIFO implemented in EG4 block RAM. SHOWAHEAD keeps the
// current head word visible while rd_en is presented to the SDRAM controller.
module pixel_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_BITS  = 9
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    output wire                  full
);
    EG_LOGIC_RAMFIFO #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_BITS),
        .SHOWAHEAD(1),
        .IMPLEMENT("AUTO")
    ) u_block_fifo (
        .rst(rst),.di(wr_data),.clk(clk),.re(rd_en),.we(wr_en),
        .do(rd_data),.empty_flag(empty),.full_flag(full),
        .rdusedw(),.wrusedw()
    );
endmodule
