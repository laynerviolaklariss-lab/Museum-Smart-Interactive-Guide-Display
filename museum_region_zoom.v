`timescale 1ns/1ps
// Reference-layout viewfinder, using the accepted frame/row ownership protocol.
// KEY6/14/9/11 = up/down/left/right; KEY10 enter/confirm/exit; KEY15 +0.5x cycle.
module museum_region_zoom #(parameter PAN_STEP=8)(
 input wire clk,reset,vblank,
 input wire zoom_tl,zoom_tr,zoom_bl,zoom_br,
 input wire zoom_in,zoom_out,zoom_home,zoom_center,zoom_enter,zoom_cycle,
 input wire locate_valid,input wire [9:0] locate_x,locate_y,
 input wire compare_mode,cover_page,
 output wire [1:0] pos,output reg [2:0] level,
 output wire [9:0] win_x,win_y,output wire [12:0] scale,
 output wire active,output reg [9:0] focus_x,focus_y,
 output wire aim_mode,zoom_mode,output wire [9:0] aim_w,aim_h
);
 localparam IDLE=2'd0,AIM=2'd1,ZOOM=2'd2;
 localparam [9:0] STEP=PAN_STEP;
 reg [1:0] state;
 reg [12:0] target_k,anim_k;
 function [12:0] factor(input [2:0] i);begin
  case(i)0:factor=2731;1:factor=2048;2:factor=1638;3:factor=1365;4:factor=1170;default:factor=1024;endcase
 end endfunction
 wire [2:0] cycle_level=(level==5)?3'd0:level+1'b1;
 wire enabled=!compare_mode&&!cover_page;
 wire [12:0] geometry_k=(state==AIM)?factor(level):(state==ZOOM)?anim_k:13'd4096;
 reg [9:0] view_w,view_h,f1x,f1y,raw2x,raw2y,max2x,max2y,out_x,out_y;
 reg [9:0] w2,h2,w3,h3;
 reg [12:0] k1,k2,k3;
 reg [3:0] aiming,zooming;reg [12:0] geometry_q;reg [9:0] f0x,f0y;
 wire [15:0] width_full=({3'd0,geometry_q}<<2)+{3'd0,geometry_q}+16'd31;
 wire [15:0] height_full=({3'd0,geometry_q}<<4)-{3'd0,geometry_q}+16'd127;
 wire [9:0] half_w=view_w>>1,half_h=view_h>>1;
 wire [9:0] max_x=10'd640-view_w,max_y=10'd480-view_h;
 always @(posedge clk or posedge reset)begin
  if(reset)begin
   view_w<=640;view_h<=480;f1x<=320;f1y<=240;k1<=4096;
   raw2x<=0;raw2y<=0;max2x<=0;max2y<=0;k2<=4096;
   out_x<=0;out_y<=0;k3<=4096;w2<=640;h2<=480;w3<=640;h3<=480;
   aiming<=0;zooming<=0;geometry_q<=4096;f0x<=320;f0y<=240;
  end else begin
   geometry_q<=geometry_k;f0x<=focus_x;f0y<=focus_y;
   view_w<=width_full[14:5];view_h<={1'b0,height_full[15:7]};
   // Exact sampled footprints for settled half-step ratios. The animation
   // fallback is conservative; fixed targets must reach the last source row.
   case(geometry_q)
    2731:begin view_w<=427;view_h<=320;end
    2048:begin view_w<=320;view_h<=240;end
    1638:begin view_w<=256;view_h<=192;end
    1365:begin view_w<=213;view_h<=160;end
    1170:begin view_w<=183;view_h<=137;end
    1024:begin view_w<=160;view_h<=120;end
    default:begin end
   endcase
   f1x<=f0x;f1y<=f0y;k1<=geometry_q;
   raw2x<=(f1x>half_w)?f1x-half_w:10'd0;
   raw2y<=(f1y>half_h)?f1y-half_h:10'd0;
   max2x<=max_x;max2y<=max_y;k2<=k1;w2<=view_w;h2<=view_h;
   out_x<=(raw2x>max2x)?max2x:raw2x;out_y<=(raw2y>max2y)?max2y:raw2y;k3<=k2;w3<=w2;h3<=h2;
   aiming<={aiming[2:0],state==AIM};zooming<={zooming[2:0],state==ZOOM};
  end
 end
 assign scale=k3;
 assign win_x=enabled?out_x:10'd0;assign win_y=enabled?out_y:10'd0;
 assign aim_mode=enabled&&aiming[3];assign zoom_mode=enabled&&zooming[3];
 assign active=zoom_mode&&(k3!=4096);
 assign aim_w=w3;assign aim_h=h3;assign pos=0;
 reg [9:0] pan_min_x,pan_max_x,pan_min_y,pan_max_y;
 reg [9:0] min_step_x,max_step_x,min_step_y,max_step_y;
 wire limited=(aim_mode||zoom_mode)&&(k3!=4096);
 always @(posedge clk or posedge reset)begin
  if(reset)begin
   pan_min_x<=0;pan_min_y<=0;pan_max_x<=639;pan_max_y<=479;
   min_step_x<=STEP;min_step_y<=STEP;max_step_x<=639-STEP;max_step_y<=479-STEP;
  end else begin
   pan_min_x<=limited?half_w:10'd0;pan_max_x<=limited?(max_x+half_w):10'd639;
   pan_min_y<=limited?half_h:10'd0;pan_max_y<=limited?(max_y+half_h):10'd479;
   min_step_x<=(pan_max_x-pan_min_x<STEP)?pan_max_x:pan_min_x+STEP;
   max_step_x<=(pan_max_x-pan_min_x<STEP)?pan_min_x:pan_max_x-STEP;
   min_step_y<=(pan_max_y-pan_min_y<STEP)?pan_max_y:pan_min_y+STEP;
   max_step_y<=(pan_max_y-pan_min_y<STEP)?pan_min_y:pan_max_y-STEP;
  end
 end
 always @(posedge clk or posedge reset)begin
  if(reset)begin state<=IDLE;level<=1;anim_k<=4096;target_k<=4096;focus_x<=320;focus_y<=240;end
  else if(enabled)begin
   if(zoom_home)begin
    state<=IDLE;level<=1;anim_k<=4096;target_k<=4096;focus_x<=320;focus_y<=240;
   end else if(zoom_enter)begin
    case(state)
     IDLE:begin state<=AIM;level<=1;focus_x<=320;focus_y<=240;anim_k<=4096;target_k<=4096;end
     AIM:begin state<=ZOOM;anim_k<=4096;target_k<=factor(level);end
     default:begin state<=IDLE;anim_k<=4096;target_k<=4096;end
    endcase
   end else begin
    if(zoom_center)begin focus_x<=320;focus_y<=240;end
    else if(locate_valid)begin focus_x<=(locate_x>639)?10'd639:locate_x;focus_y<=(locate_y>479)?10'd479:locate_y;end
    else if(state!=IDLE)begin
     if(zoom_tl)focus_y<=(focus_y>pan_max_y)?max_step_y:(focus_y>min_step_y)?focus_y-STEP:pan_min_y;
     if(zoom_tr)focus_y<=(focus_y<pan_min_y)?min_step_y:(focus_y<max_step_y)?focus_y+STEP:pan_max_y;
     if(zoom_bl)focus_x<=(focus_x>pan_max_x)?max_step_x:(focus_x>min_step_x)?focus_x-STEP:pan_min_x;
     if(zoom_br)focus_x<=(focus_x<pan_min_x)?min_step_x:(focus_x<max_step_x)?focus_x+STEP:pan_max_x;
    end
    if(zoom_cycle&&state!=IDLE)begin level<=cycle_level;target_k<=factor(cycle_level);end
    else if(zoom_in)begin
     if(state==IDLE)begin state<=ZOOM;level<=0;anim_k<=4096;target_k<=2731;end
     else if(level<5)begin level<=level+1'b1;target_k<=factor(level+1'b1);end
    end else if(zoom_out&&state!=IDLE)begin
     if(level==0)begin state<=IDLE;anim_k<=4096;target_k<=4096;end
     else begin level<=level-1'b1;target_k<=factor(level-1'b1);end
    end else if(vblank&&state==ZOOM)begin
     if(anim_k>target_k)anim_k<=((anim_k-target_k)<=64)?target_k:anim_k-13'd64;
     else if(anim_k<target_k)anim_k<=((target_k-anim_k)<=64)?target_k:anim_k+13'd64;
    end
   end
  end
 end
endmodule
