`timescale 1ns/1ps
// MVG1 fixed-format sequential demultiplexer. One complete background frame
// is offered to the existing scan loader; ownership changes only on frame_take.
module museum_video_player #(parameter REPORT_EXIT_CODES=0,parameter RECOVER_UNDERRUN=0)(
 input wire clk,reset,start,toggle_pause,stop,starved,client_busy,
 output wire session,flush,output reg loc_start,stream_start,
 input wire loc_done,loc_error,input wire [7:0] loc_ec,
 input wire byte_valid,input wire [7:0] byte_data,input wire file_last,
 output wire byte_ready,input wire stream_error,input wire [7:0] stream_ec,
 output wire pixel_valid,output wire [31:0] pixel_data,input wire pixel_ready,
 input wire writes_idle,input wire write_fire,output reg [20:0] write_addr,
 output wire pcm_valid,output wire [15:0] pcm_sample,input wire pcm_ready,
 input wire [31:0] played_samples,
 output wire offer,input wire frame_take,output wire [20:0] offered_base,
 output wire [24:0] sample_limit,
 output reg running,paused,output reg [7:0] error_code,
 output reg [15:0] frame_number,output reg [15:0] total_frames,
 input wire [7:0] stop_code,
 input wire buffer_ready,output reg buffering
);
 localparam IDLE=0,CLEAR=1,LOC=2,LOOK=3,START=4,HEADER=5,
            PART=6,AUDIO=7,VIDEO=8,RETIRE=9,WAIT_FRAME=10,FINISH=11,STOP=12;
 reg [3:0] state;reg [14:0] timer;
 reg session_active,flush_active;
 reg [8:0] head_pos;reg [9:0] audio_pos;reg [13:0] video_pos;
 reg [3:0] part_number;reg half;reg [7:0] low_byte;
 reg write_bank;reg [24:0] next_pts;
 reg [24:0] sample_a,sample_b,expected_samples;
 wire [24:0] frames_wide={12'd0,total_frames[12:0]};
 assign sample_limit=expected_samples;
 always @(posedge clk or posedge reset)begin
  if(reset)begin sample_a<=0;sample_b<=0;expected_samples<=0;end
  else begin
   sample_a<=(frames_wide<<12)+(frames_wide<<9);
   sample_b<=(frames_wide<<7)+(frames_wide<<6);
   expected_samples<=sample_a+sample_b;
  end
 end
 // Header/part setup provides hundreds of clocks before these flags
 // are consumed. Split subtraction and comparisons away from EOF/error
 // priority selection without delaying any byte or public control output.
 reg [15:0] last_frame_index;
 reg last_frame_q,last_part_q,final_video_byte;
 always @(posedge clk or posedge reset)begin
  if(reset)begin last_frame_index<=0;last_frame_q<=0;last_part_q<=0;end
  else begin
   last_frame_index<=total_frames-16'd1;
   last_frame_q<=frame_number==last_frame_index;
   last_part_q<=part_number==9;
  end
 end
 reg bad_header;reg frame_due;
 always @(posedge clk or posedge reset)begin
  if(reset)frame_due<=0;else frame_due<=played_samples>=next_pts;
 end
 wire take=byte_valid&&byte_ready;
 // Registered control levels preserve cycle timing and prevent a binary
 // state transition from becoming a pulse on asynchronous FIFO resets.
 assign session=session_active;
 assign flush=flush_active;
 // Refill control stays off the byte/pixel ready paths. The audio domain
 // acknowledges stopped consumption by clearing starved; FIFO contents and
 // the media sample clock are retained throughout this handshake.
 always @(posedge clk or posedge reset)begin
  if(reset)buffering<=0;
  else if(!RECOVER_UNDERRUN||flush_active||!session_active||!running)buffering<=0;
  else if(!paused&&starved)buffering<=1;
  else if(buffering&&!starved&&(buffer_ready||state==FINISH))buffering<=0;
 end
 wire [15:0] word16={byte_data,low_byte};
 assign pcm_sample=word16;
 assign pcm_valid=state==AUDIO&&audio_pos<960&&half&&byte_valid;
 assign pixel_valid=state==VIDEO&&half&&byte_valid;
 assign pixel_data={8'd0,word16[15:11],word16[15:13],word16[10:5],word16[10:9],word16[4:0],word16[4:2]};
 assign byte_ready=(state==HEADER||state==PART)||
   (state==AUDIO&&(audio_pos>=960||!half||pcm_ready))||
   (state==VIDEO&&(!half||pixel_ready));
 assign offer=state==WAIT_FRAME&&!paused&&(!running||frame_due);
 assign offered_base=write_bank?21'd1612800:21'd1536000;
 function [7:0] header_expected(input [8:0] p);begin
  case(p)
   0:header_expected="M";1:header_expected="V";2:header_expected="G";3:header_expected="1";
   4:header_expected=1;6:header_expected=8'h40;7:header_expected=1;8:header_expected=240;
   10:header_expected=10;11:header_expected=1;12:header_expected=8'h80;13:header_expected=8'hbb;
   24:header_expected="R";25:header_expected="G";26:header_expected="B";27:header_expected="5";
   default:header_expected=0;
  endcase
 end endfunction
 task fail(input [7:0] ec);begin error_code<=ec;state<=STOP;session_active<=1;flush_active<=1;timer<=0;running<=0;paused<=0;end endtask
 always @(posedge clk or posedge reset)begin
  if(reset)begin state<=IDLE;session_active<=0;flush_active<=0;timer<=0;loc_start<=0;stream_start<=0;head_pos<=0;
   audio_pos<=0;video_pos<=0;final_video_byte<=0;part_number<=0;half<=0;low_byte<=0;write_bank<=0;
   write_addr<=1536000;next_pts<=0;running<=0;paused<=0;
   error_code<=0;frame_number<=0;total_frames<=0;bad_header<=0;
  end else begin
   loc_start<=0;stream_start<=0;
   if(write_fire)write_addr<=write_addr+1'b1;
   if(session&&state!=STOP&&stop)begin
    state<=STOP;flush_active<=1;timer<=0;running<=0;paused<=0;
    if(REPORT_EXIT_CODES)error_code<=stop_code;
   end
   else if(!RECOVER_UNDERRUN&&running&&!paused&&starved)fail(8'hb3);
   else if(session&&state>=HEADER&&state<=FINISH&&stream_error)fail(stream_ec);
   else begin
    if(toggle_pause&&running)paused<=~paused;
    case(state)
     IDLE:if(start)begin
      state<=CLEAR;session_active<=1;flush_active<=1;timer<=0;running<=0;paused<=0;error_code<=0;write_bank<=0;
      write_addr<=1536000;frame_number<=0;part_number<=0;next_pts<=0;
      total_frames<=0;half<=0;bad_header<=0;head_pos<=0;
     end
     CLEAR:if(timer==32767&&!client_busy&&writes_idle)begin state<=LOC;flush_active<=0;end
       else if(timer!=32767)timer<=timer+1'b1;
     LOC:begin loc_start<=1;state<=LOOK;end
     LOOK:if(loc_error)fail(loc_ec);else if(loc_done)state<=START;
     START:begin stream_start<=1;head_pos<=0;state<=HEADER;end
     HEADER:if(take)begin
      if(head_pos==16)total_frames[7:0]<=byte_data;
      else if(head_pos==17)total_frames[15:8]<=byte_data;
      else if(head_pos>=20&&head_pos<=23)begin
       case(head_pos)
        20:if(byte_data!=expected_samples[7:0])bad_header<=1;
        21:if(byte_data!=expected_samples[15:8])bad_header<=1;
        22:if(byte_data!=expected_samples[23:16])bad_header<=1;
        23:if(byte_data!={7'd0,expected_samples[24]})bad_header<=1;
       endcase
      end
      else if(byte_data!=header_expected(head_pos))bad_header<=1;
      if(file_last)fail(8'hb1);
      else if(head_pos==511)begin
       if(bad_header||total_frames==0||total_frames>6000)fail(8'hb0);
       else begin state<=PART;head_pos<=0;end
      end else head_pos<=head_pos+1'b1;
     end
     PART:if(take)begin
      // PTS in the packet is informational; scheduling derives from sample
      // count and frame sequence, not an untrusted wide multiply.
      if(head_pos<8)begin
       case(head_pos)
        0:if(byte_data!="A")bad_header<=1;
        1:if(byte_data!="V")bad_header<=1;
        2:if(byte_data!="1")bad_header<=1;
        3:if(byte_data!="0")bad_header<=1;
        4:if(byte_data!=frame_number[7:0])bad_header<=1;
        5:if(byte_data!=frame_number[15:8])bad_header<=1;
        6:if(byte_data!={4'd0,part_number})bad_header<=1;
        7:if(byte_data!=0)bad_header<=1;
       endcase
      end
      if(file_last)fail(8'hb1);
      else if(head_pos==511)begin
       if(bad_header)fail(8'hb2);
       else begin state<=AUDIO;audio_pos<=0;half<=0;end
      end else head_pos<=head_pos+1'b1;
     end
     AUDIO:if(take)begin
      if(audio_pos<960)begin half<=~half;if(!half)low_byte<=byte_data;end
      if(file_last)fail(8'hb1);
      else if(audio_pos==1023)begin state<=VIDEO;video_pos<=0;final_video_byte<=0;half<=0;end
      else audio_pos<=audio_pos+1'b1;
     end
     VIDEO:if(take)begin
      final_video_byte<=video_pos==15358;
      half<=~half;if(!half)low_byte<=byte_data;
      if(file_last!=(last_frame_q&&last_part_q&&final_video_byte))fail(8'hb1);
      else if(video_pos==15359)begin
       if(part_number==9)begin state<=RETIRE;timer<=0;end
       else begin part_number<=part_number+1'b1;state<=PART;head_pos<=0;end
      end else video_pos<=video_pos+1'b1;
     end
     RETIRE:if(writes_idle)begin
      if(timer==127)begin
       state<=WAIT_FRAME;
      end else timer<=timer+1'b1;
     end else timer<=0;
     WAIT_FRAME:if(offer&&frame_take)begin
      running<=1;next_pts<=next_pts+25'd4800;
      if(last_frame_q)state<=FINISH;
      else begin
       write_bank<=~write_bank;write_addr<=write_bank?21'd1536000:21'd1612800;
       frame_number<=frame_number+1'b1;part_number<=0;head_pos<=0;state<=PART;
      end
     end
     FINISH:if(played_samples>=next_pts)begin
      state<=STOP;flush_active<=1;timer<=0;running<=0;
      if(REPORT_EXIT_CODES)error_code<=8'he0;
     end
     STOP:if(timer==32767&&!client_busy&&writes_idle)begin state<=IDLE;session_active<=0;flush_active<=0;end
       else if(timer!=32767)timer<=timer+1'b1;
     default:begin state<=IDLE;session_active<=0;flush_active<=0;end
    endcase
   end
  end
 end
endmodule

