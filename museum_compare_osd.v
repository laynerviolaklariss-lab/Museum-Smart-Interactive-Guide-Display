`timescale 1ns/1ps
// A/B pixels have already been selected in the SDRAM line-fetch path.
// This module adds only labels, a divider and its pixel-position text.
module museum_compare_osd(input wire clk,reset,input wire [9:0] x,y,
 input wire frame_end,enabled,input wire [9:0] split,input wire diagnostic,
 input wire [23:0] base_rgb,output wire [23:0] rgb);
 reg [9:0] shown_split,remaining;reg [3:0] hundreds,tens,ones;
 reg [3:0] work_hundreds,work_tens;reg converting;
 always @(posedge clk or posedge reset)begin
   if(reset)begin shown_split<=320;remaining<=320;hundreds<=3;tens<=2;ones<=0;
     work_hundreds<=0;work_tens<=0;converting<=1;end
   else if(split!=shown_split)begin
     shown_split<=split;remaining<=split;work_hundreds<=0;work_tens<=0;converting<=1;
   end else if(converting)begin
     if(remaining>=100)begin remaining<=remaining-100;work_hundreds<=work_hundreds+1'b1;end
     else if(remaining>=10)begin remaining<=remaining-10;work_tens<=work_tens+1'b1;end
     else begin hundreds<=work_hundreds;tens<=work_tens;ones<=remaining[3:0];converting<=0;end
   end
 end
 // Chinese comparison labels share the existing OSD font lookup; never
 // duplicate the complete Chinese glyph ROM for two three-character labels.
 wire header=enabled&&x>=96&&x<208&&y>=40&&y<48;
 wire [3:0] character=(x-96)>>3;reg [7:0] ch;
 always @(*)case(character)
   0:ch="S";1:ch="P";2:ch="L";3:ch="I";4:ch="T";5:ch=":";
   6:ch=48+hundreds;7:ch=48+tens;8:ch=48+ones;9:ch="p";10:ch="x";
   default:ch=" ";endcase
 wire [7:0] bits;
 audio_wave_font u_ascii(.glyph(ch),.row(y[2:0]),.bits(bits));
 wire ink=header&&bits[7-x[2:0]];
 wire divider=enabled&&split>0&&split<640&&x==split&&y>=84&&y<384;
 wire handle=enabled&&split>0&&split<640&&y>=226&&y<242&&
    x+6>=split&&x<=split+6;
 wire [23:0] dark={1'b0,base_rgb[23:17],1'b0,base_rgb[15:9],1'b0,base_rgb[7:1]};
 assign rgb=diagnostic?base_rgb:divider||handle?24'hffe080:ink?24'hffffff:
     header?dark:base_rgb;
endmodule
