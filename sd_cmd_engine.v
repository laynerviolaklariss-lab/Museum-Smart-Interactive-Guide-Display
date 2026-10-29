`timescale 1ns/1ps

// Sends one six-byte SD command and waits for an R1 response. Up to four
// additional response bytes can be collected for R3/R7. CS is controlled by
// the caller and must already be low before start is asserted.
module sd_cmd_engine #(
    parameter integer R1_POLL_LIMIT = 1024
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [5:0]  cmd_index,
    input  wire [31:0] cmd_arg,
    input  wire [2:0]  extra_len,
    output reg         busy,
    output reg         done,
    output reg         timeout,
    output reg  [7:0]  r1,
    output reg  [31:0] extra_data,

    output reg         phy_start,
    output reg  [7:0]  phy_tx,
    input  wire [7:0]  phy_rx,
    input  wire        phy_busy,
    input  wire        phy_done
);
    localparam ST_IDLE=3'd0, ST_SEND_REQ=3'd1, ST_SEND_WAIT=3'd2,
               ST_R1_REQ=3'd3, ST_R1_WAIT=3'd4,
               ST_EXT_REQ=3'd5, ST_EXT_WAIT=3'd6, ST_DONE=3'd7;
    reg [2:0] state;
    reg [2:0] byte_no;
    reg [2:0] ext_count;
    reg [15:0] poll_count;
    reg [7:0] crc_byte;

    function [6:0] crc7_40;
        input [39:0] value;
        integer i;
        reg [6:0] c;
        reg feedback;
        begin
            c = 7'd0;
            for (i=39; i>=0; i=i-1) begin
                feedback = value[i] ^ c[6];
                c = {c[5:0],1'b0};
                if (feedback) c = c ^ 7'h09;
            end
            crc7_40 = c;
        end
    endfunction

    function [7:0] command_byte;
        input [2:0] index;
        input [5:0] ci;
        input [31:0] ca;
        input [7:0] cc;
        begin
            case(index)
                3'd0: command_byte = {2'b01,ci};
                3'd1: command_byte = ca[31:24];
                3'd2: command_byte = ca[23:16];
                3'd3: command_byte = ca[15:8];
                3'd4: command_byte = ca[7:0];
                default: command_byte = cc;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=ST_IDLE; busy<=0; done<=0; timeout<=0; r1<=8'hFF;
            extra_data<=0; phy_start<=0; phy_tx<=8'hFF; byte_no<=0;
            ext_count<=0; poll_count<=0; crc_byte<=8'h01;
        end else begin
            done <= 1'b0;
            phy_start <= 1'b0;
            case(state)
                ST_IDLE: if(start) begin
                    busy<=1'b1; timeout<=1'b0; r1<=8'hFF;
                    extra_data<=0; byte_no<=0; ext_count<=0; poll_count<=0;
                    crc_byte<={crc7_40({2'b01,cmd_index,cmd_arg}),1'b1};
                    state<=ST_SEND_REQ;
                end
                ST_SEND_REQ: if(!phy_busy) begin
                    phy_tx<=command_byte(byte_no,cmd_index,cmd_arg,crc_byte);
                    phy_start<=1'b1; state<=ST_SEND_WAIT;
                end
                ST_SEND_WAIT: if(phy_done) begin
                    if(byte_no==3'd5) state<=ST_R1_REQ;
                    else begin byte_no<=byte_no+1'b1; state<=ST_SEND_REQ; end
                end
                ST_R1_REQ: if(!phy_busy) begin
                    phy_tx<=8'hFF; phy_start<=1'b1; state<=ST_R1_WAIT;
                end
                ST_R1_WAIT: if(phy_done) begin
                    if(!phy_rx[7]) begin
                        r1<=phy_rx;
                        if(extra_len==0) state<=ST_DONE;
                        else begin ext_count<=0; state<=ST_EXT_REQ; end
                    end else if(poll_count==R1_POLL_LIMIT-1) begin
                        timeout<=1'b1; state<=ST_DONE;
                    end else begin poll_count<=poll_count+1'b1; state<=ST_R1_REQ; end
                end
                ST_EXT_REQ: if(!phy_busy) begin
                    phy_tx<=8'hFF; phy_start<=1'b1; state<=ST_EXT_WAIT;
                end
                ST_EXT_WAIT: if(phy_done) begin
                    extra_data<={extra_data[23:0],phy_rx};
                    if(ext_count+1'b1==extra_len) state<=ST_DONE;
                    else begin ext_count<=ext_count+1'b1; state<=ST_EXT_REQ; end
                end
                ST_DONE: begin busy<=1'b0; done<=1'b1; state<=ST_IDLE; end
                default: state<=ST_IDLE;
            endcase
        end
    end
endmodule
