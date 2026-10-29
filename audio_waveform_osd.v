`timescale 1ns/1ps
// Actual HDMI PCM tap -> nonblocking async FIFO -> video-domain ring ->
// frozen VBlank snapshot -> double-buffered column ranges. No SDRAM traffic.
module audio_waveform_osd(
    input wire audio_clk,input wire audio_reset,
    input wire [15:0] played_sample,input wire [2:0] played_mode,
    input wire pixel_clk,input wire pixel_reset,
    input wire [9:0] pixel_x,pixel_y,
    input wire display_enable,input wire diagnostic,
    input wire [23:0] base_rgb,output wire [23:0] pixel_rgb
);
    wire bridge_reset=audio_reset||pixel_reset;
    wire bridge_full,bridge_empty,bridge_read;
    wire [18:0] bridge_data;
    reg overflow_audio,overflow_p1,overflow_p2;
    always @(posedge audio_clk or posedge bridge_reset)
        if(bridge_reset) overflow_audio<=0;
        else if(bridge_full) overflow_audio<=1;
    audio_async_fifo #(.DATA_WIDTH(19),.ADDR_WIDTH(6)) u_bridge(
        .rst(bridge_reset),.wr_clk(audio_clk),.wr_en(!bridge_full),
        .wr_data({played_mode,played_sample}),.full(bridge_full),
        .rd_clk(pixel_clk),.rd_en(bridge_read),.rd_data(bridge_data),.empty(bridge_empty));

    localparam DRAIN=0,LAST_READ=1,FREEZE=2,SEARCH_PRIME=3,
        SEARCH_READ=4,SEARCH_WAIT=5,COPY_PRIME=6,COPY_READ=7,
        COPY_WAIT=8,PCT_INIT=9,PCT_TENS=10;
    reg [3:0] state;
    reg bridge_pending;
    assign bridge_read=(state==DRAIN)&&!bridge_empty;
    reg [15:0] ring[0:1023];
    reg [9:0] ring_wr_ptr,ring_rd_addr,copy_base,search_base;
    reg [10:0] ring_count;
    reg [15:0] ring_q,previous_sample;
    reg [2:0] ring_mode,back_mode,display_mode;
    reg [6:0] search_index;
    reg [8:0] copy_index;
    reg [7:0] previous_y;
    reg [16:0] peak_candidate,back_peak;
    reg [6:0] percent_remaining;
    reg [11:0] back_peak_bcd,display_peak_bcd;
    reg front_bank,work_bank,back_ready,have_snapshot;
    reg [15:0] columns[0:1023];
    reg [15:0] column_q;
    // Compress the existing 512-sample snapshot into 176 display columns.
    // floor(j*512/176) = floor(j*32/11); no divider or new multiplier.
    reg [8:0] render_column;
    reg [3:0] render_phase;
    wire [8:0] prefetch_column=(pixel_x==447)?9'd0:render_column;
    // One-cycle BRAM look-ahead: x=447 fetches column zero for x=448.
    always @(posedge pixel_clk or posedge pixel_reset) begin
        if(pixel_reset) begin render_column<=0;render_phase<=0;end
        else if(pixel_x==447) begin render_column<=2;render_phase<=10;end
        else if(pixel_x>=448&&pixel_x<622) begin
            render_column<=render_column+((render_phase!=0)?9'd3:9'd2);
            render_phase<=(render_phase!=0)?render_phase-1'b1:4'd10;
        end
    end
    always @(posedge pixel_clk) begin
        ring_q<=ring[ring_rd_addr];
        column_q<=columns[{front_bank,prefetch_column}];
    end
    wire [16:0] sample_abs=ring_q[15]?({1'b0,~ring_q}+17'd1):{1'b0,ring_q};
    wire [16:0] peak_max=(sample_abs>peak_candidate)?sample_abs:peak_candidate;
    wire signed [8:0] vertical=9'sd22-$signed({{4{ring_q[15]}},ring_q[15:11]});
    wire [7:0] current_y=vertical[7:0];
    wire [7:0] column_low=(copy_index==0||current_y<previous_y)?current_y:previous_y;
    wire [7:0] column_high=(copy_index==0||current_y>previous_y)?current_y:previous_y;
    wire [23:0] peak100=({7'd0,back_peak}<<6)+({7'd0,back_peak}<<5)+({7'd0,back_peak}<<2);
    wire frame_end=(pixel_x==799)&&(pixel_y==524);
    wire snapshot_start=(pixel_x==0)&&(pixel_y==480);
    // One physical write port: select its address before the RAM assignment.
    // Two separate ring[0]/ring[wr_ptr] assignments can make TD infer thousands
    // of flip-flops instead of a BRAM, even when their conditions are exclusive.
    wire ring_store=!pixel_reset&&(state==DRAIN||state==LAST_READ)&&bridge_pending;
    wire [9:0] ring_write_addr=(bridge_data[18:16]!=ring_mode)?10'd0:ring_wr_ptr;
    always @(posedge pixel_clk)
        if(ring_store) ring[ring_write_addr]<=bridge_data[15:0];
    always @(posedge pixel_clk or posedge pixel_reset) begin
        if(pixel_reset) begin
            state<=DRAIN;bridge_pending<=0;ring_wr_ptr<=0;ring_rd_addr<=0;ring_count<=0;
            copy_base<=0;search_base<=0;ring_mode<=0;back_mode<=0;display_mode<=0;
            search_index<=0;copy_index<=0;previous_sample<=0;previous_y<=22;
            peak_candidate<=0;back_peak<=0;percent_remaining<=0;
            back_peak_bcd<=0;display_peak_bcd<=0;
            front_bank<=0;work_bank<=1;back_ready<=0;have_snapshot<=0;
            overflow_p1<=0;overflow_p2<=0;
        end else begin
            overflow_p1<=overflow_audio;overflow_p2<=overflow_p1;
            bridge_pending<=bridge_read;
            // LAST_READ consumes the final in-flight registered FIFO word
            // before FREEZE takes the write pointer. No multi-bit pointer CDC.
            if((state==DRAIN||state==LAST_READ)&&bridge_pending) begin
                if(bridge_data[18:16]!=ring_mode) begin
                    ring_mode<=bridge_data[18:16];
                    ring_wr_ptr<=1;ring_count<=1;
                end else begin
                    ring_wr_ptr<=ring_wr_ptr+1'b1;
                    if(ring_count<1024) ring_count<=ring_count+1'b1;
                end
            end
            case(state)
                DRAIN:if(snapshot_start&&!back_ready&&ring_count>=512) state<=LAST_READ;
                LAST_READ:state<=FREEZE;
                FREEZE:begin
                    if(ring_count<512) state<=DRAIN;
                    else begin
                        work_bank<=~front_bank;copy_base<=ring_wr_ptr-10'd512;
                        copy_index<=0;peak_candidate<=0;
                        if(ring_count>=608&&ring_mode>=1&&ring_mode<=3) begin
                            search_base<=ring_wr_ptr-10'd608;
                            ring_rd_addr<=ring_wr_ptr-10'd608;
                            search_index<=0;state<=SEARCH_PRIME;
                        end else begin ring_rd_addr<=ring_wr_ptr-10'd512;state<=COPY_PRIME;end
                    end
                end
                SEARCH_PRIME:state<=SEARCH_READ;
                SEARCH_WAIT:state<=SEARCH_READ;
                SEARCH_READ:begin
                    if(search_index!=0&&previous_sample[15]&&!ring_q[15]) begin
                        ring_rd_addr<=search_base+search_index;
                        copy_base<=search_base+search_index;state<=COPY_PRIME;
                    end else if(search_index==96) begin ring_rd_addr<=copy_base;state<=COPY_PRIME;end
                    else begin
                        previous_sample<=ring_q;search_index<=search_index+1'b1;
                        ring_rd_addr<=ring_rd_addr+1'b1;state<=SEARCH_WAIT;
                    end
                end
                COPY_PRIME:state<=COPY_READ;
                COPY_WAIT:state<=COPY_READ;
                COPY_READ:begin
                    columns[{work_bank,copy_index}]<={column_high,column_low};
                    previous_y<=current_y;peak_candidate<=peak_max;
                    if(copy_index==511) begin
                        back_peak<=peak_max;back_mode<=ring_mode;state<=PCT_INIT;
                    end else begin
                        copy_index<=copy_index+1'b1;ring_rd_addr<=ring_rd_addr+1'b1;state<=COPY_WAIT;
                    end
                end
                PCT_INIT:begin
                    back_peak_bcd<=0;
                    if(peak100[21:15]==100) begin back_peak_bcd[11:8]<=1;percent_remaining<=0;end
                    else percent_remaining<=peak100[21:15];
                    state<=PCT_TENS;
                end
                PCT_TENS:begin
                    if(percent_remaining>=10) begin
                        percent_remaining<=percent_remaining-7'd10;
                        back_peak_bcd[7:4]<=back_peak_bcd[7:4]+1'b1;
                    end else begin
                        back_peak_bcd[3:0]<=percent_remaining[3:0];back_ready<=1;state<=DRAIN;
                    end
                end
                default:state<=DRAIN;
            endcase
            // Publish both the waveform bank AND its metadata at frame end.
            if(frame_end) begin
                if(back_ready&&back_mode==ring_mode) begin
                    front_bank<=work_bank;display_mode<=back_mode;
                    display_peak_bcd<=back_peak_bcd;have_snapshot<=1;
                end else if(ring_count<512||display_mode!=ring_mode) begin
                    have_snapshot<=0;display_peak_bcd<=0;
                end
                back_ready<=0;
            end
        end
    end

    // Upper-right compact panel, below SRC and the temporary E4 controls.
    // Text and plot are 176 pixels wide, matching the source-size OSD.
    wire in_panel=display_enable&&(pixel_x>=444)&&(pixel_x<628)&&
                  (pixel_y>=88)&&(pixel_y<156);
    wire in_wave=display_enable&&(pixel_x>=448)&&(pixel_x<624)&&
                 (pixel_y>=104)&&(pixel_y<148);
    wire in_header=display_enable&&(pixel_x>=448)&&(pixel_x<624)&&
                   (pixel_y>=92)&&(pixel_y<100);
    wire border_pixel=in_panel&&((pixel_x==444)||(pixel_x==627)||
                                 (pixel_y==88)||(pixel_y==155));
    wire [7:0] local_y=pixel_y-10'd104;
    wire wave_pixel=in_wave&&have_snapshot&&local_y>=column_q[7:0]&&local_y<=column_q[15:8];
    wire zero_pixel=in_wave&&(pixel_y==126);
    wire grid_pixel=in_wave&&(pixel_x[4:0]==0);
    wire [4:0] character=(pixel_x-10'd448)>>3;
    reg [7:0] glyph;
    always @(*) begin
        glyph=8'd32;
        case(character)
            0: glyph=!have_snapshot?"W":(display_mode==0)?"M":(display_mode==1)?"5":
                     (display_mode==2)?"1":(display_mode==3)?"2":"M";
            1: glyph=!have_snapshot?"A":(display_mode==0||display_mode==4)?"U":
                     (display_mode==1)?"0":"k";
            2: glyph=!have_snapshot?"I":(display_mode==0)?"S":(display_mode==4)?"T":
                     (display_mode==1)?"0":"H";
            3: glyph=!have_snapshot?"T":(display_mode==0)?"I":(display_mode==4)?"E":
                     (display_mode==1)?"H":"z";
            4: glyph=!have_snapshot?" ":(display_mode==0)?"C":(display_mode==1)?"z":" ";
            6:glyph="P";7:glyph="K";8:glyph=":";
            9:glyph=8'd48+{4'd0,display_peak_bcd[11:8]};
            10:glyph=8'd48+{4'd0,display_peak_bcd[7:4]};
            11:glyph=8'd48+{4'd0,display_peak_bcd[3:0]};12:glyph="%";
            14:glyph="F";15:glyph="S";16:glyph=":";17:glyph="4";18:glyph="8";19:glyph="k";
            20:glyph=overflow_p2?"O":" ";21:glyph=overflow_p2?"V":" ";
            default:glyph=" ";
        endcase
    end
    wire [7:0] font_row;
    wire [9:0] header_y=pixel_y-10'd92;
    audio_wave_font u_font(.glyph(glyph),.row(header_y[2:0]),.bits(font_row));
    wire header_pixel=in_header&&font_row[3'd7-pixel_x[2:0]];
    wire [23:0] dark={1'b0,base_rgb[23:17],1'b0,base_rgb[15:9],1'b0,base_rgb[7:1]};
    assign pixel_rgb=diagnostic?base_rgb:header_pixel?24'h80e0ff:
                     wave_pixel?24'h40ffb0:zero_pixel?24'h708090:
                     grid_pixel?24'h283844:border_pixel?24'h405060:in_panel?dark:base_rgb;
endmodule
