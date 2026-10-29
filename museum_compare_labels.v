module museum_compare_labels(input wire after_label,input wire [1:0] index,output reg [7:0] glyph);
always @(*)begin case(index)
0:glyph=8'd52;1:glyph=8'd90;2:glyph=after_label?8'd80:8'd67;
default:glyph=0;endcase end endmodule
