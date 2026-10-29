`timescale 1ns/1ps
// E1 final OSD: fixed exhibit metadata, 50% alpha panel, smooth ticker,
// and a transparent 64x64 Anlogic logo generated in FPGA logic.
// All counters and visible state change only at a frame boundary.
module osd_overlay(
    input  wire        pixel_clk,
    input  wire        reset,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire [23:0] base_rgb,
    input  wire [2:0]  exhibit_id,
    input  wire        compare_mode,
    input  wire        auto_mode,
    input  wire [11:0] source_width_bcd,
    input  wire [11:0] source_height_bcd,
    input  wire signed [7:0] brightness_level,
    input  wire [6:0] contrast_level,
    input  wire adjust_hud_visible,
    input  wire        frame_end,
    input  wire        display_enable,
    input  wire        underflow,
    output wire [23:0] osd_rgb
);
    localparam [10:0] SCROLL_GAP=11'd640;
    reg [10:0] scroll_offset;
    reg [1:0]  scroll_div;
    reg [2:0]  last_exhibit;

    wire [5:0] ticker_length=6'd48;
    wire [10:0] ticker_limit=SCROLL_GAP+({5'd0,ticker_length}<<4);
    always @(posedge pixel_clk or posedge reset) begin
        if(reset) begin scroll_offset<=0; scroll_div<=0; last_exhibit<=0; end
        else if(exhibit_id!=last_exhibit) begin
            last_exhibit<=exhibit_id; scroll_offset<=0; scroll_div<=0;
        end else if(frame_end) begin
            if(scroll_div==2'd2) begin
                scroll_div<=0;
                if(scroll_offset>=ticker_limit) scroll_offset<=0;
                else scroll_offset<=scroll_offset+1'b1;
            end else scroll_div<=scroll_div+1'b1;
        end
    end

    wire in_panel=display_enable&&(pixel_x<10'd640)&&
                  (pixel_y>=10'd384)&&(pixel_y<10'd480);
    wire in_title=in_panel&&(pixel_x>=10'd16)&&(pixel_x<10'd624)&&
                  (pixel_y>=10'd392)&&(pixel_y<10'd408);
    wire in_meta=in_panel&&(pixel_x>=10'd16)&&(pixel_x<10'd624)&&
                 (pixel_y>=10'd416)&&(pixel_y<10'd432);
    wire in_status=display_enable&&(pixel_x>=10'd480)&&(pixel_x<10'd624)&&
                   (pixel_y>=10'd16)&&(pixel_y<10'd32);
    wire [9:0] text_x=(pixel_x==799)?10'd0:pixel_x+10'd1;
    wire [9:0] text_y=(pixel_x==799)?((pixel_y==524)?10'd0:pixel_y+10'd1):pixel_y;
    wire next_compare_after=display_enable&&compare_mode&&text_x>=336&&text_x<384&&text_y>=16&&text_y<32;
    wire next_compare_before=display_enable&&compare_mode&&text_x>=96&&text_x<144&&text_y>=16&&text_y<32;
    wire next_compare_label=next_compare_before||next_compare_after;
    wire compare_before=display_enable&&compare_mode&&pixel_x>=96&&pixel_x<144&&pixel_y>=16&&pixel_y<32;
    wire compare_after=display_enable&&compare_mode&&pixel_x>=336&&pixel_x<384&&pixel_y>=16&&pixel_y<32;
    wire compare_label=compare_before||compare_after;
    wire [1:0] compare_index=next_compare_after?(text_x-336)>>4:(text_x-96)>>4;
    wire [7:0] compare_glyph;
    museum_compare_labels u_compare_labels(.after_label(next_compare_after),.index(compare_index),.glyph(compare_glyph));
    wire in_ticker=in_panel&&(pixel_y>=10'd448)&&(pixel_y<10'd464);
    // Beneath the existing manual/auto status: 11 fixed 16x16 cells.
    // SRC means source BMP resolution, not the fixed HDMI output canvas.
    wire in_resolution=display_enable&&(pixel_x>=10'd448)&&(pixel_x<10'd624)&&
                       (pixel_y>=10'd40)&&(pixel_y<10'd56);
    wire in_resolution_panel=display_enable&&(pixel_x>=10'd444)&&(pixel_x<10'd628)&&
                             (pixel_y>=10'd36)&&(pixel_y<10'd60);
    // E4 bounded continuous controls; B signed offset, C rounded gain percent.
    wire in_adjust=display_enable&&adjust_hud_visible&&
                   (pixel_x>=10'd512)&&(pixel_x<10'd608)&&
                   (pixel_y>=10'd64)&&(pixel_y<10'd72);
    wire in_adjust_panel=display_enable&&adjust_hud_visible&&
                         (pixel_x>=10'd508)&&(pixel_x<10'd628)&&
                         (pixel_y>=10'd60)&&(pixel_y<10'd84);

    // The logo is a true OSD layer, not painted into the source BMP.  Its ROM
    // contains two colour masks; all other pixels remain transparent.
    wire in_logo=display_enable&&(pixel_x>=10'd16)&&(pixel_x<10'd80)&&
                 (pixel_y>=10'd16)&&(pixel_y<10'd80);
    wire logo_valid_raw;
    wire [23:0] logo_rgb;
    anlogic_logo_rom u_logo(
        .x(pixel_x-10'd16),.y(pixel_y-10'd16),
        .pixel_valid(logo_valid_raw),.pixel_rgb(logo_rgb)
    );
    wire logo_pixel=in_logo&&logo_valid_raw;

    wire next_title=display_enable&&text_x>=16&&text_x<624&&text_y>=392&&text_y<408;
    wire next_meta=display_enable&&text_x>=16&&text_x<624&&text_y>=416&&text_y<432;
    wire next_status=display_enable&&text_x>=480&&text_x<624&&text_y>=16&&text_y<32;
    wire next_ticker=display_enable&&text_x<640&&text_y>=448&&text_y<464;
    wire [10:0] ticker_source={1'b0,text_x}+scroll_offset;
    wire ticker_has_source=(ticker_source>=SCROLL_GAP)&&
                           (ticker_source<ticker_limit);
    wire [10:0] ticker_dx=ticker_source-SCROLL_GAP;

    reg [1:0] text_line;
    reg [5:0] char_index;
    reg [3:0] glyph_row,glyph_col;
    reg       text_region;
    always @(*) begin
        text_line=0; char_index=0; glyph_row=0; glyph_col=0;
        text_region=1'b0;
        if(next_compare_label) begin
            text_region=1'b1;glyph_row=text_y[3:0];glyph_col=text_x[3:0];
        end else if(next_title) begin
            text_region=1'b1; text_line=2'd0;
            char_index=(text_x-10'd16)>>4;
            glyph_row=text_y-10'd392; glyph_col=text_x[3:0];
        end else if(next_meta) begin
            text_region=1'b1; text_line=2'd1;
            char_index=(text_x-10'd16)>>4;
            glyph_row=text_y-10'd416; glyph_col=text_x[3:0];
        end else if(next_status) begin
            text_region=1'b1; text_line=2'd3;
            char_index=(text_x-10'd480)>>4;
            glyph_row=text_y-10'd16; glyph_col=text_x[3:0];
        end else if(next_ticker&&ticker_has_source) begin
            text_region=1'b1; text_line=2'd2;
            char_index=ticker_dx>>4;
            glyph_row=text_y-10'd448; glyph_col=ticker_dx[3:0];
        end
    end

    wire [7:0] glyph_id;
    wire char_valid;
    wire [5:0] line_length;
    osd_text_rom u_text(
        .exhibit_id(exhibit_id),.auto_mode(auto_mode),.compare_mode(compare_mode),
        .text_line(text_line),.char_index(char_index),
        .glyph_id(glyph_id),.char_valid(char_valid),.line_length(line_length)
    );
    wire [15:0] glyph_bits;
    wire [3:0] resolution_char_index=(pixel_x-10'd448)>>4;
    reg [7:0] resolution_glyph;
    always @(*) begin
        case(resolution_char_index)
            0:resolution_glyph=8'd83;  // S
            1:resolution_glyph=8'd82;  // R
            2:resolution_glyph=8'd67;  // C
            3:resolution_glyph=8'd32;
            4:resolution_glyph=(source_width_bcd[11:8]==0)?8'd32:
                8'd48+{4'd0,source_width_bcd[11:8]};
            5:resolution_glyph=(source_width_bcd[11:4]==0)?8'd32:
                8'd48+{4'd0,source_width_bcd[7:4]};
            6:resolution_glyph=8'd48+{4'd0,source_width_bcd[3:0]};
            7:resolution_glyph=8'd120; // x
            8:resolution_glyph=(source_height_bcd[11:8]==0)?8'd32:
                8'd48+{4'd0,source_height_bcd[11:8]};
            9:resolution_glyph=(source_height_bcd[11:4]==0)?8'd32:
                8'd48+{4'd0,source_height_bcd[7:4]};
            10:resolution_glyph=8'd48+{4'd0,source_height_bcd[3:0]};
            default:resolution_glyph=8'd32;
        endcase
    end
    osd_font16x16_bram u_font(
        .clk(pixel_clk),
        .glyph_id(next_compare_label?compare_glyph:glyph_id),
        .row_index(glyph_row),.row_bits(glyph_bits)
    );
    // Keep the original Chinese OSD font/address path untouched. The short
    // resolution line has a separate, small combinational ASCII bitmap.
    reg [255:0] resolution_bitmap;
    // 12 small cells, no changes to the BMP or Chinese text pipeline.
    reg [7:0] adjust_glyph;
    wire [3:0] adjust_char_index=(pixel_x-10'd512)>>3;
    wire [7:0] bright_abs=brightness_level[7]?(~brightness_level+8'd1):brightness_level;
    wire [13:0] percent_scaled=contrast_level*14'd100+14'd32;
    wire [7:0] percent=percent_scaled[13:6];
    wire [7:0] b_tens=bright_abs/8'd10,b_ones=bright_abs%8'd10;
    wire [7:0] c_hundreds=percent/8'd100,c_tens=(percent/8'd10)%8'd10,c_ones=percent%8'd10;
    always @(*) begin
        case(adjust_char_index)
            0:adjust_glyph=8'd66;
            1,7:adjust_glyph=8'd58;
            2:adjust_glyph=brightness_level[7]?8'd45:8'd43;
            3:adjust_glyph=8'd48+b_tens;
            4:adjust_glyph=8'd48+b_ones;
            6:adjust_glyph=8'd67;
            8:adjust_glyph=8'd48+c_hundreds;
            9:adjust_glyph=8'd48+c_tens;
            10:adjust_glyph=8'd48+c_ones;
            11:adjust_glyph=8'd37;
            default:adjust_glyph=8'd32;
        endcase
    end
    wire [7:0] adjust_bits;
    audio_wave_font u_adjust_font(adjust_glyph,pixel_y[2:0],adjust_bits);
    wire adjust_pixel=in_adjust&&adjust_bits[3'd7-pixel_x[2:0]];
    wire [7:0] ascii_glyph=resolution_glyph;
    always @(*) begin
        case(ascii_glyph)
            8'd58: resolution_bitmap=256'h0000000000000000000000001800180000000000180018000000000000000000;
            8'd66: resolution_bitmap=256'h00007c0066004200420066007c0066004200420066007c000000000000000000;
            8'd48: resolution_bitmap=256'h00003c00640042004200420042004200420046002c0018000000000000000000;
            8'd49: resolution_bitmap=256'h0000080018007800580018001800180018001800180018000000000000000000;
            8'd50: resolution_bitmap=256'h00003c0066004200060004000c000800100020007e007e000000000000000000;
            8'd51: resolution_bitmap=256'h00003c006600420006000c000c00060002004200640018000000000000000000;
            8'd52: resolution_bitmap=256'h000004000c001c001400240064004400ff000400040004000000000000000000;
            8'd53: resolution_bitmap=256'h00007e007e00400040007c007e0002000200420066003c000000000000000000;
            8'd54: resolution_bitmap=256'h00001c003000600040007c00660042004200420066003c000000000000000000;
            8'd55: resolution_bitmap=256'h00007e007e00020004000c000800100010002000200020000000000000000000;
            8'd56: resolution_bitmap=256'h00003c006600420042003c00660042004200420066003c000000000000000000;
            8'd57: resolution_bitmap=256'h00003c0066004200420066003e00020006000c00180030000000000000000000;
            8'd67: resolution_bitmap=256'h00003c006600420040004000400040004000420066003c000000000000000000;
            8'd82: resolution_bitmap=256'h00007c0066004200420066007c00480044004600420042000000000000000000;
            8'd83: resolution_bitmap=256'h00003c0066004600600030001c0006004200420066003c000000000000000000;
            8'd120:resolution_bitmap=256'h0000000000000000420024001800180024004200000000000000000000000000;
            default:resolution_bitmap=256'd0;
        endcase
    end
    wire [3:0] resolution_row=pixel_y[3:0]-4'd8;
    wire [7:0] resolution_bit_index={~resolution_row,~pixel_x[3:0]};
    wire resolution_pixel=(in_resolution&&resolution_bitmap[resolution_bit_index])||adjust_pixel;
    reg shown_text_region,shown_char_valid;
    reg [3:0] shown_glyph_col;reg [1:0] shown_text_line;
    always @(posedge pixel_clk or posedge reset)begin
        if(reset)begin shown_text_region<=0;shown_char_valid<=0;shown_glyph_col<=0;shown_text_line<=0;end
        else begin shown_text_region<=text_region;shown_char_valid<=next_compare_label||char_valid;
            shown_glyph_col<=glyph_col;shown_text_line<=text_line;end
    end
    wire text_pixel=shown_text_region&&shown_char_valid&&glyph_bits[4'd15-shown_glyph_col];

    wire [23:0] panel_rgb={1'b0,base_rgb[23:17],1'b0,base_rgb[15:9],
                           1'b0,base_rgb[7:1]};
    wire [23:0] text_color=in_resolution?24'h80e0ff:(shown_text_line==2'd3&&auto_mode)
                         ? 24'h40ff80 : 24'hfff0b0;
    assign osd_rgb=underflow ? base_rgb :
                   resolution_pixel ? 24'h80e0ff :
                   text_pixel ? text_color :
                   logo_pixel ? logo_rgb :
                   (in_panel||in_resolution_panel||in_adjust_panel||compare_label) ? panel_rgb : base_rgb;
endmodule
