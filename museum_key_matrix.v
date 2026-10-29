`timescale 1ns/1ps
// Core-board 4x4 keypad. Rows are open-drain, columns have board pull-ups.
// KEY number = row*4+column. Reject multiple-key/ghost combinations.
module museum_key_matrix #(parameter CLK_HZ=100000000)(
 input wire clk,reset,input wire [3:0] cols,inout wire [3:0] rows,
 output reg right_event,left_event,toggle_event,
 output reg brightness_down_event,contrast_down_event,
 output reg zoom_tl_event,zoom_tr_event,zoom_bl_event,zoom_br_event,
 output reg zoom_in_event,zoom_out_event,zoom_home_event,zoom_page_event,zoom_center_event,zoom_enter_event,
 output reg video_event,video_exit_event
);
 localparam TICK=(CLK_HZ/4000>0)?CLK_HZ/4000:1;
 reg [15:0] timer;reg [1:0] row;
 reg [3:0] c1,c2;reg [15:0] captured,stable,candidate;
 reg [4:0] debounce;reg [9:0] hold_count;
 // Register the complete scan before debounce/repeat comparisons. This
 // separates the one-hot detector from the 100MHz event-control path.
 reg scan_done;reg [15:0] sampled_keys;
 // Decode the stable scan before applying events. Scans are one millisecond
 // apart; this extra clock preserves debounce/repeat timing and separates
 // wide key comparisons from the hold-counter and event muxes.
 reg scan_apply,key_changed,debounced,candidate_changed,video_held,repeat_held;
 wire [15:0] complete={~c2,captured[11:0]};
 wire single=(complete!=0)&&((complete&(complete-1'b1))==0);
 wire [15:0] keys=single?complete:16'd0;
 genvar r;generate for(r=0;r<4;r=r+1)begin:drive
   assign rows[r]=(row==r)?1'b0:1'bz;
 end endgenerate
 always @(posedge clk or posedge reset)begin
   if(reset)begin timer<=0;row<=0;c1<=15;c2<=15;captured<=0;stable<=0;
     candidate<=0;debounce<=0;hold_count<=0;right_event<=0;left_event<=0;toggle_event<=0;
     scan_done<=0;sampled_keys<=0;video_event<=0;video_exit_event<=0;brightness_down_event<=0;contrast_down_event<=0;
     scan_apply<=0;key_changed<=0;debounced<=0;candidate_changed<=0;video_held<=0;repeat_held<=0;
     zoom_tl_event<=0;zoom_tr_event<=0;zoom_bl_event<=0;zoom_br_event<=0;
     zoom_in_event<=0;zoom_out_event<=0;zoom_home_event<=0;zoom_page_event<=0;zoom_center_event<=0;zoom_enter_event<=0;end
   else begin
     c1<=cols;c2<=c1;video_event<=0;video_exit_event<=0;right_event<=0;left_event<=0;toggle_event<=0;scan_done<=0;
     scan_apply<=scan_done;
     if(scan_done)begin
       key_changed<=sampled_keys!=candidate;
       debounced<=debounce>=20;
       candidate_changed<=stable!=candidate;
       video_held<=sampled_keys==stable&&stable==16'h0100;
       repeat_held<=sampled_keys==stable&&(stable==16'h0001||stable==16'h0002||stable==16'h0004||stable==16'h0008||
                    stable==16'h0040||stable==16'h4000||stable==16'h0200||stable==16'h0800);
     end
     brightness_down_event<=0;contrast_down_event<=0;
     zoom_tl_event<=0;zoom_tr_event<=0;zoom_bl_event<=0;zoom_br_event<=0;
     zoom_in_event<=0;zoom_out_event<=0;zoom_home_event<=0;zoom_page_event<=0;zoom_center_event<=0;zoom_enter_event<=0;
     if(timer==TICK-1)begin
       timer<=0;row<=row+1'b1;
       case(row)
         0:captured[3:0]<=~c2;1:captured[7:4]<=~c2;2:captured[11:8]<=~c2;
         3:begin
           captured[15:12]<=~c2;
           sampled_keys<=keys;scan_done<=1;
         end
       endcase
     end else timer<=timer+1'b1;
     if(scan_apply)begin
           if(key_changed)begin candidate<=sampled_keys;debounce<=0;end
           else if(!debounced)debounce<=debounce+1'b1;
           else if(candidate_changed)begin
             stable<=candidate;hold_count<=0;
             if(candidate==16'h0001)right_event<=1;
             if(candidate==16'h0002)left_event<=1;
             if(candidate==16'h0010)toggle_event<=1;
             if(candidate==16'h0004)brightness_down_event<=1;
             if(candidate==16'h0008)contrast_down_event<=1;
             // Physical cross: KEY6 up, KEY14 down, KEY9 left, KEY11 right.
             // KEY10 confirms/exits, KEY15 cycles magnification.
             if(candidate==16'h0040)zoom_tl_event<=1;
             if(candidate==16'h4000)zoom_tr_event<=1;
             if(candidate==16'h0200)zoom_bl_event<=1;
             if(candidate==16'h0800)zoom_br_event<=1;
             if(candidate==16'h8000)zoom_in_event<=1;
             if(candidate==16'h0080)zoom_out_event<=1;
             if(candidate==16'h0020)zoom_home_event<=1;
             if(candidate==16'h1000)zoom_page_event<=1;
             if(candidate==16'h2000)zoom_center_event<=1;
             if(candidate==16'h0400)zoom_enter_event<=1;
             if(candidate==16'h0100)video_event<=1;
           end else if(video_held)begin
             if(hold_count==999)begin video_exit_event<=1;hold_count<=1000;end
             else if(hold_count<1000)hold_count<=hold_count+1'b1;
           end else if(repeat_held)begin
             if(hold_count==299)begin
               hold_count<=(stable[2]||stable[3])?199:249;right_event<=stable[0];left_event<=stable[1];
               brightness_down_event<=stable[2];contrast_down_event<=stable[3];
               zoom_tl_event<=stable[6];zoom_tr_event<=stable[14];zoom_bl_event<=stable[9];zoom_br_event<=stable[11];
             end else hold_count<=hold_count+1'b1;
           end else hold_count<=0;
     end
   end
 end
endmodule
