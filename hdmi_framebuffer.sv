`timescale 1ns/1ps
// Step 4: true HDMI (video + 48 kHz audio) via hdl-util core.
// The dual scan-line buffer handshake from Step 2 is preserved; the read side
// now runs on the independent 25 MHz clk_pixel and is addressed by the hdl-util
// cx/cy counters (frame 800x525, active 640x480, same timing as before).
module hdmi_framebuffer #(parameter ENABLE_MEDIA=0)(
    input wire clk_50m,input wire run,input wire frame_ready_sys,
    input wire sw4_brightness,input wire sw5_contrast,input wire sw6_default,
    input wire sw7_audio,
    input wire media_mode_sys,media_run_sys,media_pause_sys,media_reset_sys,
    output wire [31:0] media_samples_sys,input wire [24:0] media_sample_limit_sys,
    output reg media_buffer_ready_sys,
    input wire menu_valid,input wire [3:0] menu_code,
    output wire [56:0] lcd_status_pixel,output wire lcd_status_strobe,
    input wire [1:0] line_ready_toggle_sys,input wire [31:0] line_data,
    output wire line_rd_clk,output wire line_rd_bank,output wire [9:0] line_rd_addr,
    output reg [1:0] line_consumed_toggle,output reg underflow,
    output wire HDMI_CLK_P,output wire HDMI_D0_P,output wire HDMI_D1_P,
    output wire HDMI_D2_P,output wire video_locked,
    output wire audio_active,
    output reg audio_underflow,
    input wire audio_pcm_clk,input wire audio_pcm_valid,
    input wire [15:0] audio_pcm_sample,output wire audio_pcm_ready,output wire audio_pcm_low,
    input wire [2:0] display_exhibit_id,
    input wire compare_mode,input wire [9:0] compare_split,
    input wire auto_mode,
    input wire [23:0] source_resolution_bcd,
    input wire [5:0] transition_level,
    input wire [23:0] line_zoom0_sys,line_zoom1_sys,input wire [40:0] aim_packet_pixel
);
    wire clk_pixel,clk_5x,pll_locked;
    reg [1:0] reset_pipe;
    hdmi_pll u_hdmi_pll(.refclk(clk_50m),.reset(!run),
        .clk_pixel(clk_pixel),.clk_5x(clk_5x),.locked(pll_locked));

    wire async_reset=!run||!pll_locked;
    always @(posedge clk_pixel or posedge async_reset)
        if(async_reset) reset_pipe<=0;
        else reset_pipe<={reset_pipe[0],1'b1};
    wire video_reset=!reset_pipe[1];
    assign video_locked=reset_pipe[1];

    // ---- Audio sample clock ~48 kHz: 125 MHz / 2604 = 48003 Hz ----
    reg [10:0] aud_cnt=11'd0; reg clk_audio_u=1'b0;
    always @(posedge clk_5x)
        if(async_reset) begin aud_cnt<=11'd0; clk_audio_u<=1'b0; end
        else if(aud_cnt==11'd1301) begin aud_cnt<=11'd0; clk_audio_u<=~clk_audio_u; end
        else aud_cnt<=aud_cnt+11'd1;
    wire clk_audio;
    EG_LOGIC_BUFG u_audio_buf(.i(clk_audio_u),.o(clk_audio));

    // ---- TF-card PCM stream: 48 kHz, mono, signed 16-bit little-endian ----
    // Media uses 8192 samples; BGM uses 4096. The shared started flag rises
    // after 1024 writes; media consumption also waits for full-frame commit.
    wire audio_fifo_full,audio_fifo_empty;
    wire pcm_reset=async_reset||(ENABLE_MEDIA&&media_reset_sys);
    reg [1:0] pcm_release;
    always @(posedge clk_audio or posedge pcm_reset)
        if(pcm_reset)pcm_release<=3;else pcm_release<={pcm_release[0],1'b0};
    wire stream_reset=pcm_reset||pcm_release[1];
    reg mode_a1,mode_a2,run_a1,run_a2,pause_a1,pause_a2;
    // Header-derived limit is held stable throughout prefill and playback;
    // run cannot assert until a full frame has been loaded (~100ms later).
    reg [24:0] limit_a1,limit_a2;
    always @(posedge clk_audio or posedge stream_reset)
        if(stream_reset)begin limit_a1<=0;limit_a2<=0;end
        else begin limit_a1<=media_sample_limit_sys;limit_a2<=limit_a1;end
    reg [24:0] media_samples;
    wire media_at_end=mode_a2&&limit_a2!=0&&media_samples>=limit_a2;
    always @(posedge clk_audio or posedge async_reset)
        if(async_reset)begin mode_a1<=0;mode_a2<=0;run_a1<=0;run_a2<=0;pause_a1<=0;pause_a2<=0;end
        else begin
            mode_a1<=ENABLE_MEDIA&&media_mode_sys;mode_a2<=mode_a1;
            run_a1<=ENABLE_MEDIA&&media_run_sys;run_a2<=run_a1;
            pause_a1<=ENABLE_MEDIA&&media_pause_sys;pause_a2<=pause_a1;
        end

    always @(posedge clk_audio or posedge stream_reset)
        if(stream_reset)media_samples<=0;
        else if(mode_a2&&audio_fifo_read)media_samples<=media_samples+1'b1;
    wire [24:0] media_time_short;
    assign media_samples_sys={7'd0,media_time_short};
    lcd_mailbox #(.WIDTH(25)) u_media_time(.reset(stream_reset),
        .src_clk(clk_audio),.src_valid(1'b1),.src_data(media_samples),.src_ready(),
        .dst_clk(audio_pcm_clk),.dst_valid(),.dst_data(media_time_short));
    wire [15:0] audio_fifo_data;
    wire audio_fifo_write=audio_pcm_valid&&!audio_fifo_full;
    wire audio_fifo_read;
    reg [10:0] audio_prefill_count;
    reg audio_started_sys,audio_started_a1,audio_started_a2;
    assign audio_pcm_ready=!audio_fifo_full&&!stream_reset;

    always @(posedge audio_pcm_clk or posedge stream_reset) begin
        if(stream_reset) begin audio_prefill_count<=0;audio_started_sys<=0;end
        else if(!audio_started_sys&&audio_fifo_write) begin
            if(audio_prefill_count==11'd1023) audio_started_sys<=1'b1;
            else audio_prefill_count<=audio_prefill_count+1'b1;
        end
    end
    always @(posedge clk_audio or posedge stream_reset) begin
        if(stream_reset) begin
            audio_started_a1<=0;audio_started_a2<=0;audio_underflow<=0;
        end else begin
            audio_started_a1<=audio_started_sys;
            audio_started_a2<=audio_started_a1;
            if(ENABLE_MEDIA&&mode_a2&&!run_a2)audio_underflow<=1'b0;
            else if(audio_started_a2&&(!mode_a2||(run_a2&&!pause_a2))&&!media_at_end&&audio_fifo_empty) audio_underflow<=1'b1;
        end
    end
    assign audio_fifo_read=audio_started_a2&&!audio_fifo_empty&&(!mode_a2||(run_a2&&!pause_a2&&!media_at_end));
    assign audio_active=audio_started_a2;
    wire [(ENABLE_MEDIA?13:12):0] audio_fifo_used;
    // Registered in the FIFO write domain: no wide CDC or combinational
    // occupancy feedback into the media byte handshake.
    always @(posedge audio_pcm_clk or posedge stream_reset)
        if(stream_reset)media_buffer_ready_sys<=0;
        else media_buffer_ready_sys<=ENABLE_MEDIA&&(audio_fifo_used>=4096);
    audio_async_fifo #(.DATA_WIDTH(16),.ADDR_WIDTH(ENABLE_MEDIA?13:12),.SHOWAHEAD(ENABLE_MEDIA)) u_audio_fifo(
        .rst(stream_reset),.wr_clk(audio_pcm_clk),.wr_en(audio_fifo_write),
        .wr_data(audio_pcm_sample),.full(audio_fifo_full),
        .rd_clk(clk_audio),.rd_en(audio_fifo_read),.rd_data(audio_fifo_data),
        .empty(audio_fifo_empty),.wr_used(audio_fifo_used));
    assign audio_pcm_low=(audio_fifo_used<2048);

    wire [15:0] audio_sample_word [1:0];
    // Mono is intentionally duplicated to HDMI left and right channels.
    // An empty FIFO emits digital silence rather than repeating stale audio.
    wire [15:0] music_output_sample=audio_fifo_empty?16'h0000:audio_fifo_data;
    wire [15:0] selected_audio_sample;
    wire [2:0] audio_source_mode;
    wire audio_mode_press;
    key_input #(.CLK_HZ(25_000_000),.REPEAT_EN(0)) u_key_audio(
        .clk(clk_pixel),.rst(video_reset),.raw(sw7_audio),.pressed(audio_mode_press),.level());
    audio_source_select u_audio_source(
        .pixel_clk(clk_pixel),.pixel_reset(video_reset),
        .mode_press(audio_mode_press||(menu_valid&&menu_code==3)),
        .audio_clk(clk_audio),.audio_reset(async_reset),.music_sample(music_output_sample),
        .output_sample(selected_audio_sample),.source_mode(audio_source_mode));
    wire [15:0] final_audio=mode_a2?((run_a2&&!pause_a2&&audio_source_mode!=4)?music_output_sample:16'd0):selected_audio_sample;
    assign audio_sample_word[0]=final_audio;
    assign audio_sample_word[1]=final_audio;

    // ---- hdl-util timing counters ----
    wire [9:0] cx,cy;
    wire [23:0] osd_layer_rgb,osd_rgb;

    // Line-buffer read port (25 MHz), addressed by cx/cy.
    // ---- Innovation: full-screen digital zoom ----------------------
    // src_x = Lx + (cx * K) >> 12 with K = 4096 / magnification. At 1x
    // (K=4096, Lx=0) this reduces to cx, so the unzoomed path is bit-identical
    // to the original design. The dual-bank line buffer already holds a full
    // 640-pixel source line, so magnification costs only this address logic.
    // Row metadata travels under the existing ready/consumed ownership
    // handshake, rather than independently synchronizing each payload bit.
    reg [23:0] zoom_row0,zoom_row1;reg [1:0] zoom_seen;
    always @(posedge clk_pixel or posedge video_reset) begin
        if(video_reset)begin zoom_row0<=24'd4096;zoom_row1<=24'd4096;zoom_seen<=0;end
        else begin
            if(line_ready_sync[0]!=zoom_seen[0])begin
                zoom_row0<=line_zoom0_sys;zoom_seen[0]<=line_ready_sync[0];
            end
            if(line_ready_sync[1]!=zoom_seen[1])begin
                zoom_row1<=line_zoom1_sys;zoom_seen[1]<=line_ready_sync[1];
            end
        end
    end
    wire [23:0] zoom_row=cy[0]?zoom_row1:zoom_row0;
    wire z_en_s2=zoom_row[23];wire [9:0] z_lx_s2=zoom_row[22:13];
    wire [12:0] z_k_s2=zoom_row[12:0];
    // The existing row-owned video tag selects 320 source words. Horizontal
    // 2x replication is a wire shift here, never a repeated SDRAM request.
    wire media_row=ENABLE_MEDIA&&!z_en_s2&&z_lx_s2==1023;
    wire [21:0] zoom_prod={12'd0,cx}*{9'd0,z_k_s2};
    wire [9:0] zoom_src=z_lx_s2+zoom_prod[21:12];
    wire [9:0] zoom_src_lim=(zoom_src>10'd639)?10'd639:zoom_src;
    // The address multiply is registered so the line-buffer address setup no
    // longer depends on a 10x13 product in the same 40 ns cycle (v1 had no
    // multiplier on this path). Cost: a fixed one-pixel horizontal shift.
    reg [9:0] line_rd_addr_r;
    // Media alone compensates the existing address register + RAM latency:
    // fetch one source word (two output pixels) ahead, prefetch word 0 in
    // blanking, and select the next row bank one clock before x=0.
    wire [8:0] media_fetch_x=cx[9:1]+9'd1;
    wire [9:0] media_fetch_addr=(cx<640)?{1'b0,media_fetch_x}:10'd0;
    always @(posedge clk_pixel) line_rd_addr_r<=media_row?media_fetch_addr:(z_en_s2?zoom_src_lim:cx);
    assign line_rd_clk=clk_pixel;
    assign line_rd_bank=(media_row&&cx==799)?((cy==524)?1'b0:!cy[0]):cy[0];
    assign line_rd_addr=line_rd_addr_r;

    // ---- Frame / line handshake, ported from the 125 MHz/5-phase design ----
    reg ready_meta,ready_sync,display_frame;
    reg [1:0] line_ready_meta,line_ready_sync,line_ready_seen;
    reg lv_reg;
    always @(posedge clk_pixel or posedge video_reset) begin
        if(video_reset) begin
            ready_meta<=1'b0;ready_sync<=1'b0;display_frame<=1'b0;
            line_ready_meta<=2'd0;line_ready_sync<=2'd0;line_ready_seen<=2'd0;
            line_consumed_toggle<=2'd0;lv_reg<=1'b0;underflow<=1'b0;
        end else begin
            ready_meta<=frame_ready_sys; ready_sync<=ready_meta;
            line_ready_meta<=line_ready_toggle_sys; line_ready_sync<=line_ready_meta;
            if(cx==10'd799 && cy==10'd524) display_frame<=ready_sync;
            if(cx==10'd0 && cy<10'd480 && display_frame) begin
                if(cy[0]==1'b0) begin
                    lv_reg<=line_ready_sync[0]!=line_ready_seen[0];
                    if(line_ready_sync[0]!=line_ready_seen[0])
                        line_ready_seen[0]<=line_ready_sync[0];
                    if(line_ready_sync[0]==line_ready_seen[0]) underflow<=1'b1;
                end else begin
                    lv_reg<=line_ready_sync[1]!=line_ready_seen[1];
                    if(line_ready_sync[1]!=line_ready_seen[1])
                        line_ready_seen[1]<=line_ready_sync[1];
                    if(line_ready_sync[1]==line_ready_seen[1]) underflow<=1'b1;
                end
            end
            if(cx==10'd639 && cy<10'd480 && display_frame && lv_reg)
                line_consumed_toggle[cy[0]]<=~line_consumed_toggle[cy[0]];
        end
    end
    // cx==0 uses the freshly computed validity; later columns hold lv_reg.
    wire lv_new = cy[0] ? (line_ready_sync[1]!=line_ready_seen[1])
                        : (line_ready_sync[0]!=line_ready_seen[0]);
    wire line_valid = (cx==10'd0) ? lv_new : lv_reg;

    // ---- Pixel color: frame image / magenta diagnostic / color bars ----
    wire active=(cx<10'd640)&&(cy<10'd480);
    wire [23:0] bars=(cx<10'd80)?24'hffffff:(cx<10'd160)?24'hffff00:
        (cx<10'd240)?24'h00ffff:(cx<10'd320)?24'h00ff00:(cx<10'd400)?24'hff00ff:
        (cx<10'd480)?24'hff0000:(cx<10'd560)?24'h0000ff:24'h000000;
    wire [23:0] rgb=(display_frame&&active)
        ? (line_valid ? line_data[23:0] : 24'hff00ff)
        : bars;
    wire osd_frame_end=(cx==10'd799)&&(cy==10'd524);
    wire osd_underflow=display_frame&&active&&!line_valid;

    // ---- E4: control and image adjustment; no added pixel latency ----
    // Spare SW4/SW5/SW6 are synchronized/debounced directly at 25 MHz,
    // avoiding a new multi-bit parameter CDC. Existing SW0..SW3 are unchanged.
    wire brightness_press,contrast_press,default_press,adjust_hud_visible;
    wire signed [7:0] brightness_level;wire [6:0] contrast_level;
    key_input #(.CLK_HZ(25_000_000),.REPEAT_EN(1),.LONG_MS(400),.REPEAT_MS(100)) u_key_brightness(
        .clk(clk_pixel),.rst(video_reset),.raw(sw4_brightness),
        .pressed(brightness_press),.level());
    key_input #(.CLK_HZ(25_000_000),.REPEAT_EN(1),.LONG_MS(400),.REPEAT_MS(100)) u_key_contrast(
        .clk(clk_pixel),.rst(video_reset),.raw(sw5_contrast),
        .pressed(contrast_press),.level());
    key_input #(.CLK_HZ(25_000_000),.REPEAT_EN(0)) u_key_default(
        .clk(clk_pixel),.rst(video_reset),.raw(sw6_default),
        .pressed(default_press),.level());
    image_adjust_control u_adjust_control(
        .clk(clk_pixel),.reset(video_reset),.frame_end(osd_frame_end),
        .brightness_press(brightness_press||(menu_valid&&menu_code==4)),
        .contrast_press(contrast_press||(menu_valid&&menu_code==5)),
        .default_press(default_press||(menu_valid&&menu_code==6)),.brightness_level(brightness_level),
        .brightness_down(menu_valid&&menu_code==8),.contrast_down(menu_valid&&menu_code==9),
        .contrast_level(contrast_level),.hud_visible(adjust_hud_visible));
    wire [23:0] adjusted_image_rgb;
    image_color_adjust u_image_adjust(
        .rgb_in(rgb),.brightness_level(brightness_level),.contrast_level(contrast_level),
        .rgb_out(adjusted_image_rgb));
    // Retain boot color bars and magenta underflow diagnostic exactly.
    wire [23:0] image_osd_base=(display_frame&&active&&line_valid)?adjusted_image_rgb:rgb;
    // The viewfinder bundle has already crossed via a held request/ACK mailbox.
    // Commit it once per HDMI frame; address-mapping row metadata is unchanged.
    reg [40:0] aim_display;
    always @(posedge clk_pixel or posedge video_reset)
        if(video_reset)aim_display<=0;
        else if(cx==799&&cy==524)aim_display<=aim_packet_pixel;
    wire [9:0] ax=aim_display[39:30],ay=aim_display[29:20];
    wire [10:0] box_r={1'b0,ax}+{1'b0,aim_display[19:10]};
    wire [10:0] box_b={1'b0,ay}+{1'b0,aim_display[9:0]};
    wire box_inside=(cx>=ax)&&(cy>=ay)&&({1'b0,cx}<box_r)&&({1'b0,cy}<box_b);
    wire box_edge=box_inside&&((cx-ax<2)||(cy-ay<2)||({1'b0,cx}+11'd2>=box_r)||({1'b0,cy}+11'd2>=box_b));
    wire [23:0] image_osd_marked=(aim_display[40]&&box_edge)?24'hffe000:image_osd_base;

    // ---- E1/E2: synchronize metadata and fade coefficient ----
    // All visible state is committed only at the 800x525 frame boundary.
    reg [2:0] ex_s1,ex_s2,ex_display; reg am_s1,am_s2,am_display;
    reg cmp_s1,cmp_s2,cmp_display;reg [9:0] split_s1,split_s2,split_display;
    reg [5:0] fl_s1,fl_s2,fl_display;
    // Four per-image sizes are frozen before frame_ready. Synchronize the
    // stable bundle, then select using the SAME id committed at frame end.
    reg [23:0] resolution_s1,resolution_s2;
    reg [11:0] width_display_bcd,height_display_bcd;
    wire [2:0] lcd_audio_mode;
    lcd_mailbox #(.WIDTH(3)) u_audio_status(.reset(video_reset||async_reset),
        .src_clk(clk_audio),.src_valid(1'b1),.src_data(audio_source_mode),.src_ready(),
        .dst_clk(clk_pixel),.dst_valid(),.dst_data(lcd_audio_mode));
    assign lcd_status_pixel={cmp_display,split_display,ex_display,am_display,brightness_level,contrast_level,
                             width_display_bcd,height_display_bcd,lcd_audio_mode};
    assign lcd_status_strobe=osd_frame_end;
    always @(posedge clk_pixel) begin
        if (video_reset) begin
            ex_s1<=2'd0; ex_s2<=2'd0; ex_display<=2'd0;
            am_s1<=1'b0; am_s2<=1'b0; am_display<=1'b0;
            fl_s1<=6'd32;fl_s2<=6'd32;fl_display<=6'd32;
            resolution_s1<=0;resolution_s2<=0;
            cmp_s1<=0;cmp_s2<=0;cmp_display<=0;split_s1<=320;split_s2<=320;split_display<=320;
            width_display_bcd<=0;height_display_bcd<=0;
        end else begin
            ex_s1<=display_exhibit_id; ex_s2<=ex_s1;
            am_s1<=auto_mode; am_s2<=am_s1;
            fl_s1<=transition_level;fl_s2<=fl_s1;
            resolution_s1<=source_resolution_bcd;resolution_s2<=resolution_s1;
            cmp_s1<=compare_mode;cmp_s2<=cmp_s1;split_s1<=compare_split;split_s2<=split_s1;
            if((cx==10'd799)&&(cy==10'd524)) begin
                ex_display<=ex_s2;am_display<=am_s2;fl_display<=fl_s2;
                cmp_display<=cmp_s2;split_display<=split_s2;
                {width_display_bcd,height_display_bcd}<=resolution_s2;
            end
        end
    end

    // ---- E2 selected final effect: 32-level fade after OSD composition ----
    // Scaling the composed pixel makes the old metadata disappear before the
    // black-field swap; the new metadata then appears with the new picture.
    wire [13:0] fade_r=osd_layer_rgb[23:16]*fl_display;
    wire [13:0] fade_g=osd_layer_rgb[15:8]*fl_display;
    wire [13:0] fade_b=osd_layer_rgb[7:0]*fl_display;
    wire [23:0] faded_rgb={fade_r[12:5],fade_g[12:5],fade_b[12:5]};
    wire [23:0] compare_overlay_rgb;
    museum_compare_osd u_compare_osd(.clk(clk_pixel),.reset(video_reset),
        .x(cx),.y(cy),.frame_end(osd_frame_end),.enabled(cmp_display&&display_frame),
        .split(split_display),.diagnostic(osd_underflow),.base_rgb(faded_rgb),.rgb(compare_overlay_rgb));
    // Keep the magenta underflow diagnostic visible even during a transition.
    // Reserved inactive-row Lx=1023 marks video with the same line ownership.
    wire [23:0] transition_rgb=media_row?rgb:(osd_underflow?osd_layer_rgb:compare_overlay_rgb);
    // E5 observes exactly the sample accepted by the HDMI audio-clock edge.
    // This independent final layer stays visible while photographs fade.
    audio_waveform_osd u_wave(
        .audio_clk(clk_audio),.audio_reset(async_reset),
        .played_sample(audio_sample_word[0]),.played_mode(mode_a2?((audio_source_mode==4)?3'd4:3'd0):audio_source_mode),
        .pixel_clk(clk_pixel),.pixel_reset(video_reset),.pixel_x(cx),.pixel_y(cy),
        .display_enable(display_frame&&!media_row),.diagnostic(osd_underflow),
        .base_rgb(transition_rgb),.pixel_rgb(osd_rgb));

    // ---- True HDMI transmitter ----
    hdmi #(
        .VIDEO_ID_CODE(1),
        .VIDEO_REFRESH_RATE(60.0),
        .VIDEO_PIXEL_RATE(25.0E6),
        .AUDIO_RATE(48000),
        .AUDIO_BIT_WIDTH(16)
    ) u_hdmi(
        .clk_pixel_x5(clk_5x),
        .clk_pixel(clk_pixel),
        .clk_audio(clk_audio),
        .reset(video_reset),
        .rgb(osd_rgb),
        .audio_sample_word(audio_sample_word),
        .tmds({HDMI_D2_P,HDMI_D1_P,HDMI_D0_P}),
        .tmds_clock(HDMI_CLK_P),
        .cx(cx),.cy(cy),
        .frame_width(),.frame_height(),
        .screen_width(),.screen_height()
    );

    // ---- E1 OSD overlay ----
    osd_overlay u_osd(
        .pixel_clk(clk_pixel),.reset(video_reset),
        .pixel_x(cx),.pixel_y(cy),
        .base_rgb(image_osd_marked),.exhibit_id(ex_display),.auto_mode(am_display),.compare_mode(cmp_display),
        .brightness_level(brightness_level),.contrast_level(contrast_level),
        .adjust_hud_visible(adjust_hud_visible),
        .source_width_bcd(width_display_bcd),.source_height_bcd(height_display_bcd),
        .frame_end(osd_frame_end),.display_enable(display_frame),
        .underflow(osd_underflow),.osd_rgb(osd_layer_rgb)
    );
endmodule
