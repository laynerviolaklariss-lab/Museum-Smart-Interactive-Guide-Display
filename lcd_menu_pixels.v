`timescale 1ns/1ps

module lcd_menu_pixels(
 input wire clk,input wire [7:0] x,input wire [8:0] y,
 input wire [56:0] status,input wire [7:0] main_error,input wire main_ready,
 input wire touch_present,touch_fault,output wire [15:0] rgb565,input wire [46:0] zoom_status
);
 // Existing ERROR row must remain visible after any video/zoom exit.
 wire error_active=main_error!=0;
 wire zoom_page=zoom_status[46]&&!error_active,cover_page=zoom_status[45];
 wire media_page=(zoom_status[42:40]==7)&&!error_active;
 wire [2:0] zoom_level=zoom_status[42:40];
 wire zoom_running=zoom_status[44],zoom_aiming=zoom_status[43];
 wire view_on=zoom_running||zoom_aiming;
 wire [9:0] focus_x=zoom_status[39:30],focus_y=zoom_status[29:20];
 wire [9:0] origin_x=zoom_status[19:10],origin_y=zoom_status[9:0];
 wire [7:0] box_x=8'd40+origin_x[9:2];wire [8:0] box_y=9'd40+origin_y[9:2];
 wire [7:0] box_w=!view_on?160:(zoom_level==0)?107:(zoom_level==1)?80:(zoom_level==2)?64:(zoom_level==3)?54:(zoom_level==4)?46:40;
 wire [8:0] box_h=!view_on?120:(zoom_level==0)?80:(zoom_level==1)?60:(zoom_level==2)?48:(zoom_level==3)?40:(zoom_level==4)?35:30;
 wire locator=(x>=40&&x<200&&y>=40&&y<160);
 wire locator_edge=(x==40||x==199||y==40||y==159);
 wire view_edge=(x>=box_x&&x<box_x+box_w&&y>=box_y&&y<box_y+box_h)&&
    (x==box_x||x==box_x+box_w-1||y==box_y||y==box_y+box_h-1);
 wire focus_mark=(x==8'd40+focus_x[9:2]||y==9'd40+focus_y[9:2]);
 wire [2:0] exhibit=status[45:43];wire signed [7:0] bright=status[41:34];wire [6:0] contrast=status[33:27];
 wire compare=status[56];wire [9:0] split=status[55:46];
 wire is_auto=status[42];wire [11:0] sw=status[26:15],sh=status[14:3];
 wire [7:0] bright_abs=bright[7]?(~bright+8'd1):bright;
 wire [13:0] contrast_scaled=contrast*14'd100+14'd32;
 wire [7:0] contrast_percent=contrast_scaled[13:6];
 wire [7:0] b_tens=bright_abs/8'd10,b_ones=bright_abs%8'd10;
 wire [7:0] c_hundreds=contrast_percent/8'd100,c_tens=(contrast_percent/8'd10)%8'd10,c_ones=contrast_percent%8'd10;
 wire [2:0] audio=status[2:0];
 reg [119:0] text_line;reg [7:0] glyph;
 wire button_area=(y>=144&&y<304);
 wire [7:0] local_x=(button_area&&x>=120)?x-8'd120:x;
 wire [7:0] text_x=local_x-8'd4;
 wire text_x_valid=local_x>=4&&(button_area?local_x<116:local_x<240);
 wire [3:0] col=text_x[7:4];
 wire [8:0] local_y=(y<128)?y:(y>=304)?y-9'd304:
                    (y<184)?y-9'd156:(y<224)?y-9'd196:(y<264)?y-9'd236:y-9'd276;
 wire text_y_valid=(y<128)||(y>=304)||
                   (y>=156&&y<172)||(y>=196&&y<212)||(y>=236&&y<252)||(y>=276&&y<292);
 function [7:0] digit(input [3:0] d);begin digit=(d<10)?8'd48+d:8'd63;end endfunction
 function [7:0] hexchar(input [3:0] d);begin hexchar=(d<10)?8'd48+d:8'd55+d;end endfunction
 always @(*)begin
   text_line=120'h202020202020202020202020202020;
   if(y<128)begin
     case(y[6:4])
       0:text_line=120'h4d555345554d2050414e454c202020;
       1:text_line={72'h455848494249542030,8'd48+{5'd0,exhibit},40'h2F30362020};
       2:case(exhibit)
           0:text_line="CHINA MUSEUM   ";
           1:text_line="FU HAO BRONZE  ";
           2:text_line="JI HONGCHANG   ";
           3:text_line="GONG XIAN FAN  ";
           4:text_line="DNIEPER AUTUMN ";
           5:text_line="RENT REDUCTION ";
           6:text_line="RED SILK SKIRT ";
           default:text_line="               ";
         endcase
       3:text_line={32'h53524320,digit(sw[11:8]),digit(sw[7:4]),digit(sw[3:0]),8'h58,
                       digit(sh[11:8]),digit(sh[7:4]),digit(sh[3:0]),32'h20202020};
       4:text_line=compare?"COMPARE PAUSED ":is_auto?"MODE AUTO      ":"MODE MANUAL    ";
       5:text_line={16'h423A,(bright[7]?8'd45:8'd43),8'd48+b_tens,8'd48+b_ones,
           24'h20433A,8'd48+c_hundreds,8'd48+c_tens,8'd48+c_ones,32'h25202020};
       6:case(audio)
           0:text_line=120'h415544494f204d5553494320202020;
           1:text_line=120'h415544494f2035303020485a202020;
           2:text_line=120'h415544494f20314b20485a20202020;
           3:text_line=120'h415544494f20324b20485a20202020;
           default:text_line=120'h415544494f204d5554452020202020;
         endcase
       7:if(main_error!=0)text_line={64'h4552524F52203058,hexchar(main_error[7:4]),hexchar(main_error[3:0]),40'h2020202020};
         else text_line=main_ready?120'h535441544520524541445920202020:120'h5354415445204c4f41442020202020;
     endcase
   end else if(button_area)begin
     if(y<184)text_line=(x<120)?120'h4e4558542020202020202020202020:120'h505245562020202020202020202020;
     else if(y<224)text_line=(x<120)?120'h4155544f2020202020202020202020:120'h415544494f20202020202020202020;
     else if(y<264)text_line=(x<120)?"B-  B+         ":"C-  C+         ";
     else text_line=(x<120)?"DEFAULT        ":"COMPARE        ";
   end else if(y>=304)text_line=touch_fault?120'h544f554348204552524f5220202020:
                                  touch_present?120'h544f554348204f4b20202020202020:120'h544f55434820574149542020202020;
   if(zoom_page)begin
     if(y<16)text_line=cover_page?"COVER NO ZOOM  ":"ZOOM LOCATOR   ";
     else if(y<32)begin
       if(!view_on)text_line="KEY10 AIM      ";
       else case(zoom_level)
         0:text_line="1.5X  KEY15 +  ";1:text_line="2.0X  KEY15 +  ";2:text_line="2.5X  KEY15 +  ";
         3:text_line="3.0X  KEY15 +  ";4:text_line="3.5X  KEY15 +  ";default:text_line="4.0X  KEY15 +  ";
       endcase
     end
     else if(y>=184&&y<224)text_line=(x<120)?"ZOOM +         ":"ZOOM -         ";
     else if(y>=224&&y<264)text_line=(x<120)?"RESET          ":"CENTER         ";
     else if(y>=264&&y<304)text_line="BACK           ";
     else if(y>=304)text_line=touch_fault?"TOUCH ERROR    ":"KEY12 BACK     ";
     else text_line="               ";
   end
   if(media_page)begin
     text_line="               ";
     if(y<16)text_line="GROUP 1 VIDEO  ";
     else if(y<32)text_line=zoom_aiming?"PAUSED         ":zoom_running?"PLAYING        ":"BUFFERING      ";
     else if(y>=48&&y<64)text_line="320X240 10FPS  ";
     else if(y>=80&&y<96)text_line="KEY8 PLAY/PAUSE";
     else if(y>=112&&y<128)text_line="HOLD KEY8 EXIT ";
     else if(y>=184&&y<224)text_line=(x<120)?(zoom_aiming?"PLAY           ":zoom_running?"PAUSE          ":"WAIT           "):"STOP           ";
     else if(y>=264&&y<304)text_line="EXIT           ";
   end
   glyph=(text_line>>((4'd14-col)*8));
 end
 wire [7:0] font_bits;
 lcd_ui_font u_font(clk,glyph[6:0],local_y[3:1],font_bits);
 wire ink=text_x_valid&&text_y_valid&&font_bits[7-text_x[3:1]];
 wire border=button_area&&(x==0||x==119||x==120||x==239||((y>=224&&y<264)&&(x==60||x==180))||
                           y==144||y==183||y==184||y==223||y==224||y==263||y==264||y==303);
 wire [15:0] background=button_area?16'h1948:16'h0861;
 wire [9:0] slider_x=(x>=12)?(({2'd0,x}-10'd12)<<1)+({2'd0,x}-10'd12):10'd0;
 wire thumb=(x>=12&&x<228)&&(slider_x>=split)&&(slider_x<split+10'd3);
 wire [15:0] menu_rgb=(y>=128&&y<144)?((x<12||x>=228)?16'h0861:
                thumb?16'hFFFF:(slider_x<split)?16'hFBA0:16'h07F0):
               ink?16'hFFFF:border?16'h7BEF:background;
 assign rgb565=media_page?(ink?16'hFFFF:16'h0861):zoom_page?((locator)?
     (locator_edge?16'hFFFF:cover_page?16'h2104:view_edge?16'hFFE0:focus_mark?16'hF800:16'h1948):
     ink?16'hFFFF:(border&&y>=184)?16'h7BEF:16'h0861):menu_rgb;
endmodule

