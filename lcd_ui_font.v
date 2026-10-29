`timescale 1ns/1ps
// One synchronous 8 Ki-bit ROM replaces the combinational glyph/row mux.
// Address and one-clock output timing match the original LCD font exactly.
module lcd_ui_font(input wire clk,input wire [6:0] glyph,input wire [2:0] row,output wire [7:0] bits);
 EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.DATA_WIDTH_B(8),
 .ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),.DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),
 .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("SP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.FORCE_KEEP("ON"),.IMPLEMENT("9K"),
 .INIT_FILE("lcd_ui_font.dat")) rom(
 .doa(bits),.dob(),.dia(8'd0),.dib(8'd0),
 .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
 .ceb(1'b0),.oceb(1'b0),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
 .addra({glyph,row}),.addrb(10'd0));
endmodule
