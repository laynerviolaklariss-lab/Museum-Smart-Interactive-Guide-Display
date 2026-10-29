`timescale 1ns/1ps
`include "tf_bmp_defs.vh"

// B1..B4/E1..E5/LCD plus restoration comparison (fade32 retained):
// TF/FAT32 -> BMP24 -> SDRAM write/verify -> scan-line buffer -> HDMI,
// with manual prev/next keys and automatic slideshow.  The OSD path also
// contains the FPGA-generated Anlogic logo; all layers share the same fade.
//
// 播放控制状态（play_state）：
//   SHOW       显示当前帧 load_index；自动轮播计时只在此状态进行
//   LOAD       锁存目标帧 want_index（四帧常驻 SDRAM，故为瞬时；
//              新组装入非活动对照缓存；两图缩放/校验通过后才继续）
//   READY      目标就绪，进入32级淡出
//   FADE_OUT   每帧递减一级，直到全黑
//   SWAP       在黑场帧边界提交 load_index<=want_index
//   FADE_IN    每帧递增一级，恢复满亮后回 SHOW
// 主状态机 top_state 的加载阶段对应 BOOT，T_ERROR 对应 ERROR。
module TfBmpImg0001Top(
    input wire clk_50m,input wire sw0_run,
    input wire sw1_next,input wire sw2_prev,input wire sw3_mode,
    input wire sw4_brightness,input wire sw5_contrast,input wire sw6_default,
    input wire sw7_audio,
    input wire [3:0] key_col,inout wire [3:0] key_row,
    input wire sd_miso,output wire sd_cs_n,output wire sd_mosi,output wire sd_sck,
    output wire HDMI_CLK_P,output wire HDMI_D0_P,
    output wire HDMI_D1_P,output wire HDMI_D2_P,
    output wire [7:0] led,
    output wire lcd_cs_n,lcd_rst_n,lcd_dc,lcd_mosi,lcd_sck,lcd_bl,
    inout wire ctp_scl,ctp_sda,input wire ctp_int_n,output wire ctp_reset_n
);
    // Actual PLL core clock: 1 GHz / 12. HDMI and LCD clocks are independent.
    localparam integer CORE_CLK_HZ=83333333;
    localparam T_WAIT_CARD=0,T_LOC_START=1,T_LOC_WAIT=2,T_LOAD_START=3,
        T_LOAD=4,T_TURN=5,T_VERIFY_START=6,T_VERIFY=7,T_DONE=8,T_ERROR=9,
        T_MUSIC_LOC_START=10,T_MUSIC_LOC_WAIT=11,T_MUSIC_STREAM_START=12;
    reg [3:0] top_state; reg [6:0] turn_count; reg [7:0] top_error;
    reg [3:0] image_index; reg [2:0] write_slot; reg [20:0] frame_base;
    reg loc_start,stream_start,bmp_start,verify_start,stream_abort,music_mode;
    reg [27:0] blink;
    reg display_started,runtime_load,load_bank,load_failed;
    reg [2:0] loading_group,cache_group0,cache_group1;
    reg cache_valid0,cache_valid1;
    reg [9:0] pair_width0,pair_height0,pair_width1,pair_height1;
    reg compare_requested;reg [9:0] split_requested;
    reg scan_compare;reg [9:0] scan_split;
    reg [2:0] scan_before_slot,scan_after_slot;
    wire key_right,key_left,key_compare,key_brightness_down,key_contrast_down,touch_slider_valid;
    wire key_zoom_tl,key_zoom_tr,key_zoom_bl,key_zoom_br;
    wire key_zoom_in,key_zoom_out,key_zoom_home,key_zoom_page,key_zoom_center,key_zoom_enter;
    wire [9:0] zoom_focus_x,zoom_focus_y;
    wire touch_locate_valid;wire [9:0] touch_locate_x,touch_locate_y;
    wire [3:0] touch_zoom_command;wire touch_zoom_valid;
    reg zoom_page;
    reg vblank_pulse;
    reg [2:0] load_index; // current displayed group, declared before zoom use
    wire region_zoom_active;wire [9:0] region_zoom_lx,region_zoom_ly;wire [12:0] region_zoom_k;
    wire [1:0] region_zoom_pos;wire [2:0] region_zoom_level;
    wire region_aim_mode,region_zoom_mode;wire [9:0] region_aim_w,region_aim_h;
    wire [40:0] aim_packet_pixel;
    wire [9:0] touch_slider_position;
    wire audio_pcm_low;
    localparam M_IDLE=0,M_VIDEO=1,M_WRITE=2,M_VERIFY=3,M_TURN=4,M_MEDIA=5;
    wire kp_next,kp_prev,kp_mode,kp_next_button,kp_prev_button,kp_mode_button;
    wire touch_event_valid,touch_present,touch_fault;
    wire [3:0] touch_event_code;
    localparam P_SHOW=3'd0,P_LOAD=3'd1,P_READY=3'd2,
               P_FADE_OUT=3'd3,P_SWAP=3'd4,P_FADE_IN=3'd5;
    reg [2:0] play_state;
    wire key_video,key_video_exit,video_session,video_flush,video_loc_start,video_stream_start;
    wire video_pixel_valid,video_pixel_ready,video_pcm_valid,video_byte_ready;
    wire [31:0] video_pixel_data,video_samples;wire [24:0] video_sample_limit;wire [15:0] video_pcm_sample;
    wire video_offer,video_take,video_running,video_paused;
    // One shared player; freeze the selected file for the whole session.
    // Reserved locator indices 14/15 name GUIDE000/001 respectively.
    reg video_cover;
    wire video_start=key_video&&!video_session&&(load_index<2)&&
                     top_state==T_DONE&&play_state==P_SHOW&&!compare_requested;
    wire [3:0] video_file_index={3'b111,!video_cover};
    always @(posedge clk100 or posedge rst)
        if(rst)video_cover<=0;
        else if(video_start)video_cover<=load_index==0;
    wire line_last_response;
    wire video_buffering,video_buffer_ready;
    wire video_audio_run=video_running&&!video_buffering;
    wire [20:0] video_base,video_write_addr;
    wire [15:0] video_frame_number,video_total_frames;wire [7:0] video_error;
    // Reuse the player's existing sticky byte; no diagnostic payload or CDC.
    wire [7:0] video_stop_code=key_video_exit?8'he1:kp_next_button?8'he2:kp_prev_button?8'he3:
        (touch_event_valid&&touch_event_code<=1)?8'he4:
        (touch_zoom_valid&&touch_zoom_command==1)?8'he5:
        (touch_zoom_valid&&touch_zoom_command==4)?8'he6:8'd0;
    wire vfifo_full,vfifo_empty;wire [31:0] vfifo_data;wire video_write_fire;
    reg audio_fault_s1,audio_fault_s2;
    always @(posedge clk100 or posedge rst)
        if(rst)begin audio_fault_s1<=0;audio_fault_s2<=0;end
        else if(video_flush)begin audio_fault_s1<=0;audio_fault_s2<=0;end
        else begin audio_fault_s1<=audio_underflow;audio_fault_s2<=audio_fault_s1;end
    reg scan_video;reg [20:0] video_front_base;reg video_previous;reg [1:0] video_nav;
    always @(posedge clk100 or posedge rst)
        if(rst)begin video_previous<=0;video_nav<=0;end
        else begin
            video_previous<=video_session;
            if(video_session)begin
                if(kp_next_button||(touch_event_valid&&touch_event_code==0))video_nav<=1;
                else if(kp_prev_button||(touch_event_valid&&touch_event_code==1))video_nav<=2;
            end else if(video_previous)video_nav<=0;
        end
    reg [2:0] mem_owner;reg [9:0] mem_sent,mem_returned;reg [6:0] mem_guard;
    // Transaction ownership outlives the final line response: scan_video can
    // change at that response. Keep the read length until the grant retires.
    reg mem_line_video;


    wire sdram_pll_locked,clk25_unused,clk100,clk100_180;
    wire rst=!sw0_run||!sdram_pll_locked;
    museum_key_matrix #(.CLK_HZ(CORE_CLK_HZ)) u_matrix(.clk(clk100),.reset(rst),.cols(key_col),.rows(key_row),
        .right_event(key_right),.left_event(key_left),.toggle_event(key_compare),
        .brightness_down_event(key_brightness_down),.contrast_down_event(key_contrast_down),
        .zoom_tl_event(key_zoom_tl),.zoom_tr_event(key_zoom_tr),
        .zoom_bl_event(key_zoom_bl),.zoom_br_event(key_zoom_br),
        .zoom_in_event(key_zoom_in),.zoom_out_event(key_zoom_out),.zoom_home_event(key_zoom_home),
        .zoom_page_event(key_zoom_page),.zoom_center_event(key_zoom_center),.zoom_enter_event(key_zoom_enter),
        .video_event(key_video),.video_exit_event(key_video_exit));
    // Arbitrary focus; cover commands are ignored. Compare has priority.
    always @(posedge clk100 or posedge rst)
        if(rst)zoom_page<=0;
        else if(key_zoom_page||(touch_zoom_valid&&touch_zoom_command==4))zoom_page<=~zoom_page;
    museum_region_zoom u_region_zoom(.clk(clk100),.reset(rst),
        .vblank(vblank_pulse),
        .zoom_tl(key_zoom_tl),.zoom_tr(key_zoom_tr),
        .zoom_bl(key_zoom_bl),.zoom_br(key_zoom_br),
        .compare_mode(compare_requested||video_session),.cover_page(load_index==0),
        .zoom_enter(key_zoom_enter),.zoom_cycle(key_zoom_in),
        .zoom_in(touch_zoom_valid&&touch_zoom_command==0),
        .zoom_out(key_zoom_out||(touch_zoom_valid&&touch_zoom_command==1)),
        .zoom_home(key_zoom_home||(touch_zoom_valid&&touch_zoom_command==2)),
        .zoom_center(key_zoom_center||(touch_zoom_valid&&touch_zoom_command==3)),
        .locate_valid(touch_locate_valid),.locate_x(touch_locate_x),.locate_y(touch_locate_y),
        .focus_x(zoom_focus_x),.focus_y(zoom_focus_y),
        .pos(region_zoom_pos),.level(region_zoom_level),
        .win_x(region_zoom_lx),.win_y(region_zoom_ly),.scale(region_zoom_k),
        .active(region_zoom_active),.aim_mode(region_aim_mode),.zoom_mode(region_zoom_mode),
        .aim_w(region_aim_w),.aim_h(region_aim_h));
    clk_pll u_pll(.refclk(clk_50m),.reset(!sw0_run),.extlock(sdram_pll_locked),
        .clk0_out(clk25_unused),.clk1_out(clk100),.clk2_out(clk100_180));

    // Image and music keep independent FAT cursors. Tagged sector arbitration.
    wire host_ready,host_sdhc,host_busy,host_dv,host_done,host_error;
    wire [8:0] host_di; wire [7:0] host_db,host_ec,host_r1;
    wire host_req; wire [31:0] host_lba;
    sd_spi_host u_sd(.clk(clk100),.rst(rst),.rd_req(host_req),.rd_lba(host_lba),
        .card_ready(host_ready),.card_sdhc(host_sdhc),.rd_busy(host_busy),
        .data_valid(host_dv),.data_index(host_di),.data_byte(host_db),
        .sector_done(host_done),.error(host_error),.error_code(host_ec),.last_r1(host_r1),
        .sd_cs_n(sd_cs_n),.sd_sck(sd_sck),.sd_mosi(sd_mosi),.sd_miso(sd_miso));
    wire loc_req,loc_busy,loc_done,loc_error,loc_selected,img_selected,music_selected,client_busy;
    wire [31:0] loc_lba,fat_lba,data_lba,max_cluster,first_cluster,file_size;
    wire [7:0] spc,loc_ec;
    fat32_file_locator u_locator(.clk(clk100),.rst(rst||(top_state==T_ERROR)||video_flush),.start(loc_start||video_loc_start),
        .target_music(music_mode||video_session),.target_index(video_session?video_file_index:image_index),
        .sec_req(loc_req),.sec_lba(loc_lba),.sec_busy(client_busy),
        .sec_data_valid(host_dv&&loc_selected),.sec_data_index(host_di),
        .sec_data_byte(host_db),.sec_done(host_done&&loc_selected),
        .sec_error(host_error&&loc_selected),.busy(loc_busy),.done(loc_done),
        .error(loc_error),.error_code(loc_ec),.fat_start_lba(fat_lba),
        .data_start_lba(data_lba),.sectors_per_cluster(spc),.max_cluster(max_cluster),
        .file_first_cluster(first_cluster),.file_size(file_size));
    wire stream_req,stream_busy,stream_done,stream_error,stream_bv,stream_last;
    wire [31:0] stream_lba,stream_off;wire [7:0] stream_byte,stream_ec;
    wire bmp_byte_ready,audio_pcm_ready;
    fat32_file_stream #(.USE_BRAM(1)) u_stream(.clk(clk100),.rst(rst),.start(stream_start),.abort(stream_abort),
        .fat_start_lba(fat_lba),.data_start_lba(data_lba),.sectors_per_cluster(spc),
        .max_cluster(max_cluster),.first_cluster(first_cluster),.file_size(file_size),
        .sec_req(stream_req),.sec_lba(stream_lba),.sec_busy(client_busy),
        .sec_data_valid(host_dv&&img_selected),.sec_data_index(host_di),
        .sec_data_byte(host_db),.sec_done(host_done&&img_selected),
        .sec_error(host_error&&img_selected),.byte_valid(stream_bv),
        .byte_ready(bmp_byte_ready),.byte_data(stream_byte),.file_offset(stream_off),
        .file_last(stream_last),.busy(stream_busy),.done(stream_done),
        .error(stream_error),.error_code(stream_ec));
    reg [31:0] music_fat,music_data,music_max,music_cluster,music_size;
    reg [7:0] music_spc;reg music_start,music_enabled;
    wire m_req,m_done,m_error,m_bv,video_file_last;wire [31:0] m_lba;wire [7:0] m_byte,m_ec;
    reg music_byte_half;reg [7:0] music_low_byte;
    wire music_byte_ready=video_session?video_byte_ready:(!music_byte_half||audio_pcm_ready);
    wire audio_pcm_valid=video_session?video_pcm_valid:music_enabled&&m_bv&&music_byte_half;
    wire [15:0] audio_pcm_sample=video_session?video_pcm_sample:{m_byte,music_low_byte};
    fat32_file_stream #(.USE_BRAM(1)) u_music(.clk(clk100),.rst(rst),.start((music_start&&!video_session)||video_stream_start),.abort(video_flush),
        .fat_start_lba(video_session?fat_lba:music_fat),.data_start_lba(video_session?data_lba:music_data),
        .sectors_per_cluster(video_session?spc:music_spc),.max_cluster(video_session?max_cluster:music_max),
        .first_cluster(video_session?first_cluster:music_cluster),.file_size(video_session?file_size:music_size),
        .sec_req(m_req),.sec_lba(m_lba),.sec_busy(client_busy),
        .sec_data_valid(host_dv&&music_selected),.sec_data_index(host_di),
        .sec_data_byte(host_db),.sec_done(host_done&&music_selected),
        .sec_error(host_error&&music_selected),.byte_valid(m_bv),
        .byte_ready(music_byte_ready),.byte_data(m_byte),.file_offset(),
        .file_last(video_file_last),.busy(),.done(m_done),.error(m_error),.error_code(m_ec));
    museum_sector_arbiter u_sector(.clk(clk100),.reset(rst),.music_low(audio_pcm_low),
        .loc_req(loc_req),.img_req(stream_req),.music_req(m_req),
        .loc_lba(loc_lba),.img_lba(stream_lba),.music_lba(m_lba),
        .client_busy(client_busy),.host_req(host_req),.host_lba(host_lba),
        .host_busy(host_busy),.host_done(host_done),.host_error(host_error),
        .loc_selected(loc_selected),.img_selected(img_selected),.music_selected(music_selected));
    always @(posedge clk100 or posedge rst)begin
        if(rst||video_flush)begin music_byte_half<=0;music_low_byte<=0;end
        else if(!video_session&&m_bv&&music_byte_ready)begin
            if(!music_byte_half)begin music_low_byte<=m_byte;music_byte_half<=1;end
            else music_byte_half<=0;
        end
    end

    // BMP parser and block-RAM write staging FIFO.
    wire pixel_valid,parser_done,parser_busy,parser_error,line_start,line_end,metadata_valid;
    wire [31:0] pixel_rgb,pixel_x,pixel_y,img_w,img_h,pix_off,pix_count;
    wire [7:0] parser_ec; wire image_top_down;
    wire init_done,init_ref_vld,sdr_busy;
    reg format_checked,format_ok_latched,parser_finished;
    reg [31:0] write_count;
    wire fifo_full,fifo_empty; wire [31:0] fifo_dout;
    reg block_draining;
    wire scaled_valid,scaled_ready,scale_done,scale_error;
    wire [31:0] scaled_rgb;
    wire [18:0] scaled_count;
    wire [7:0] scale_ec;
    wire pixel_ready;
    assign scaled_ready=format_ok_latched&&!fifo_full&&!block_draining;
    wire fifo_wr_en=scaled_valid&&scaled_ready;
    wire write_fire=block_draining&&!fifo_empty&&(top_state==T_LOAD)&&
                    init_done&&!init_ref_vld&&(mem_owner==M_WRITE);
    pixel_fifo #(.DATA_WIDTH(32),.ADDR_BITS(9)) u_pfifo(
        .clk(clk100),.rst(rst||(top_state==T_LOAD_START)||(video_flush&&mem_owner!=M_MEDIA)),
        .wr_en(video_session?(video_pixel_valid&&video_pixel_ready):fifo_wr_en),
        .wr_data(video_session?video_pixel_data:scaled_rgb),
        .rd_en(write_fire||video_write_fire),.rd_data(fifo_dout),.empty(fifo_empty),.full(fifo_full));
    bmp24_parser #(.MAX_IMAGE_DIM(800)) u_bmp(.clk(clk100),.rst(rst),.start(bmp_start),.file_size(file_size),
        .slot_capacity_pixels(480000),.byte_valid(stream_bv),.byte_ready(bmp_byte_ready),
        .byte_data(stream_byte),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_rgb(pixel_rgb),.pixel_x(pixel_x),.pixel_y(pixel_y),
        .line_start(line_start),.line_end(line_end),.frame_done(parser_done),
        .busy(parser_busy),.error(parser_error),.error_code(parser_ec),
        .metadata_valid(metadata_valid),.image_width(img_w),.image_height(img_h),
        .image_top_down(image_top_down),.pixel_offset(pix_off),.pixel_count(pix_count));

    bmp_stream_scaler u_scaler(.clk(clk100),.rst(rst),.start(bmp_start),
        .metadata_valid(metadata_valid&&format_ok_latched),
        .src_width(img_w),.src_height(img_h),.src_top_down(image_top_down),
        .in_valid(pixel_valid),.in_ready(pixel_ready),.in_rgb(pixel_rgb),
        .line_start(line_start),.line_end(line_end),
        .out_valid(scaled_valid),.out_ready(scaled_ready),.out_rgb(scaled_rgb),
        .out_count(scaled_count),.done(scale_done),.error(scale_error),.error_code(scale_ec));

    reg [31:0] write_sum,write_xor,exp_tl,exp_tr,exp_bl,exp_br;
    reg [20:0] write_addr; reg [4:0] frame_top_down;
    // Source resolution is captured from each accepted BMP header. Convert
    // once in the core clock domain, never divide in the 25 MHz OSD pixel path.
    reg [11:0] frame_width_bcd[0:4],frame_height_bcd[0:4];
    reg [9:0] resolution_w_rem,resolution_h_rem;
    reg [2:0] resolution_index;
    reg resolution_busy,resolution_tens;
    reg resolution_capture,resolution_commit;reg [9:0] resolution_cw,resolution_ch;
    reg [2:0] resolution_ci;reg [11:0] resolution_w_bcd,resolution_h_bcd;
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin resolution_capture<=0;resolution_cw<=0;resolution_ch<=0;resolution_ci<=0;end
        else begin
            resolution_capture<=(top_state==T_LOAD)&&metadata_valid&&!format_checked&&!bmp_start&&
                img_w!=0&&img_h!=0&&img_w<=800&&img_h<=800;
            resolution_cw<=img_w[9:0];resolution_ch<=img_h[9:0];resolution_ci<=write_slot;
        end
    end
    integer resolution_reset_index;
    wire [23:0] source_resolution_bcd={frame_width_bcd[scan_after_slot],frame_height_bcd[scan_after_slot]};
    // Commit enable is registered independently of arithmetic/validation.
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin
            for(resolution_reset_index=0;resolution_reset_index<5;resolution_reset_index=resolution_reset_index+1)begin
                frame_width_bcd[resolution_reset_index]<=0;frame_height_bcd[resolution_reset_index]<=0;
            end
        end else if(resolution_commit)begin
            frame_width_bcd[resolution_index]<=resolution_w_bcd;
            frame_height_bcd[resolution_index]<=resolution_h_bcd;
        end
    end
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin
            resolution_w_rem<=0;resolution_h_rem<=0;resolution_index<=0;
            resolution_busy<=0;resolution_tens<=0;resolution_w_bcd<=0;resolution_h_bcd<=0;resolution_commit<=0;
        end else begin
            resolution_commit<=0;
            if(resolution_capture)begin
                resolution_index<=resolution_ci;resolution_w_rem<=resolution_cw;resolution_h_rem<=resolution_ch;
                resolution_w_bcd<=0;resolution_h_bcd<=0;resolution_busy<=1;resolution_tens<=0;
            end else if(resolution_busy)begin
                if(!resolution_tens)begin
                    if(resolution_w_rem>=100)begin resolution_w_rem<=resolution_w_rem-10'd100;resolution_w_bcd[11:8]<=resolution_w_bcd[11:8]+1'b1;end
                    if(resolution_h_rem>=100)begin resolution_h_rem<=resolution_h_rem-10'd100;resolution_h_bcd[11:8]<=resolution_h_bcd[11:8]+1'b1;end
                    if(resolution_w_rem<100&&resolution_h_rem<100)resolution_tens<=1;
                end else begin
                    if(resolution_w_rem>=10)begin resolution_w_rem<=resolution_w_rem-10'd10;resolution_w_bcd[7:4]<=resolution_w_bcd[7:4]+1'b1;end
                    if(resolution_h_rem>=10)begin resolution_h_rem<=resolution_h_rem-10'd10;resolution_h_bcd[7:4]<=resolution_h_bcd[7:4]+1'b1;end
                    if(resolution_w_rem<10&&resolution_h_rem<10)begin
                        resolution_w_bcd[3:0]<=resolution_w_rem[3:0];resolution_h_bcd[3:0]<=resolution_h_rem[3:0];
                        resolution_busy<=0;resolution_commit<=1;
                    end
                end
            end
        end
    end
    wire app_wr_en=write_fire||video_write_fire;
    wire [20:0] app_wr_addr=(mem_owner==M_MEDIA)?video_write_addr:write_addr;
    wire [3:0] app_wr_dm=4'b0000;wire [31:0] app_wr_data=fifo_dout;
    assign video_pixel_ready=!vfifo_full&&!video_flush&&(mem_owner!=M_MEDIA);
    // Sdr_busy is not an application ready signal. Match the accepted
    // photo path: drain complete 512-word blocks, pausing only for refresh.
    assign video_write_fire=(mem_owner==M_MEDIA)&&!vfifo_empty&&(mem_sent<512)&&init_done&&!init_ref_vld;
    // Photo loading and video playback are mutually exclusive; retain one
    // proven 512-word staging FIFO rather than duplicating its RAM/control.
    assign vfifo_full=fifo_full;assign vfifo_empty=fifo_empty;assign vfifo_data=fifo_dout;
    museum_video_player #(.REPORT_EXIT_CODES(1),.RECOVER_UNDERRUN(1)) u_media(.clk(clk100),.reset(rst),
        .start(video_start),
        .toggle_pause(key_video||(touch_zoom_valid&&touch_zoom_command==0)),
        .stop(key_video_exit||kp_next_button||kp_prev_button||
              (touch_event_valid&&touch_event_code<=1)||(touch_zoom_valid&&(touch_zoom_command==1||touch_zoom_command==4))),
        .starved(audio_fault_s2),.client_busy(client_busy),.session(video_session),.flush(video_flush),
        .loc_start(video_loc_start),.stream_start(video_stream_start),.loc_done(loc_done),.loc_error(loc_error),.loc_ec(loc_ec),
        .byte_valid(m_bv),.byte_data(m_byte),.file_last(video_file_last),.byte_ready(video_byte_ready),
        .stream_error(m_error),.stream_ec(m_ec),.pixel_valid(video_pixel_valid),.pixel_data(video_pixel_data),
        .pixel_ready(video_pixel_ready),.writes_idle(vfifo_empty&&mem_owner!=M_MEDIA),
        .write_fire(video_write_fire),.write_addr(video_write_addr),
        .pcm_valid(video_pcm_valid),.pcm_sample(video_pcm_sample),.pcm_ready(audio_pcm_ready),
        .played_samples(video_samples),.offer(video_offer),.frame_take(video_take),.offered_base(video_base),
        .running(video_running),.paused(video_paused),.sample_limit(video_sample_limit),.error_code(video_error),
        .frame_number(video_frame_number),.total_frames(video_total_frames),.stop_code(video_stop_code),
        .buffer_ready(video_buffer_ready),.buffering(video_buffering));
    assign video_take=video_offer&&line_wr_en&&line_last_response&&next_line==479;

    // Cold boot and runtime frame checks share the proven checksum verifier;
    // only tagged 512-word verify transactions enter it.
    wire verify_rd_en; wire [20:0] verify_rd_addr;
    wire verify_busy,verify_done,verify_pass,verify_protocol;
    wire [7:0] verify_failure_code;
    wire sdr_rd_en; wire [31:0] sdr_rd_data;
    sdram_frame_verify u_verify(.clk(clk100),.rst(rst),.start(verify_start),
        .base_addr(frame_base),.init_done(init_done),
        .init_ref_vld(init_ref_vld||(mem_owner!=M_VERIFY)||(mem_sent==512)),
        .total_words(307200),.image_width(640),.expected_sum(write_sum),
        .expected_xor(write_xor),.exp_tl(exp_tl),.exp_tr(exp_tr),
        .exp_bl(exp_bl),.exp_br(exp_br),.app_rd_en(verify_rd_en),
        .app_rd_addr(verify_rd_addr),.sdr_rd_en(sdr_rd_en&&(mem_owner==M_VERIFY)),
        .sdr_rd_data(sdr_rd_data),.busy(verify_busy),.done(verify_done),
        .pass(verify_pass),.protocol_error(verify_protocol),
        .failure_code(verify_failure_code));

    // ------------------------------------------------------------------
    // Step 3 keys: SW1 next, SW2 prev (long-press repeat), SW3 auto/manual.
    // ------------------------------------------------------------------



    assign kp_next=(!video_session&&(kp_next_button||(touch_event_valid&&touch_event_code==0)))||(video_previous&&!video_session&&video_nav==1);
    assign kp_prev=(!video_session&&(kp_prev_button||(touch_event_valid&&touch_event_code==1)))||(video_previous&&!video_session&&video_nav==2);
    assign kp_mode=kp_mode_button||(touch_event_valid&&touch_event_code==2);
    key_input #(.CLK_HZ(CORE_CLK_HZ),.REPEAT_EN(1)) u_key_next(
        .clk(clk100),.rst(rst),.raw(sw1_next),.pressed(kp_next_button),.level());
    key_input #(.CLK_HZ(CORE_CLK_HZ),.REPEAT_EN(1)) u_key_prev(
        .clk(clk100),.rst(rst),.raw(sw2_prev),.pressed(kp_prev_button),.level());
    key_input #(.CLK_HZ(CORE_CLK_HZ),.REPEAT_EN(0)) u_key_mode(
        .clk(clk100),.rst(rst),.raw(sw3_mode),.pressed(kp_mode_button),.level());

    // ------------------------------------------------------------------
    // Step 2/3 scan-line loader with frame index.
    // SDRAM line y of frame load_index is written into bank y[0]; HDMI
    // returns a consumed toggle before that bank is replaced.  At the frame
    // boundary (line 479 done, aligned with HDMI vertical blanking) the
    // loader commits want_index and restarts at the new frame top.
    // ------------------------------------------------------------------
    reg loader_active,loader_initialized,frame_ready;
    reg [9:0] line_issue_count,line_response_count,next_line;
    reg [20:0] line_base,line_issue_addr;
    reg [1:0] line_ready_toggle,line_busy,initial_loaded;
    reg [23:0] line_zoom0,line_zoom1;
    reg scan_zoom_active;reg [9:0] scan_zoom_lx;reg [12:0] scan_zoom_k;
    reg [1:0] consumed_meta,consumed_sync,consumed_seen;
    wire [1:0] line_consumed_toggle;
    assign line_last_response=scan_video?(line_response_count==319):(line_response_count==639);
    wire line_last_request=mem_line_video?(line_issue_count==319):(line_issue_count==639);
    wire line_requests_left=mem_line_video?(line_issue_count<320):(line_issue_count<640);
    wire grant_requests_left=mem_line_video?(mem_sent<320):(mem_sent<640);
    wire line_grant_done=mem_line_video?((mem_sent==320)&&(mem_returned==320)):
                                           ((mem_sent==640)&&(mem_returned==640));
    wire line_issue=display_started&&loader_active&&(mem_owner==M_VIDEO)&&init_done&&
                    !init_ref_vld&&line_requests_left&&grant_requests_left;
    wire app_rd_en=line_issue||verify_rd_en;
    wire [20:0] app_rd_addr=(mem_owner==M_VIDEO)?line_issue_addr:verify_rd_addr;
    wire line_wr_en=display_started&&loader_active&&sdr_rd_en&&(mem_owner==M_VIDEO);
    wire line_wr_bank=next_line[0];
    wire line_rd_clk,line_rd_bank; wire [9:0] line_rd_addr;
    wire [31:0] line_rd_data;
    wire video_underflow,video_locked,audio_active,audio_underflow;
    wire menu_pixel_valid;wire [3:0] menu_pixel_code;
    wire [56:0] lcd_status_pixel,lcd_status_sys;
    // Coalesce only faster-than-service repeats of the same command.
    // Different touch/key requests are retained until the CDC accepts them.
    reg [6:0] menu_pending;reg [3:0] menu_source_code;
    wire menu_source_ready;
    wire [6:0] menu_touch_new=(touch_event_valid&&touch_event_code>=3&&touch_event_code<=9)
        ?(7'b1<<(touch_event_code-3)):7'd0;
    wire [6:0] menu_new=menu_touch_new|{key_contrast_down,key_brightness_down,5'd0};
    always @(*)begin
        menu_source_code=3;
        if(menu_pending[3])menu_source_code=6;
        else if(menu_pending[0])menu_source_code=3;
        else if(menu_pending[1])menu_source_code=4;
        else if(menu_pending[2])menu_source_code=5;
        else if(menu_pending[4])menu_source_code=7;
        else if(menu_pending[5])menu_source_code=8;
        else if(menu_pending[6])menu_source_code=9;
    end
    always @(posedge clk100 or posedge rst)
        if(rst)menu_pending<=0;
        else menu_pending<=((menu_source_ready&&|menu_pending)
            ?(menu_pending&~(7'b1<<(menu_source_code-3))):menu_pending)|menu_new;
    wire lcd_status_strobe,lcd_status_valid;
    wire lcd_cdc_reset=rst||!video_locked;

    // ---- Step 3/E2 playback and fade control registers ----


    // load_index is declared before the zoom instance.
    reg [2:0] want_index;     // requested target frame
    reg       auto_mode;      // 1=automatic slideshow
    reg [28:0] auto_timer;
    reg [5:0] fade_level;     // 0=black, 32=full scale
    // vblank_pulse declared before the zoom instance to avoid implicit nets.
    localparam [28:0] AUTO_LIMIT=CORE_CLK_HZ*3; // 3 seconds at actual core frequency

    function [20:0] slot_base(input [2:0] idx);
        begin case(idx)
            0:slot_base=0;1:slot_base=307200;2:slot_base=614400;
            3:slot_base=921600;default:slot_base=1228800;
        endcase end
    endfunction
    function [20:0] frame_top(input [2:0] idx,input top_down);
        begin frame_top=slot_base(idx)+(top_down?21'd0:21'd306560);end
    endfunction
    function [2:0] next_group(input [2:0] g);
        begin next_group=(g==6)?0:g+1'b1;end
    endfunction
    function [2:0] prev_group(input [2:0] g);
        begin prev_group=(g==0)?6:g-1'b1;end
    endfunction
    wire want_hit0=cache_valid0&&cache_group0==want_index;
    wire want_hit1=cache_valid1&&cache_group1==want_index;
    wire want_ready=(want_index==0)||want_hit0||want_hit1;
    wire [2:0] want_after=(want_index==0)?3'd0:want_hit1?3'd4:3'd2;
    wire [2:0] want_before=(want_index==0)?3'd0:want_hit1?3'd3:3'd1;
    reg [20:0] line_before_base;
    // The app request address is pipelined one cycle ahead, including the
    // A/B boundary. Only one pixel is fetched for each canvas x.
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin mem_owner<=M_IDLE;mem_sent<=0;mem_returned<=0;mem_guard<=0;mem_line_video<=0;end
        else begin
            if(app_rd_en||video_write_fire)mem_sent<=mem_sent+1'b1;
            if(sdr_rd_en&&(mem_owner==M_VIDEO||mem_owner==M_VERIFY))mem_returned<=mem_returned+1'b1;
            case(mem_owner)
                M_IDLE:begin
                    mem_sent<=0;mem_returned<=0;
                    if(display_started&&loader_active)begin mem_owner<=M_VIDEO;mem_line_video<=scan_video;end
                    else if(block_draining&&!fifo_empty&&(top_state==T_LOAD))mem_owner<=M_WRITE;
                    else if(verify_busy)mem_owner<=M_VERIFY;
                    else if(video_session&&vfifo_full&&!video_flush)mem_owner<=M_MEDIA;
                end
                M_VIDEO:if(line_grant_done)begin mem_owner<=M_TURN;mem_guard<=0;end
                M_MEDIA:if(vfifo_empty||mem_sent==512)begin mem_owner<=M_TURN;mem_guard<=0;end
                M_WRITE:if(fifo_empty||top_state!=T_LOAD)begin mem_owner<=M_TURN;mem_guard<=0;end
                M_VERIFY:if((mem_sent==512&&mem_returned==512)||
                             (!verify_busy&&mem_sent==mem_returned))begin mem_owner<=M_TURN;mem_guard<=0;end
                M_TURN:if(mem_guard==63)mem_owner<=M_IDLE;else mem_guard<=mem_guard+1'b1;
                default:mem_owner<=M_IDLE;
            endcase
        end
    end

    video_line_buffer u_linebuf(.wr_clk(clk100),.wr_en(line_wr_en),
        .wr_bank(line_wr_bank),.wr_addr(line_response_count),.wr_data(sdr_rd_data),
        .rd_clk(line_rd_clk),.rd_bank(line_rd_bank),.rd_addr(line_rd_addr),
        .rd_data(line_rd_data));
    hdmi_framebuffer #(.ENABLE_MEDIA(1)) u_video(.clk_50m(clk_50m),.run(sw0_run),
        .sw4_brightness(sw4_brightness),.sw5_contrast(sw5_contrast),.sw6_default(sw6_default),
        .sw7_audio(sw7_audio),
        .media_mode_sys(video_session),.media_run_sys(video_audio_run),.media_pause_sys(video_paused),
        .media_buffer_ready_sys(video_buffer_ready),
        .media_reset_sys(video_flush),.media_samples_sys(video_samples),.media_sample_limit_sys(video_sample_limit),
        .menu_valid(menu_pixel_valid),.menu_code(menu_pixel_code),
        .lcd_status_pixel(lcd_status_pixel),.lcd_status_strobe(lcd_status_strobe),
        .frame_ready_sys(frame_ready),.line_ready_toggle_sys(line_ready_toggle),
        .line_data(line_rd_data),.line_rd_clk(line_rd_clk),
        .line_rd_bank(line_rd_bank),.line_rd_addr(line_rd_addr),
        .line_consumed_toggle(line_consumed_toggle),.underflow(video_underflow),
        .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D0_P(HDMI_D0_P),
        .HDMI_D1_P(HDMI_D1_P),.HDMI_D2_P(HDMI_D2_P),.video_locked(video_locked),
        .audio_active(audio_active),.audio_underflow(audio_underflow),
        .audio_pcm_clk(clk100),.audio_pcm_valid(audio_pcm_valid),
        .audio_pcm_sample(audio_pcm_sample),.audio_pcm_ready(audio_pcm_ready),.audio_pcm_low(audio_pcm_low),
        .display_exhibit_id(load_index),.auto_mode(auto_mode),
        .compare_mode(scan_compare),.compare_split(scan_split),
        .source_resolution_bcd(source_resolution_bcd),
        .transition_level(fade_level),
        .line_zoom0_sys(line_zoom0),.line_zoom1_sys(line_zoom1),.aim_packet_pixel(aim_packet_pixel));

    lcd_mailbox #(.WIDTH(41)) u_zoom_aim(.reset(lcd_cdc_reset),.src_clk(clk100),.src_valid(1'b1),
        .src_data({region_aim_mode,region_zoom_lx,region_zoom_ly,region_aim_w,region_aim_h}),.src_ready(),
        .dst_clk(line_rd_clk),.dst_valid(),.dst_data(aim_packet_pixel));
    // Independent LCD/CTP buses: no arbitration or reset of TF/SDRAM/HDMI.
    lcd_touch_reader #(.CLK_HZ(CORE_CLK_HZ),.I2C_HALF(417)) u_touch(.clk(clk100),.reset(rst),.scl(ctp_scl),.sda(ctp_sda),
        .interrupt_n(ctp_int_n),.reset_n(ctp_reset_n),.present(touch_present),
        .event_valid(touch_event_valid),.event_code(touch_event_code),.fault(touch_fault),
        .slider_valid(touch_slider_valid),.slider_position(touch_slider_position),
        .zoom_page(zoom_page||video_session),.locate_valid(touch_locate_valid),
        .locate_x(touch_locate_x),.locate_y(touch_locate_y),
        .zoom_valid(touch_zoom_valid),.zoom_command(touch_zoom_command));
    lcd_mailbox #(.WIDTH(4)) u_touch_commands(.reset(lcd_cdc_reset),.src_clk(clk100),
        .src_valid(|menu_pending),.src_data(menu_source_code),
        .src_ready(menu_source_ready),.dst_clk(line_rd_clk),.dst_valid(menu_pixel_valid),.dst_data(menu_pixel_code));
    lcd_mailbox #(.WIDTH(57)) u_lcd_status(.reset(lcd_cdc_reset),.src_clk(line_rd_clk),
        .src_valid(lcd_status_strobe),.src_data(lcd_status_pixel),.src_ready(),
        .dst_clk(clk100),.dst_valid(lcd_status_valid),.dst_data(lcd_status_sys));
    // Reuse the already configured 25MHz PLL output for the slow LCD UI.
    // LCD stays at 25 MHz; HDMI clocks remain at their original frequencies.
    wire [114:0] lcd_panel_status;
    reg [1:0] lcd_reset_pipe;
    always @(posedge clk25_unused or posedge rst)
        if(rst)lcd_reset_pipe<=0;else lcd_reset_pipe<={lcd_reset_pipe[0],1'b1};
    lcd_mailbox #(.WIDTH(115)) u_lcd_panel_status(.reset(lcd_cdc_reset),.src_clk(clk100),
        .src_valid(1'b1),.src_data({(video_session?
            {1'b1,1'b0,video_audio_run,video_paused,3'd7,video_frame_number[9:0],video_total_frames[9:0],20'd0}:
            {zoom_page,(load_index==0),region_zoom_mode,region_aim_mode,region_zoom_level,zoom_focus_x,zoom_focus_y,region_zoom_lx,region_zoom_ly}),
            lcd_status_sys,(video_error!=0?video_error:top_error),display_started,touch_present,touch_fault}),
        .src_ready(),.dst_clk(clk25_unused),.dst_valid(),.dst_data(lcd_panel_status));
    lcd_menu_driver #(.CLK_HZ(25000000),.SPI_HALF(3)) u_lcd(
        .clk(clk25_unused),.reset(!lcd_reset_pipe[1]),.status(lcd_panel_status[67:11]),
        .zoom_status(lcd_panel_status[114:68]),
        .main_error(lcd_panel_status[10:3]),.main_ready(lcd_panel_status[2]),
        .touch_present(lcd_panel_status[1]),.touch_fault(lcd_panel_status[0]),
        .lcd_cs_n(lcd_cs_n),.lcd_rst_n(lcd_rst_n),.lcd_dc(lcd_dc),
        .lcd_mosi(lcd_mosi),.lcd_sck(lcd_sck),.lcd_bl(lcd_bl));

    // Full-screen zoom: the row pointer follows src_y = Ly + (cy*K)>>12 using a
    // fractional accumulator, which is mathematically identical to the
    // horizontal formula in hdmi_framebuffer. K=4096 advances one source row
    // per display line, so at 1x the pointer behaves exactly as before.
    reg [12:0] zoom_acc;
    wire [12:0] zoom_acc_sum=zoom_acc+scan_zoom_k;
    wire zoom_row_step=scan_zoom_active&&(zoom_acc_sum>=13'd4096);
    wire zoom_page_swap=(play_state==P_SWAP)&&(want_index!=load_index);
    wire [2:0] zoom_next_group=zoom_page_swap?want_index:load_index;
    wire [2:0] zoom_next_after=zoom_page_swap?want_after:scan_after_slot;
    wire [2:0] zoom_next_before=zoom_page_swap?want_before:scan_before_slot;
    wire zoom_next_compare=zoom_page_swap?1'b0:compare_requested;
    // Precompute a complete candidate over three short arithmetic stages.
    // The final valid bit checks page/compare/slot identity at commit time.
    reg [20:0] zoom_row_off,zoom_top_a,zoom_top_b;
    reg zoom_down_a,zoom_down_b;reg [23:0] zoom_meta1,zoom_meta2;
    reg [20:0] zoom_base_after,zoom_base_before;
    reg [2:0] zoom_group1,zoom_group2,zoom_slot1,zoom_slot2;
    reg zoom_cmp1,zoom_cmp2;
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin
            zoom_row_off<=0;zoom_top_a<=0;zoom_top_b<=0;zoom_down_a<=0;zoom_down_b<=0;
            zoom_meta1<=4096;zoom_meta2<=4096;zoom_base_after<=0;zoom_base_before<=0;
            zoom_group1<=0;zoom_group2<=0;zoom_slot1<=0;zoom_slot2<=0;zoom_cmp1<=0;zoom_cmp2<=0;
        end else begin
            zoom_row_off<={region_zoom_ly,9'd0}+{region_zoom_ly,7'd0};
            zoom_top_a<=frame_top(zoom_next_after,frame_top_down[zoom_next_after]);
            zoom_top_b<=frame_top(zoom_next_before,frame_top_down[zoom_next_before]);
            zoom_down_a<=frame_top_down[zoom_next_after];zoom_down_b<=frame_top_down[zoom_next_before];
            zoom_meta1<={region_zoom_active,region_zoom_lx,region_zoom_k};
            zoom_group1<=zoom_next_group;zoom_slot1<=zoom_next_after;zoom_cmp1<=zoom_next_compare;
            zoom_base_after<=zoom_down_a?(zoom_top_a+zoom_row_off):(zoom_top_a-zoom_row_off);
            zoom_base_before<=zoom_down_b?(zoom_top_b+zoom_row_off):(zoom_top_b-zoom_row_off);
            zoom_meta2<=zoom_meta1;zoom_group2<=zoom_group1;zoom_slot2<=zoom_slot1;zoom_cmp2<=zoom_cmp1;
        end
    end
    wire zoom_next_active=!video_session&&(zoom_next_group!=0)&&!zoom_next_compare&&zoom_meta2[23]&&
        zoom_group2==zoom_next_group&&zoom_slot2==zoom_next_after&&zoom_cmp2==zoom_next_compare;

    always @(posedge clk100 or posedge rst) begin
        if(rst) begin
            scan_video<=0;video_front_base<=1536000;
            loader_active<=0;loader_initialized<=0;frame_ready<=0;
            line_issue_count<=0;line_response_count<=0;next_line<=0;
            line_base<=0;line_before_base<=0;line_issue_addr<=0;line_ready_toggle<=0;
            scan_compare<=0;scan_split<=320;scan_before_slot<=0;scan_after_slot<=0;
            line_busy<=0;initial_loaded<=0;zoom_acc<=13'd0;
            consumed_meta<=0;consumed_sync<=0;consumed_seen<=0;
            load_index<=2'd0;vblank_pulse<=1'b0;
            line_zoom0<=24'd4096;line_zoom1<=24'd4096;
            scan_zoom_active<=0;scan_zoom_lx<=0;scan_zoom_k<=4096;
        end else begin
            consumed_meta<=line_consumed_toggle;
            consumed_sync<=consumed_meta;
            vblank_pulse<=1'b0;
            if(!display_started) begin
                scan_video<=0;video_front_base<=1536000;
                loader_active<=0;loader_initialized<=0;frame_ready<=0;
                line_issue_count<=0;line_response_count<=0;next_line<=0;
                line_base<=frame_top(3'd0,frame_top_down[0]);
                line_before_base<=frame_top(3'd0,frame_top_down[0]);
                line_issue_addr<=frame_top(3'd0,frame_top_down[0]);
                line_ready_toggle<=0;line_busy<=0;initial_loaded<=0;
                consumed_seen<=consumed_sync;zoom_acc<=13'd0;
                load_index<=2'd0;
                scan_zoom_active<=0;scan_zoom_lx<=0;scan_zoom_k<=4096;
                line_zoom0<=24'd4096;line_zoom1<=24'd4096;
            end else begin
                if(consumed_sync[0]!=consumed_seen[0]) begin
                    consumed_seen[0]<=consumed_sync[0];line_busy[0]<=0;
                end
                if(consumed_sync[1]!=consumed_seen[1]) begin
                    consumed_seen[1]<=consumed_sync[1];line_busy[1]<=0;
                end
                if(!loader_initialized) begin
                    loader_initialized<=1;loader_active<=1;
                    line_issue_count<=0;line_response_count<=0;
                    line_issue_addr<=line_base;
                end else begin
                    if(line_issue) begin
                        line_issue_count<=line_issue_count+1'b1;
                        if(!line_last_request)begin
                            if(scan_video)line_issue_addr<=line_issue_addr+1'b1;
                            else if(scan_compare&&(line_issue_count+1'b1<scan_split))
                                line_issue_addr<=line_before_base+line_issue_count+1'b1;
                            else line_issue_addr<=line_base+line_issue_count+1'b1;
                        end
                    end
                    if(line_wr_en) begin
                        if(line_last_response) begin
                            // Bundled metadata has the same ownership as the line RAM:
                            // stable before ready-toggle crosses, held until consumed.
                            if(next_line[0])line_zoom1<=scan_video?{1'b0,10'd1023,13'd4096}:{scan_zoom_active,scan_zoom_lx,scan_zoom_k};
                            else line_zoom0<=scan_video?{1'b0,10'd1023,13'd4096}:{scan_zoom_active,scan_zoom_lx,scan_zoom_k};
                            loader_active<=0;
                            line_ready_toggle[next_line[0]]<=~line_ready_toggle[next_line[0]];
                            line_busy[next_line[0]]<=1;
                            initial_loaded[next_line[0]]<=1;
                            if(initial_loaded[~next_line[0]])frame_ready<=1;
                            if(next_line==479) begin
                                // Frame boundary = HDMI vertical blanking.
                                next_line<=10'd0;
                                vblank_pulse<=1'b1;
                                // E2 only exchanges the resident SDRAM frame
                                // while the output coefficient is held at 0.
                                if((play_state==P_SWAP)&&(want_index!=load_index)) begin
                                    load_index<=want_index;
                                    scan_before_slot<=want_before;scan_after_slot<=want_after;
                                    line_base<=frame_top(want_after,frame_top_down[want_after]);
                                    line_before_base<=frame_top(want_before,frame_top_down[want_before]);
                                    scan_compare<=0;scan_split<=320;
                                end else begin
                                    line_base<=frame_top(scan_after_slot,frame_top_down[scan_after_slot]);
                                    line_before_base<=frame_top(scan_before_slot,frame_top_down[scan_before_slot]);
                                    scan_compare<=compare_requested;scan_split<=split_requested;
                                end
                                // Zoom overrides the row origin: the frame starts at
                                // source row Ly so that src_y = Ly + (cy*K)>>12 holds.
                                scan_zoom_active<=zoom_next_active;
                                scan_zoom_lx<=zoom_next_active?zoom_meta2[22:13]:10'd0;
                                scan_zoom_k<=zoom_next_active?zoom_meta2[12:0]:13'd4096;
                                zoom_acc<=13'd0;
                                if(zoom_next_active) begin
                                    zoom_acc<=13'd0;
                                    line_base<=zoom_base_after;
                                    line_before_base<=zoom_base_before;
                                end
                                if(video_session&&!video_flush&&(video_running||video_offer))begin
                                    scan_video<=1;scan_compare<=0;scan_zoom_active<=0;
                                    if(video_take)begin video_front_base<=video_base;line_base<=video_base;end
                                    else line_base<=video_front_base;
                                end else scan_video<=0;
                            end else begin
                                next_line<=next_line+1'b1;
                                if(scan_video)begin
                                    if(next_line[0])line_base<=line_base+21'd320;
                                end else if(scan_zoom_active) begin
                                    if(zoom_row_step) begin
                                        zoom_acc<=zoom_acc_sum-13'd4096;
                                        line_base<=frame_top_down[scan_after_slot]?(line_base+21'd640):(line_base-21'd640);
                                    end else zoom_acc<=zoom_acc_sum;
                                end else begin
                                    line_base<=frame_top_down[scan_after_slot]?(line_base+21'd640):(line_base-21'd640);
                                    line_before_base<=frame_top_down[scan_before_slot]?(line_before_base+21'd640):(line_before_base-21'd640);
                                end
                            end
                        end else line_response_count<=line_response_count+1'b1;
                    end
                    if(!loader_active&&!line_busy[next_line[0]]) begin
                        loader_active<=1;line_issue_count<=0;line_response_count<=0;
                        line_issue_addr<=(scan_compare&&scan_split!=0)?line_before_base:line_base;
                    end
                end
            end
        end
    end

    // KEY4 toggles compare; KEY0/KEY1 move only the pending split. The line
    // loader commits pending state when preparing the next frame's row zero.
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin compare_requested<=0;split_requested<=320;end
        else if(!display_started)begin compare_requested<=0;split_requested<=320;end
        else if(play_state==P_SHOW&&!video_session)begin
            if((key_compare||(touch_event_valid&&touch_event_code==7))&&load_index!=0)
                compare_requested<=~compare_requested;
            if(compare_requested)begin
                if(touch_slider_valid)split_requested<=touch_slider_position;
                else if(key_right&&!key_left)split_requested<=(split_requested>=632)?640:split_requested+10'd8;
                else if(key_left&&!key_right)split_requested<=(split_requested<=8)?0:split_requested-10'd8;
            end
        end else begin compare_requested<=0;split_requested<=320;end
    end
    always @(posedge clk100 or posedge rst)begin
        if(rst)begin play_state<=P_SHOW;auto_mode<=0;auto_timer<=0;want_index<=0;fade_level<=32;end
        else if(!display_started)begin play_state<=P_SHOW;auto_mode<=0;auto_timer<=0;want_index<=0;fade_level<=32;end
        else if(!video_session)begin
            if(kp_mode)begin auto_mode<=~auto_mode;auto_timer<=0;end
            case(play_state)
                P_SHOW:begin
                    fade_level<=32;
                    if(!kp_mode)auto_timer<=(auto_mode&&!compare_requested)?auto_timer+1'b1:0;
                    if(!compare_requested&&!kp_mode&&!key_compare&&!(touch_event_valid&&touch_event_code==7))begin
                        if(kp_next)begin want_index<=next_group(load_index);play_state<=P_LOAD;auto_timer<=0;end
                        else if(kp_prev)begin want_index<=prev_group(load_index);play_state<=P_LOAD;auto_timer<=0;end
                        else if(auto_mode&&auto_timer==AUTO_LIMIT-1)begin want_index<=next_group(load_index);play_state<=P_LOAD;auto_timer<=0;end
                    end
                end
                P_LOAD:begin
                    auto_timer<=0;
                    if(load_failed)begin want_index<=load_index;play_state<=P_SHOW;end
                    else if(want_ready)play_state<=P_READY;
                end
                P_READY:play_state<=P_FADE_OUT;
                P_FADE_OUT:if(vblank_pulse)begin
                    if(fade_level>1)fade_level<=fade_level-1'b1;
                    else begin fade_level<=0;play_state<=P_SWAP;end
                end
                P_SWAP:begin
                    fade_level<=0;
                    if(vblank_pulse&&load_index==want_index)play_state<=P_FADE_IN;
                end
                P_FADE_IN:if(vblank_pulse)begin
                    if(fade_level>=31)begin fade_level<=32;play_state<=P_SHOW;end
                    else fade_level<=fade_level+1'b1;
                end
                default:begin play_state<=P_SHOW;fade_level<=32;end
            endcase
        end
    end

    // Internal packaged SDRAM; no external SDRAM GPIO assignments.
    wire sdram_clk,sdr_ras,sdr_cas,sdr_we; wire [1:0] sdr_ba;
    wire [10:0] sdr_addr; wire [3:0] sdr_dm; wire [31:0] sdr_dq;
    sdr_as_ram #(.self_refresh_open(1'b1)) u_controller(
        .Sdr_clk(clk100),.Sdr_clk_sft(clk100_180),.Rst(rst),
        .Sdr_init_done(init_done),.Sdr_init_ref_vld(init_ref_vld),.Sdr_busy(sdr_busy),
        .App_ref_req(1'b0),.App_wr_en(app_wr_en),.App_wr_addr(app_wr_addr),
        .App_wr_dm(app_wr_dm),.App_wr_din(app_wr_data),.App_rd_en(app_rd_en),
        .App_rd_addr(app_rd_addr),.Sdr_rd_en(sdr_rd_en),.Sdr_rd_dout(sdr_rd_data),
        .SDRAM_CLK(sdram_clk),.SDR_RAS(sdr_ras),.SDR_CAS(sdr_cas),.SDR_WE(sdr_we),
        .SDR_BA(sdr_ba),.SDR_ADDR(sdr_addr),.SDR_DM(sdr_dm),.SDR_DQ(sdr_dq));
    EG_PHY_SDRAM_2M_32 u_sdram(.clk(sdram_clk),.ras_n(sdr_ras),.cas_n(sdr_cas),
        .we_n(sdr_we),.addr(sdr_addr),.ba(sdr_ba),.dq(sdr_dq),.cs_n(1'b0),
        .dm0(sdr_dm[0]),.dm1(sdr_dm[1]),.dm2(sdr_dm[2]),.dm3(sdr_dm[3]),.cke(1'b1));

    always @(posedge clk100 or posedge rst) begin
        if(rst) begin
            top_state<=T_WAIT_CARD;turn_count<=0;top_error<=0;loc_start<=0;
            stream_start<=0;bmp_start<=0;verify_start<=0;stream_abort<=0;blink<=0;
            write_sum<=0;write_xor<=0;exp_tl<=0;exp_tr<=0;exp_bl<=0;exp_br<=0;
            format_checked<=0;format_ok_latched<=0;parser_finished<=0;write_count<=0;
            image_index<=0;write_slot<=0;frame_base<=0;write_addr<=0;block_draining<=0;
            display_started<=0;runtime_load<=0;load_bank<=0;load_failed<=0;
            loading_group<=0;cache_group0<=0;cache_group1<=0;cache_valid0<=0;cache_valid1<=0;
            pair_width0<=0;pair_height0<=0;pair_width1<=0;pair_height1<=0;
            music_start<=0;music_enabled<=0;music_fat<=0;music_data<=0;music_max<=0;
            music_cluster<=0;music_size<=0;music_spc<=0;
            frame_top_down<=0;music_mode<=0;
        end else begin
            loc_start<=0;stream_start<=0;bmp_start<=0;verify_start<=0;stream_abort<=0;
            blink<=blink+1'b1;load_failed<=0;music_start<=0;
            if(music_enabled&&!video_session&&(m_done||video_previous))music_start<=1;
            if(write_fire) begin
                write_count<=write_count+1'b1;write_addr<=write_addr+1'b1;
                write_sum<=write_sum+fifo_dout;write_xor<=write_xor^fifo_dout;
                if(write_count==0)exp_tl<=fifo_dout;
                if(write_count==639)exp_tr<=fifo_dout;
                if(write_count==306560)exp_bl<=fifo_dout;
                if(write_count==307199)exp_br<=fifo_dout;
            end
            if((top_state==T_LOAD)&&!block_draining&&fifo_full) block_draining<=1;
            else if(block_draining&&fifo_empty) block_draining<=0;

            case(top_state)
                T_WAIT_CARD: if(host_error)begin top_error<=host_ec;top_state<=T_ERROR;end
                    else if(host_ready)top_state<=T_LOC_START;
                T_LOC_START:begin
                    frame_base<=slot_base(write_slot);
                    loc_start<=1;top_state<=T_LOC_WAIT;
                end
                T_LOC_WAIT:if(loc_error)begin top_error<=loc_ec;top_state<=T_ERROR;end
                    else if(loc_done)top_state<=T_LOAD_START;
                T_LOAD_START:begin
                    write_sum<=0;write_xor<=0;write_count<=0;write_addr<=frame_base;
                    parser_finished<=0;block_draining<=0;format_checked<=0;
                    format_ok_latched<=0;stream_start<=1;bmp_start<=1;top_state<=T_LOAD;
                end
                T_LOAD:begin
                    if(parser_error)begin top_error<=parser_ec;top_state<=T_ERROR;end
                    else if(scale_error)begin top_error<=scale_ec;top_state<=T_ERROR;end
                    else if(stream_error)begin top_error<=stream_ec;top_state<=T_ERROR;end
                    // start clears parser metadata by NBA on this same edge;
                    // do not accept the preceding file's still-visible header.
                    else if(metadata_valid&&!format_checked&&!bmp_start)begin
                        format_checked<=1;
                        if(img_w==0||img_h==0||img_w>800||img_h>800)begin
                            top_error<=`ERR_SCALE_RANGE;top_state<=T_ERROR;
                        end else begin
                            if((write_slot==2&&(img_w!=pair_width0||img_h!=pair_height0))||
                               (write_slot==4&&(img_w!=pair_width1||img_h!=pair_height1)))begin
                                top_error<=8'h83;top_state<=T_ERROR;
                            end else begin
                                format_ok_latched<=1;frame_top_down[write_slot]<=image_top_down;
                                if(write_slot==1)begin pair_width0<=img_w[9:0];pair_height0<=img_h[9:0];end
                                if(write_slot==3)begin pair_width1<=img_w[9:0];pair_height1<=img_h[9:0];end
                            end
                        end
                    end else if(parser_done)begin
                        parser_finished<=1;
                    end else if(parser_finished&&scale_done&&fifo_empty&&!block_draining)begin
                        if(write_count!=307200)begin
                            top_error<=`ERR_SDRAM_WRITE_CNT;top_state<=T_ERROR;
                        end else begin turn_count<=0;top_state<=T_TURN;end
                    end
                end
                T_TURN:if(turn_count==63)top_state<=T_VERIFY_START;
                    else turn_count<=turn_count+1'b1;
                T_VERIFY_START:begin verify_start<=1;top_state<=T_VERIFY;end
                T_VERIFY:if(verify_done)begin
                    if(verify_pass&&!verify_protocol)begin
                        stream_abort<=1;
                        if(runtime_load)begin
                            if(write_slot[0])begin write_slot<=write_slot+1'b1;image_index<=image_index+1'b1;top_state<=T_LOC_START;end
                            else begin
                                if(load_bank)begin cache_group1<=loading_group;cache_valid1<=1;end
                                else begin cache_group0<=loading_group;cache_valid0<=1;end
                                runtime_load<=0;top_state<=T_DONE;
                            end
                        end else if(image_index==2)begin
                            cache_group0<=1;cache_valid0<=1;music_mode<=1;top_state<=T_MUSIC_LOC_START;
                        end else begin
                            image_index<=image_index+1'b1;write_slot<=write_slot+1'b1;top_state<=T_LOC_START;
                        end
                    end else begin
                        top_error<=(verify_failure_code==0)?`ERR_SDRAM_VERIFY:verify_failure_code;
                        top_state<=T_ERROR;
                    end
                end
                T_MUSIC_LOC_START:begin loc_start<=1'b1;top_state<=T_MUSIC_LOC_WAIT;end
                T_MUSIC_LOC_WAIT:begin
                    if(loc_error)begin top_error<=loc_ec;top_state<=T_ERROR;end
                    else if(loc_done)begin
                        // 16-bit PCM must contain a whole number of samples.
                        if(file_size<2||file_size[0])begin top_error<=8'h51;top_state<=T_ERROR;end
                        else begin
                            music_fat<=fat_lba;music_data<=data_lba;music_max<=max_cluster;
                            music_spc<=spc;music_cluster<=first_cluster;music_size<=file_size;
                            top_state<=T_MUSIC_STREAM_START;
                        end
                    end
                end
                T_MUSIC_STREAM_START:begin
                    music_start<=1;music_enabled<=1;music_mode<=0;display_started<=1;top_state<=T_DONE;
                end
                T_DONE:begin
                    if(m_error&&music_enabled&&!video_session&&!video_previous&&!music_start)begin music_enabled<=0;top_error<=m_ec;top_state<=T_ERROR;end
                    else if(!video_session&&play_state==P_LOAD&&!want_ready&&!load_failed)begin
                        // Never overwrite the pair currently scanned.
                        load_bank<=(scan_after_slot==2);
                        loading_group<=want_index;runtime_load<=1;top_error<=0;music_mode<=0;
                        image_index<={want_index,1'b0}-1'b1;
                        if(scan_after_slot==2)begin write_slot<=3;cache_valid1<=0;end
                        else begin write_slot<=1;cache_valid0<=0;end
                        top_state<=T_LOC_START;
                    end
                end
                T_ERROR:if(display_started)begin
                    // Retain the old display and the independent music cursor.
                    stream_abort<=1;runtime_load<=0;load_failed<=1;top_state<=T_DONE;
                end
                default:begin top_error<=8'h7f;top_state<=T_ERROR;end
            endcase
        end
    end

    // LED:
    //  LED0 = 播放常亮 / ERROR 闪烁
    //  LED1/2 = logical page low two bits; pages0..6 require LCD/full OSD ID.
    //  LED3 = 视频或音频 FIFO 欠读锁存（正常为 0）
    //  LED4 = HDMI 锁定
    //  LED5 = 自动轮播模式（1=自动）
    //  LED6 = HDMI/音频通路使能（PLL 锁定、音频播放中常亮）
    //  LED7 = SD 主机就绪
    // A video exit code overrides all eight status LEDs until start/reset.
    assign led=(video_error!=0)?video_error:
        {(top_state==T_ERROR)?top_error[6:0]:
          {host_ready,audio_active,auto_mode,video_locked,
           (video_underflow|audio_underflow),load_index[1:0]},
         (top_state==T_DONE)||((top_state==T_ERROR)&&blink[27])};
endmodule
