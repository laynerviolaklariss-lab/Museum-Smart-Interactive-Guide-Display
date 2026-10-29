`timescale 1ns/1ps
// 64x64 Anlogic logo, quantized to transparent/navy/red for FPGA OSD.
// Generated from D:/桌面/logo.png; row masks preserve the original geometry.
module anlogic_logo_rom(
    input  wire [5:0] x,
    input  wire [5:0] y,
    output wire       pixel_valid,
    output wire [23:0] pixel_rgb
);
    reg [63:0] navy_mask;
    reg [63:0] red_mask;
    always @(*) begin
        navy_mask = 64'd0;
        red_mask  = 64'd0;
        case (y)
            6'd0: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd1: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd2: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd3: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd4: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd5: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd6: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd7: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd8: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd9: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd10: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd11: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd12: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd13: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd14: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd15: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd16: begin navy_mask=64'h0000020000000040; red_mask=64'h0000007FFFFFFF80; end
            6'd17: begin navy_mask=64'h0000034000000000; red_mask=64'h0000003FFFFFFF80; end
            6'd18: begin navy_mask=64'h0000070000000000; red_mask=64'h0000000000000000; end
            6'd19: begin navy_mask=64'h0000078000000000; red_mask=64'h0000000000000000; end
            6'd20: begin navy_mask=64'h00000F8000000100; red_mask=64'h0000001FFFFFFE00; end
            6'd21: begin navy_mask=64'h00000FC000000200; red_mask=64'h0000000FFFFFFC00; end
            6'd22: begin navy_mask=64'h00001FC000000000; red_mask=64'h0000000000000000; end
            6'd23: begin navy_mask=64'h00001FE3FFFFF400; red_mask=64'h0000000400000800; end
            6'd24: begin navy_mask=64'h00003FE000000400; red_mask=64'h00000007FFFFF800; end
            6'd25: begin navy_mask=64'h00003FF000000800; red_mask=64'h00000003FFFFF000; end
            6'd26: begin navy_mask=64'h00007FF000000000; red_mask=64'h0000000000000000; end
            6'd27: begin navy_mask=64'h00007FF8FFFFD000; red_mask=64'h0000000100002000; end
            6'd28: begin navy_mask=64'h0000FFF800000000; red_mask=64'h00000001FFFFE000; end
            6'd29: begin navy_mask=64'h0000FFFCFFFFC000; red_mask=64'h0000000000000000; end
            6'd30: begin navy_mask=64'h0001FFFC00000000; red_mask=64'h0000000000000000; end
            6'd31: begin navy_mask=64'h0001FDFE00004000; red_mask=64'h000000007FFF8000; end
            6'd32: begin navy_mask=64'h0003FCFE00000000; red_mask=64'h000000007FFF8000; end
            6'd33: begin navy_mask=64'h0003F8FF00000000; red_mask=64'h0000000000000000; end
            6'd34: begin navy_mask=64'h0007F87F80000000; red_mask=64'h0000000000000000; end
            6'd35: begin navy_mask=64'h0007F07FA0000000; red_mask=64'h000000001FFF0000; end
            6'd36: begin navy_mask=64'h000FF03F80000000; red_mask=64'h000000001FFE0000; end
            6'd37: begin navy_mask=64'h000FE03FC0000000; red_mask=64'h0000000000000000; end
            6'd38: begin navy_mask=64'h001FE01FE0000000; red_mask=64'h0000000000000000; end
            6'd39: begin navy_mask=64'h001FC01FE0000000; red_mask=64'h000000000FFC0000; end
            6'd40: begin navy_mask=64'h003FC00FE0000000; red_mask=64'h0000000007F80000; end
            6'd41: begin navy_mask=64'h003F800FF0000000; red_mask=64'h0000000000000000; end
            6'd42: begin navy_mask=64'h007F8007F8000000; red_mask=64'h0000000000000000; end
            6'd43: begin navy_mask=64'h007FFF83F8000000; red_mask=64'h0000000003F00000; end
            6'd44: begin navy_mask=64'h00FFFFC3FC000000; red_mask=64'h0000000001E00000; end
            6'd45: begin navy_mask=64'h00FFFFC1FC000000; red_mask=64'h0000000000000000; end
            6'd46: begin navy_mask=64'h01FFFFE1FE000000; red_mask=64'h0000000000000000; end
            6'd47: begin navy_mask=64'h01FFFFE0FE000000; red_mask=64'h0000000000C00000; end
            6'd48: begin navy_mask=64'h01FFFFF0FE000000; red_mask=64'h0000000000000000; end
            6'd49: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd50: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd51: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd52: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd53: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd54: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd55: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd56: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd57: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd58: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd59: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd60: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd61: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd62: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            6'd63: begin navy_mask=64'h0000000000000000; red_mask=64'h0000000000000000; end
            default: begin navy_mask=64'd0; red_mask=64'd0; end
        endcase
    end
    wire navy_pixel = navy_mask[6'd63-x];
    wire red_pixel  = red_mask[6'd63-x];
    assign pixel_valid = navy_pixel | red_pixel;
    assign pixel_rgb = red_pixel ? 24'hff2029 : 24'h1c2d4e;
endmodule
