`timescale 1ns/1ps
// Fine bounded controls. Requests accumulate; visible parameters update ONLY
// at VBlank. Opposite simultaneous events cancel. Default has priority.
module image_adjust_control #(parameter integer HUD_FRAMES=120)(
 input wire clk,reset,frame_end,
 input wire brightness_press,contrast_press,default_press,
 input wire brightness_down,contrast_down,
 output reg signed [7:0] brightness_level,
 output reg [6:0] contrast_level,output wire hud_visible
);
 reg signed [7:0] pending_brightness,next_brightness;
 reg [6:0] pending_contrast,next_contrast;
 reg pending_event;reg [7:0] hud_frames;
 wire request_event=brightness_press||contrast_press||default_press||brightness_down||contrast_down;
 always @(*)begin
  next_brightness=pending_brightness;next_contrast=pending_contrast;
  if(default_press)begin next_brightness=0;next_contrast=64;end
  else begin
   if(brightness_press&&!brightness_down&&pending_brightness<64)
    next_brightness=pending_brightness+8'sd2;
   else if(brightness_down&&!brightness_press&&pending_brightness>-64)
    next_brightness=pending_brightness-8'sd2;
   if(contrast_press&&!contrast_down&&pending_contrast<96)next_contrast=pending_contrast+1'b1;
   else if(contrast_down&&!contrast_press&&pending_contrast>32)next_contrast=pending_contrast-1'b1;
  end
 end
 always @(posedge clk or posedge reset)begin
  if(reset)begin
   pending_brightness<=0;pending_contrast<=64;brightness_level<=0;contrast_level<=64;
   pending_event<=0;hud_frames<=0;
  end else begin
   pending_brightness<=next_brightness;pending_contrast<=next_contrast;
   if(request_event)pending_event<=1;
   if(frame_end)begin
    brightness_level<=next_brightness;contrast_level<=next_contrast;pending_event<=0;
    if(pending_event||request_event)hud_frames<=HUD_FRAMES;
    else if(hud_frames!=0)hud_frames<=hud_frames-1'b1;
   end
  end
 end
 assign hud_visible=(hud_frames!=0);
endmodule
