`timescale 1ns/1ps
// Gain Q6: 32..96 (0.5..1.5), offset -64..64. Three parallel small signed
// products; no added pixel latency. Saturate rather than unsigned wrap.
module image_color_adjust(
 input wire [23:0] rgb_in,input wire signed [7:0] brightness_level,
 input wire [6:0] contrast_level,output wire [23:0] rgb_out
);
 function [7:0] adjust_channel;
  input [7:0] value;input signed [7:0] brightness;input [6:0] contrast;
  reg signed [8:0] centered;reg signed [7:0] gain;
  reg signed [16:0] product,result;
  begin
   centered=$signed({1'b0,value})-9'sd128;gain=$signed({1'b0,contrast});
   product=centered*gain;
   result=(product>>>6)+17'sd128+brightness;
   if(result<0)adjust_channel=0;
   else if(result>255)adjust_channel=255;
   else adjust_channel=result[7:0];
  end
 endfunction
 assign rgb_out={adjust_channel(rgb_in[23:16],brightness_level,contrast_level),
                 adjust_channel(rgb_in[15:8],brightness_level,contrast_level),
                 adjust_channel(rgb_in[7:0],brightness_level,contrast_level)};
endmodule
