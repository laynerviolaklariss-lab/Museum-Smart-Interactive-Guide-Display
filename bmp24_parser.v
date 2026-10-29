`timescale 1ns/1ps
`include "tf_bmp_defs.vh"

// Streaming 24-bit BI_RGB BMP parser. Input bytes are the complete file in
// ascending file-offset order. Output coordinates are always top-origin even
// when a conventional positive-height BMP stores bottom rows first.
module bmp24_parser #(parameter integer MAX_IMAGE_DIM=0)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] file_size,
    input  wire [31:0] slot_capacity_pixels,
    input  wire        byte_valid,
    output wire        byte_ready,
    input  wire [7:0]  byte_data,
    output wire        pixel_valid,
    input  wire        pixel_ready,
    output wire [31:0] pixel_rgb,
    output wire [31:0] pixel_x,
    output wire [31:0] pixel_y,
    output wire        line_start,
    output wire        line_end,
    output reg         frame_done,
    output reg         busy,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         metadata_valid,
    output reg  [31:0] image_width,
    output reg  [31:0] image_height,
    output reg         image_top_down,
    output reg  [31:0] pixel_offset,
    output reg  [31:0] pixel_count
);
    localparam S_IDLE=0,S_HEADER=1,S_CAPTURE=2,S_STRIDE=3,
               S_MUL_BYTES_INIT=4,S_MUL_BYTES=5,S_MUL_COUNT=6,S_END=7,
               S_CHECK=8,S_SKIP=9,S_PIXELS=10,S_DONE=11,S_ERROR=12,S_ACCEPT=13,S_END_HIGH=14;
    reg [3:0] state;
    reg [7:0] header[0:53];
    reg [6:0] header_count;
    reg [31:0] stream_offset;
    // Default keeps the general 32-bit interface. The museum top already
    // rejects dimensions above 800; size only its active pixel counters.
    localparam integer XY_BITS=(MAX_IMAGE_DIM>0)?$clog2(MAX_IMAGE_DIM+1):32;
    reg [XY_BITS-1:0] file_row,x_count,last_pixel_x,last_file_y;
    reg [31:0] last_skip_byte;
    reg [19:0] last_row_byte;
    // slot_capacity_pixels bounds width to <=307200, therefore a padded
    // 24-bit row is at most 921600 bytes and fits in 20 bits.
    reg [19:0] row_byte,row_stride,pixel_data_bytes;
    reg height_negative;
    reg row_active;
    reg [1:0] color_phase;
    reg [7:0] blue_byte,green_byte;

    function [15:0] hle16;
        input integer a;
        begin hle16={header[a+1],header[a]}; end
    endfunction
    function [31:0] hle32;
        input integer a;
        begin hle32={header[a+3],header[a+2],header[a+1],header[a]}; end
    endfunction

    wire consuming_pixel_byte = state==S_PIXELS && row_active;
    wire is_red_byte = consuming_pixel_byte && color_phase==2;
    assign byte_ready = (state==S_HEADER || state==S_SKIP) ? 1'b1 :
                        (state==S_PIXELS ? (!is_red_byte || pixel_ready) : 1'b0);
    assign pixel_valid = state==S_PIXELS && byte_valid && is_red_byte;
    assign pixel_rgb = {8'h00,byte_data,green_byte,blue_byte};
    assign pixel_x = x_count;
    wire [XY_BITS-1:0] logical_y=last_file_y-file_row;
    assign pixel_y = height_negative ? file_row : logical_y;
    assign line_start = pixel_valid && x_count==0;
    assign line_end = pixel_valid && x_count==last_pixel_x;
    wire byte_take = byte_valid && byte_ready;

    task fail;
        input [7:0] code;
        begin error<=1'b1; error_code<=code; busy<=1'b0; state<=S_ERROR; end
    endtask

    reg signed [31:0] signed_width,signed_height;
    reg [31:0] abs_height_calc,width_calc,off_calc,bf_size_calc;
    reg [63:0] stride_calc,pixel_bytes_calc,end_calc;
    reg [63:0] mul_accum,mul_multiplicand;
    // The final count product stays in the accumulator through S_CHECK;
    // reuse that stable result instead of copying another 64-bit register.
    wire [63:0] count_calc=mul_accum;
    reg [31:0] mul_multiplier;
    reg [5:0] mul_count;
    // Header validation is latency-insensitive. Four 16-bit add phases
    // retain full 64-bit overflow/error semantics without a 64-bit carry path.
    reg [1:0] mul_part;reg mul_carry,end_carry;
    wire [63:0] mul_operand=mul_multiplier[0]?mul_multiplicand:64'd0;
    wire [16:0] mul_p0={1'b0,mul_accum[15:0]}+{1'b0,mul_operand[15:0]};
    wire [16:0] mul_p1={1'b0,mul_accum[31:16]}+{1'b0,mul_operand[31:16]}+mul_carry;
    wire [16:0] mul_p2={1'b0,mul_accum[47:32]}+{1'b0,mul_operand[47:32]}+mul_carry;
    wire [16:0] mul_p3={1'b0,mul_accum[63:48]}+{1'b0,mul_operand[63:48]}+mul_carry;
    wire [63:0] mul_result={mul_p3[15:0],mul_accum[47:0]};
    wire [32:0] end_low={1'b0,off_calc}+{1'b0,pixel_bytes_calc[31:0]};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            last_pixel_x<=0;last_file_y<=0;last_skip_byte<=0;last_row_byte<=0;
            state<=S_IDLE; header_count<=0; stream_offset<=0; file_row<=0;
            row_byte<=0; x_count<=0; row_stride<=0; pixel_data_bytes<=0;
            height_negative<=0; color_phase<=0; blue_byte<=0; green_byte<=0;
            row_active<=1;
            frame_done<=0; busy<=0; error<=0; error_code<=`ERR_NONE;
            metadata_valid<=0;
            image_width<=0; image_height<=0; image_top_down<=0; pixel_offset<=0; pixel_count<=0;
            signed_width<=0; signed_height<=0; abs_height_calc<=0;
            width_calc<=0; off_calc<=0; bf_size_calc<=0; stride_calc<=0;
            pixel_bytes_calc<=0; end_calc<=0;
            mul_accum<=0;mul_multiplicand<=0;mul_multiplier<=0;mul_count<=0;mul_part<=0;mul_carry<=0;end_carry<=0;
        end else begin
            frame_done<=1'b0;
            case(state)
                S_IDLE: if(start) begin
                    header_count<=0; stream_offset<=0; file_row<=0; row_byte<=0;
                    x_count<=0; color_phase<=0; row_active<=1; pixel_count<=0; busy<=1;
                    error<=0; error_code<=`ERR_NONE; metadata_valid<=0; state<=S_HEADER;
                end
                S_HEADER: if(byte_take) begin
                    header[header_count]<=byte_data;
                    stream_offset<=stream_offset+1'b1;
                    if(header_count==53) state<=S_CAPTURE;
                    else header_count<=header_count+1'b1;
                end
                S_CAPTURE: begin
                    if(header[0]!="B" || header[1]!="M") fail(`ERR_BMP_MAGIC);
                    else if(hle32(14)<40 || hle32(10)<54) fail(`ERR_BMP_DIB);
                    else if(hle16(26)!=1) fail(`ERR_BMP_PLANES);
                    else if(hle16(28)!=24) fail(`ERR_BMP_DEPTH);
                    else if(hle32(30)!=0) fail(`ERR_BMP_COMPRESSED);
                    else if($signed(hle32(18))<=0 || $signed(hle32(22))==0 ||
                            hle32(22)==32'h80000000)
                        fail(`ERR_BMP_SIZE);
                    else begin
                        signed_width<=$signed(hle32(18));signed_height<=$signed(hle32(22));
                        width_calc<=hle32(18);off_calc<=hle32(10);bf_size_calc<=hle32(2);
                        abs_height_calc<=$signed(hle32(22))<0 ? -$signed(hle32(22)) : hle32(22);
                        state<=S_STRIDE;
                    end
                end
                S_STRIDE: begin
                    stride_calc<=({32'd0,width_calc}+({32'd0,width_calc}<<1)+3)&
                                 64'hFFFFFFFFFFFFFFFC;
                    state<=S_MUL_BYTES_INIT;
                end
                S_MUL_BYTES_INIT: begin
                    mul_accum<=0;mul_multiplicand<=stride_calc;
                    mul_multiplier<=abs_height_calc;mul_count<=0;mul_part<=0;state<=S_MUL_BYTES;
                end
                S_MUL_BYTES,S_MUL_COUNT: begin
                    case(mul_part)
                        0:begin mul_accum[15:0]<=mul_p0[15:0];mul_carry<=mul_p0[16];mul_part<=1;end
                        1:begin mul_accum[31:16]<=mul_p1[15:0];mul_carry<=mul_p1[16];mul_part<=2;end
                        2:begin mul_accum[47:32]<=mul_p2[15:0];mul_carry<=mul_p2[16];mul_part<=3;end
                        3:begin
                            mul_accum[63:48]<=mul_p3[15:0];mul_part<=0;
                            mul_multiplicand<=mul_multiplicand<<1;mul_multiplier<=mul_multiplier>>1;
                            if(mul_count==31)begin
                                if(state==S_MUL_BYTES)begin
                                    pixel_bytes_calc<=mul_result;mul_accum<=0;
                                    mul_multiplicand<={32'd0,width_calc};mul_multiplier<=abs_height_calc;
                                    mul_count<=0;state<=S_MUL_COUNT;
                                end else begin state<=S_END;end
                            end else mul_count<=mul_count+1'b1;
                        end
                    endcase
                end
                S_END:begin end_calc[31:0]<=end_low[31:0];end_carry<=end_low[32];state<=S_END_HIGH;end
                S_END_HIGH:begin end_calc[63:32]<=pixel_bytes_calc[63:32]+end_carry;state<=S_CHECK;end
                S_CHECK: begin
                    if(stride_calc>32'hFFFFFFFF || count_calc>slot_capacity_pixels)
                        fail(`ERR_BMP_SIZE);
                    else if(end_calc>file_size || end_calc>32'hFFFFFFFF ||
                            (bf_size_calc!=0 && (end_calc>bf_size_calc || bf_size_calc>file_size)))
                        fail(`ERR_BMP_TRUNCATED);
                    else if(MAX_IMAGE_DIM>0&&(width_calc>MAX_IMAGE_DIM||abs_height_calc>MAX_IMAGE_DIM))
                        fail(`ERR_SCALE_RANGE);
                    else state<=S_ACCEPT;
                end
                // Keep the wide file-boundary comparisons above out of the
                // pixel-state control cone.  This extra setup cycle is hidden
                // by SD-card latency and materially improves 100 MHz timing.
                S_ACCEPT: begin
                        image_width<=width_calc[XY_BITS-1:0]; image_height<=abs_height_calc[XY_BITS-1:0];
                        last_pixel_x<=width_calc[XY_BITS-1:0]-1'b1;last_file_y<=abs_height_calc[XY_BITS-1:0]-1'b1;
                        last_skip_byte<=off_calc-1'b1;last_row_byte<=stride_calc[19:0]-1'b1;
                        metadata_valid<=1;
                        height_negative<=(signed_height<0); pixel_offset<=off_calc;
                        image_top_down<=(signed_height<0);
                        row_stride<=stride_calc[19:0];
                        pixel_data_bytes<=width_calc+(width_calc<<1);
                        file_row<=0; row_byte<=0; x_count<=0; color_phase<=0;row_active<=1;
                        if(off_calc==54) state<=S_PIXELS; else state<=S_SKIP;
                end
                S_SKIP: if(byte_take) begin
                    stream_offset<=stream_offset+1'b1;
                    if(stream_offset==last_skip_byte) state<=S_PIXELS;
                end
                S_PIXELS: if(byte_take) begin
                    stream_offset<=stream_offset+1'b1;
                    if(row_active) begin
                        case(color_phase)
                            0: begin blue_byte<=byte_data; color_phase<=1; end
                            1: begin green_byte<=byte_data; color_phase<=2; end
                            default: begin
                                color_phase<=0; pixel_count<=pixel_count+1'b1;
                                if(x_count==last_pixel_x) begin
                                    x_count<=0;row_active<=0;
                                end
                                else x_count<=x_count+1'b1;
                            end
                        endcase
                    end
                    if(row_byte==last_row_byte) begin
                        // x_count and color_phase already return to zero on
                        // the last red byte of every valid row.  Do not drive
                        // them again from the row-stride comparator: keeping
                        // these counters independent removes a long 100 MHz
                        // control path, including for padded BMP rows.
                        row_byte<=0;row_active<=1;
                        if(file_row==last_file_y) begin
                            busy<=0; frame_done<=1; state<=S_DONE;
                        end else file_row<=file_row+1'b1;
                    end else row_byte<=row_byte+1'b1;
                end
                // Re-arm the parser for IMG0002/3/4 without a global reset.
                S_DONE: if(start) begin
                    header_count<=0;stream_offset<=0;file_row<=0;row_byte<=0;
                    x_count<=0;color_phase<=0;row_active<=1;pixel_count<=0;busy<=1;
                    error<=0;error_code<=`ERR_NONE;metadata_valid<=0;state<=S_HEADER;
                end
                S_ERROR: state<=S_ERROR;
                default: fail(`ERR_BMP_DIB);
            endcase
        end
    end
endmodule

