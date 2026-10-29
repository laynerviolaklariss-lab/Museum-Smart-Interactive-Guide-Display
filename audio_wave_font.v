`timescale 1ns/1ps
// Small 8x8 ASCII font, doubled to 16x16. Separate from the Chinese OSD ROM.
module audio_wave_font(input wire [7:0] glyph,input wire [2:0] row,output wire [7:0] bits);
    reg [63:0] bitmap;
    always @(*) begin
        case(glyph)
            8'd48: bitmap=64'h3c666e7666663c00;
            8'd66: bitmap=64'h7c66667c66667c00;
            8'd43: bitmap=64'h0018187e18180000;
            8'd45: bitmap=64'h0000007e00000000;
            8'd49: bitmap=64'h1838181818187e00;
            8'd50: bitmap=64'h3c66060c30607e00;
            8'd51: bitmap=64'h3c66061c06663c00;
            8'd52: bitmap=64'h0c1c3c6c7e0c0c00;
            8'd53: bitmap=64'h7e607c0606663c00;
            8'd54: bitmap=64'h1c30607c66663c00;
            8'd55: bitmap=64'h7e66060c18181800;
            8'd56: bitmap=64'h3c66663c66663c00;
            8'd57: bitmap=64'h3c66663e060c3800;
            8'd77: bitmap=64'h63777f6b63636300;
            8'd85: bitmap=64'h6666666666663c00;
            8'd83: bitmap=64'h3c66603c06663c00;
            8'd73: bitmap=64'h3c18181818183c00;
            8'd67: bitmap=64'h3c66606060663c00;
            8'd70: bitmap=64'h7e60607c60606000;
            8'd80: bitmap=64'h7c66667c60606000;
            8'd75: bitmap=64'h666c7870786c6600;
            8'd72: bitmap=64'h6666667e66666600;
            8'd84: bitmap=64'h7e18181818181800;
            8'd69: bitmap=64'h7e60607c60607e00;
            8'd87: bitmap=64'h6363636b7f776300;
            8'd65: bitmap=64'h183c66667e666600;
            8'd79: bitmap=64'h3c66666666663c00;
            8'd86: bitmap=64'h66666666663c1800;
            8'd82: bitmap=64'h7c66667c786c6600;
            8'd107: bitmap=64'h6060666c786c6600;
            8'd122: bitmap=64'h00007e0c18307e00;
            8'd58: bitmap=64'h0018180018180000;
            8'd37: bitmap=64'h62660c1830664600;
            8'd76: bitmap=64'h6060606060607e00;
            8'd112:bitmap=64'h00007c66667c6060;
            8'd120:bitmap=64'h0000663c183c6600;
            default:bitmap=64'd0;
        endcase
    end
    assign bits=bitmap>>((3'd7-row)*8);
endmodule
