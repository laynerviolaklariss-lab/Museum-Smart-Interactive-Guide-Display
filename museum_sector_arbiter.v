`timescale 1ns/1ps
// Requests are pulses: retain each pending LBA until its tagged transaction
// completes. Only its owner sees bytes/done/errors. Arbitration per sector.
module museum_sector_arbiter(
 input wire clk,reset,input wire music_low,
 input wire loc_req,img_req,music_req,
 input wire [31:0] loc_lba,img_lba,music_lba,
 output wire client_busy,output reg host_req,output reg [31:0] host_lba,
 input wire host_busy,host_done,host_error,
 output wire loc_selected,img_selected,music_selected
);
 reg [2:0] pending;reg [31:0] lba0,lba1,lba2;
 reg active;reg [1:0] owner;reg music_last;
 assign client_busy=active||host_busy||(|pending);
 assign loc_selected=active&&owner==0;
 assign img_selected=active&&owner==1;
 assign music_selected=active&&owner==2;
 always @(posedge clk or posedge reset)begin
   if(reset)begin pending<=0;lba0<=0;lba1<=0;lba2<=0;active<=0;owner<=0;
     host_req<=0;host_lba<=0;music_last<=0;end
   else begin
     host_req<=0;
     if(loc_req)begin pending[0]<=1;lba0<=loc_lba;end
     if(img_req)begin pending[1]<=1;lba1<=img_lba;end
     if(music_req)begin pending[2]<=1;lba2<=music_lba;end
     if(active)begin if(host_done||host_error)active<=0;end
     else if(!host_busy)begin
       if(pending[2]&&(music_low||!music_last||!(pending[0]||pending[1])))begin
         pending[2]<=0;host_lba<=lba2;owner<=2;active<=1;host_req<=1;music_last<=1;
       end else if(pending[0])begin
         pending[0]<=0;host_lba<=lba0;owner<=0;active<=1;host_req<=1;music_last<=0;
       end else if(pending[1])begin
         pending[1]<=0;host_lba<=lba1;owner<=1;active<=1;host_req<=1;music_last<=0;
       end
     end
   end
 end
endmodule
