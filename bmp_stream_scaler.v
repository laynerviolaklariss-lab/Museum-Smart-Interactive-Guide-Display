`timescale 1ns/1ps
`include "tf_bmp_defs.vh"

// File-order input -> file-order 640x480 output. Only one source row is held.
// All coordinates and RAM contents are held during output backpressure.
// Bottom-up sampling uses ceil((j+1)*H/DH)-1, so the *displayed* result
// matches floor(y*H/DH), including odd-sized letterbox margins.
module bmp_stream_scaler(
    input wire clk,input wire rst,input wire start,
    input wire metadata_valid,input wire [31:0] src_width,src_height,
    input wire src_top_down,
    input wire in_valid,output wire in_ready,input wire [31:0] in_rgb,
    input wire line_start,line_end,
    output wire out_valid,input wire out_ready,output wire [31:0] out_rgb,
    output reg [18:0] out_count,output reg done,output reg error,
    output reg [7:0] error_code
);
    localparam IDLE=0,CONFIG=1,DIVIDE=2,PREP=3,YNORM=4,PAD=5,
        LOAD=6,CHECK=7,REQ=8,CAP=9,SEND=10,XSTEP=11,XNORM=12,
        ROW_END=13,YSTEP=14,ADV_IN=15,FINISH=16,BYPASS=17,STOP=18;
    reg [4:0] state;
    reg [9:0] w,h,dw,dh,left_pad,first_pad,last_pad;
    reg [9:0] last_input_x,last_input_y,last_output_y,right_edge,last_picture_x;
    reg top_down,wide;
    reg [20:0] w480,h640,div_rem;
    reg [9:0] div_den,div_q;
    reg [9:0] input_row,input_col,output_rows,output_x,source_x,source_y;
    reg [10:0] xerr,yerr;
    reg [9:0] pad_rows,pad_x;
    reg pad_final,initial_y;
    reg [31:0] pixel_hold;
    wire [31:0] row_q;
    wire take_in=in_valid&&in_ready;
    wire take_out=out_valid&&out_ready;
    assign in_ready=!error&&((state==LOAD)||((state==BYPASS)&&out_ready));
    assign out_valid=!error&&((state==SEND)||(state==PAD)||
                             ((state==BYPASS)&&in_valid));
    assign out_rgb=(state==BYPASS)?in_rgb:((state==PAD)?32'd0:pixel_hold);

    // Same BRAM primitive and register mode as the proven video line buffers.
    // CAP occurs one whole clock after REQ. Never use an asynchronous RAM mux.
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),
        .ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),
        .DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),
        .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
        .FORCE_KEEP("ON"),.INIT_FILE("NONE"),.FILL_ALL("NONE"),
        .IMPLEMENT("32K")
    ) u_source_row(
        .doa(),.dob(row_q),.dia(in_rgb),.dib(32'd0),
        .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(take_in&&(state==LOAD)),
        .rsta(1'b0),.bea(1'b0),.addra(input_col),
        .ceb(1'b1),.oceb(1'b1),.clkb(clk),.web(1'b0),
        .rstb(1'b0),.beb(1'b0),.addrb(source_x)
    );

    task fail;
        input [7:0] code;
        begin error<=1;error_code<=code;state<=STOP;end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;out_count<=0;done<=0;error<=0;error_code<=0;
            w<=0;h<=0;dw<=0;dh<=0;left_pad<=0;first_pad<=0;last_pad<=0;
            last_input_x<=0;last_input_y<=0;last_output_y<=0;right_edge<=0;last_picture_x<=0;
            top_down<=0;wide<=0;w480<=0;h640<=0;
            div_rem<=0;div_den<=0;div_q<=0;
            input_row<=0;input_col<=0;output_rows<=0;output_x<=0;
            source_x<=0;source_y<=0;xerr<=0;yerr<=0;
            pad_rows<=0;pad_x<=0;pad_final<=0;initial_y<=0;pixel_hold<=0;
        end else if(start) begin
            state<=IDLE;out_count<=0;done<=0;error<=0;error_code<=0;
            input_row<=0;input_col<=0;output_rows<=0;
            source_y<=0;source_x<=0;output_x<=0;xerr<=0;yerr<=0;
        end else begin
            if(take_out) out_count<=out_count+1'b1;
            case(state)
                IDLE: if(metadata_valid) begin
                    if(src_width==0||src_height==0||src_width>800||src_height>800)
                        fail(`ERR_SCALE_RANGE);
                    else begin
                        w<=src_width[9:0];h<=src_height[9:0];top_down<=src_top_down;
                        last_input_x<=src_width[9:0]-1'b1;last_input_y<=src_height[9:0]-1'b1;
                        state<=CONFIG;
                    end
                end
                CONFIG: begin
                    // Constant multiplies by shifts/adds, evaluated once per file.
                    w480<=({11'd0,w}<<9)-({11'd0,w}<<5);
                    h640<=({11'd0,h}<<9)+({11'd0,h}<<7);
                    if(w==640&&h==480)state<=BYPASS;
                    else state<=DIVIDE;
                    div_q<=0;div_den<=0;
                end
                DIVIDE: begin
                    // <=640 subtract cycles, avoiding a large combinational divider.
                    if(div_den==0) begin
                        wide<=w480>=h640;
                        div_rem<=(w480>=h640)?h640:w480;
                        div_den<=(w480>=h640)?w:h;
                    end else if(div_rem>=div_den) begin
                        div_rem<=div_rem-div_den;div_q<=div_q+1'b1;
                    end else begin
                        dw<=wide?10'd640:((div_q==0)?10'd1:div_q);
                        dh<=wide?((div_q==0)?10'd1:div_q):10'd480;
                        state<=PREP;
                    end
                end
                PREP: begin
                    left_pad<=(10'd640-dw)>>1;
                    right_edge<=((10'd640-dw)>>1)+dw;
                    last_picture_x<=((10'd640-dw)>>1)+dw-1'b1;
                    last_output_y<=dh-1'b1;
                    first_pad<=top_down?((10'd480-dh)>>1):
                                       (10'd480-dh-((10'd480-dh)>>1));
                    last_pad<=top_down?(10'd480-dh-((10'd480-dh)>>1)):
                                      ((10'd480-dh)>>1);
                    // Canonical top-origin nearest neighbour, even for bottom-up BMP.
                    yerr<=top_down?11'd0:({1'b0,h}-1'b1);
                    source_y<=0;initial_y<=1;state<=YNORM;
                end
                YNORM: begin
                    if(yerr>=dh) begin yerr<=yerr-dh;source_y<=source_y+1'b1;end
                    else if(initial_y) begin
                        initial_y<=0;pad_final<=0;pad_rows<=first_pad;pad_x<=0;
                        state<=(first_pad==0)?LOAD:PAD;
                    end else state<=CHECK;
                end
                PAD: if(take_out) begin
                    if(pad_x==639) begin
                        pad_x<=0;
                        if(pad_rows==1) state<=pad_final?FINISH:LOAD;
                        else pad_rows<=pad_rows-1'b1;
                    end else pad_x<=pad_x+1'b1;
                end
                LOAD: if(take_in) begin
                    if((line_start!=(input_col==0))||
                       (line_end!=(input_col==last_input_x)))fail(`ERR_SCALE_ROW_COUNT);
                    else if(input_col==last_input_x) begin input_col<=0;state<=CHECK;end
                    else input_col<=input_col+1'b1;
                end
                CHECK: begin
                    if(output_rows==dh||input_row<source_y) state<=ADV_IN;
                    else if(input_row==source_y) begin
                        output_x<=0;source_x<=0;xerr<=0;state<=REQ;
                    end else fail(`ERR_SCALE_STATE);
                end
                REQ: begin
                    if(output_x<left_pad||output_x>=right_edge) begin
                        pixel_hold<=0;state<=SEND;
                    end else if(source_x>=w)fail(`ERR_SCALE_RANGE);
                    else state<=CAP;
                end
                CAP: begin pixel_hold<=row_q;state<=SEND;end
                SEND: if(take_out) begin
                    if(output_x==639)state<=ROW_END;
                    else begin
                        output_x<=output_x+1'b1;
                        if(output_x>=left_pad&&output_x<last_picture_x)
                            state<=XSTEP;
                        else state<=REQ;
                    end
                end
                XSTEP: begin xerr<=xerr+{1'b0,w};state<=XNORM;end
                XNORM: begin
                    if(xerr>=dw)begin xerr<=xerr-dw;source_x<=source_x+1'b1;end
                    else state<=REQ;
                end
                ROW_END: begin
                    output_rows<=output_rows+1'b1;
                    if(output_rows==last_output_y)state<=ADV_IN;
                    else state<=YSTEP;
                end
                YSTEP: begin yerr<=yerr+{1'b0,h};state<=YNORM;end
                ADV_IN: begin
                    if(input_row==last_input_y) begin
                        if(output_rows!=dh)fail(`ERR_SCALE_OUT_COUNT);
                        else begin
                            pad_final<=1;pad_rows<=last_pad;pad_x<=0;
                            state<=(last_pad==0)?FINISH:PAD;
                        end
                    end else begin input_row<=input_row+1'b1;state<=LOAD;end
                end
                BYPASS: if(take_out) begin
                    if(out_count==19'd307199)state<=FINISH;
                end
                FINISH: begin
                    if(out_count!=19'd307200)fail(`ERR_SCALE_OUT_COUNT);
                    else begin done<=1;state<=STOP;end
                end
                STOP: state<=STOP;
                default:fail(`ERR_SCALE_STATE);
            endcase
        end
    end
endmodule
