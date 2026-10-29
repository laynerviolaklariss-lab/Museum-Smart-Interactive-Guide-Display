`timescale 1ns/1ps
`include "tf_bmp_defs.vh"

// SD v2 / SDHC SPI host. After card_ready, a one-cycle rd_req starts CMD17.
// The returned block is a 512-byte indexed stream followed by sector_done.
module sd_spi_host #(
    parameter integer POWERUP_CYCLES = 1000000, // 10ms at 100MHz
    parameter integer INIT_RETRY_MAX = 10000,
    parameter integer TOKEN_POLL_MAX = 65535
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rd_req,
    input  wire [31:0] rd_lba,
    output reg         card_ready,
    output reg         card_sdhc,
    output reg         rd_busy,
    output reg         data_valid,
    output reg  [8:0]  data_index,
    output reg  [7:0]  data_byte,
    output reg         sector_done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg  [7:0]  last_r1,
    output reg         sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso
);
    localparam [5:0] CMD0=0, CMD8=8, CMD16=16, CMD17=17,
                     CMD55=55, CMD58=58, ACMD41=41;
    localparam [5:0]
        ST_POWER=0, ST_DUMMY_REQ=1, ST_DUMMY_WAIT=2,
        ST_CMD0_START=3, ST_CMD0_WAIT=4,
        ST_CMD8_START=5, ST_CMD8_WAIT=6,
        ST_CMD55_START=7, ST_CMD55_WAIT=8,
        ST_ACMD41_START=9, ST_ACMD41_WAIT=10,
        ST_CMD58_START=11, ST_CMD58_WAIT=12,
        ST_CMD16_START=13, ST_CMD16_WAIT=14,
        ST_READY=15, ST_RD_CMD_START=16, ST_RD_CMD_WAIT=17,
        ST_TOKEN_REQ=18, ST_TOKEN_WAIT=19,
        ST_DATA_REQ=20, ST_DATA_WAIT=21,
        ST_CRC1_REQ=22, ST_CRC1_WAIT=23,
        ST_CRC2_REQ=24, ST_CRC2_WAIT=25,
        ST_RELEASE_REQ=26, ST_RELEASE_WAIT=27,
        ST_ERROR=28, ST_GAP_REQ=29, ST_GAP_WAIT=30;
    reg [5:0] state;
    reg [31:0] power_count;
    reg [3:0] dummy_count;
    reg [15:0] init_retry;
    reg [15:0] token_poll;
    reg [31:0] active_lba;
    reg [8:0] block_count;
    reg [15:0] crc16_calc;
    reg [15:0] crc16_recv;
    reg [5:0] after_gap_state;

    reg cmd_start;
    reg [5:0] cmd_index;
    reg [31:0] cmd_arg;
    reg [2:0] cmd_extra_len;
    wire cmd_busy,cmd_done,cmd_timeout;
    wire [7:0] cmd_r1;
    wire [31:0] cmd_extra_data;
    wire cmd_phy_start;
    wire [7:0] cmd_phy_tx;

    reg raw_start;
    reg [7:0] raw_tx;
    wire [7:0] phy_rx;
    wire phy_busy,phy_done;
    wire phy_start = cmd_busy ? cmd_phy_start : raw_start;
    wire [7:0] phy_tx = cmd_busy ? cmd_phy_tx : raw_tx;
    wire [15:0] spi_half_div = card_ready ? 16'd2 : 16'd125;

    spi_byte_master u_spi(
        .clk(clk),.rst(rst),.half_div(spi_half_div),.start(phy_start),
        .tx_data(phy_tx),.rx_data(phy_rx),.busy(phy_busy),.done(phy_done),
        .spi_sck(sd_sck),.spi_mosi(sd_mosi),.spi_miso(sd_miso));

    sd_cmd_engine u_cmd(
        .clk(clk),.rst(rst),.start(cmd_start),.cmd_index(cmd_index),
        .cmd_arg(cmd_arg),.extra_len(cmd_extra_len),.busy(cmd_busy),
        .done(cmd_done),.timeout(cmd_timeout),.r1(cmd_r1),
        .extra_data(cmd_extra_data),.phy_start(cmd_phy_start),
        .phy_tx(cmd_phy_tx),.phy_rx(phy_rx),.phy_busy(phy_busy),
        .phy_done(phy_done));

    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] value;
        integer i;
        reg [15:0] c;
        begin
            c=crc_in;
            for(i=7;i>=0;i=i-1) begin
                if(c[15]^value[i]) c={c[14:0],1'b0}^16'h1021;
                else c={c[14:0],1'b0};
            end
            crc16_byte=c;
        end
    endfunction

    task fail;
        input [7:0] code;
        begin
            error<=1'b1; error_code<=code; rd_busy<=1'b0;
            card_ready<=1'b0; sd_cs_n<=1'b1; state<=ST_ERROR;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=ST_POWER; power_count<=0; dummy_count<=0;
            init_retry<=0; token_poll<=0; active_lba<=0;
            card_ready<=0; card_sdhc<=0; rd_busy<=0;
            data_valid<=0; data_index<=0; data_byte<=0; sector_done<=0;
            error<=0; error_code<=`ERR_NONE; last_r1<=8'hFF;
            sd_cs_n<=1'b1; cmd_start<=0; cmd_index<=0; cmd_arg<=0;
            cmd_extra_len<=0; raw_start<=0; raw_tx<=8'hFF;
            crc16_calc<=0; crc16_recv<=0; block_count<=0;
            after_gap_state<=ST_ERROR;
        end else begin
            cmd_start<=1'b0; raw_start<=1'b0; data_valid<=1'b0;
            sector_done<=1'b0;
            case(state)
                ST_POWER: begin
                    sd_cs_n<=1'b1;
                    if(power_count==POWERUP_CYCLES-1) begin
                        power_count<=0; dummy_count<=0; state<=ST_DUMMY_REQ;
                    end else power_count<=power_count+1'b1;
                end
                ST_DUMMY_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_DUMMY_WAIT;
                end
                ST_DUMMY_WAIT: if(phy_done) begin
                    if(dummy_count==4'd9) begin sd_cs_n<=1'b0; state<=ST_CMD0_START; end
                    else begin dummy_count<=dummy_count+1'b1; state<=ST_DUMMY_REQ; end
                end
                ST_CMD0_START: if(!cmd_busy && !phy_busy) begin
                    sd_cs_n<=1'b0;
                    cmd_index<=CMD0; cmd_arg<=0; cmd_extra_len<=0;
                    cmd_start<=1'b1; state<=ST_CMD0_WAIT;
                end
                ST_CMD0_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout || cmd_r1!=8'h01) fail(`ERR_SD_CMD0);
                    else begin sd_cs_n<=1'b1; after_gap_state<=ST_CMD8_START; state<=ST_GAP_REQ; end
                end
                ST_CMD8_START: if(!cmd_busy && !phy_busy) begin
                    sd_cs_n<=1'b0;
                    cmd_index<=CMD8; cmd_arg<=32'h000001AA; cmd_extra_len<=4;
                    cmd_start<=1'b1; state<=ST_CMD8_WAIT;
                end
                ST_CMD8_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout || cmd_r1!=8'h01 || cmd_extra_data!=32'h000001AA)
                        fail(`ERR_SD_CMD8);
                    else begin sd_cs_n<=1'b1; after_gap_state<=ST_CMD55_START; state<=ST_GAP_REQ; end
                end
                ST_CMD55_START: if(!cmd_busy && !phy_busy) begin
                    sd_cs_n<=1'b0;
                    cmd_index<=CMD55; cmd_arg<=0; cmd_extra_len<=0;
                    cmd_start<=1'b1; state<=ST_CMD55_WAIT;
                end
                ST_CMD55_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout || (cmd_r1!=8'h01 && cmd_r1!=8'h00))
                        fail(`ERR_SD_ACMD41);
                    else begin sd_cs_n<=1'b1; after_gap_state<=ST_ACMD41_START; state<=ST_GAP_REQ; end
                end
                ST_ACMD41_START: if(!cmd_busy && !phy_busy) begin
                    sd_cs_n<=1'b0;
                    cmd_index<=ACMD41; cmd_arg<=32'h40000000; cmd_extra_len<=0;
                    cmd_start<=1'b1; state<=ST_ACMD41_WAIT;
                end
                ST_ACMD41_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout) fail(`ERR_SD_ACMD41);
                    else if(cmd_r1==8'h00) begin
                        sd_cs_n<=1'b1; after_gap_state<=ST_CMD58_START; state<=ST_GAP_REQ;
                    end
                    else if(cmd_r1!=8'h01 || init_retry==INIT_RETRY_MAX-1)
                        fail(`ERR_SD_ACMD41);
                    else begin
                        init_retry<=init_retry+1'b1; sd_cs_n<=1'b1;
                        after_gap_state<=ST_CMD55_START; state<=ST_GAP_REQ;
                    end
                end
                ST_CMD58_START: if(!cmd_busy && !phy_busy) begin
                    sd_cs_n<=1'b0;
                    cmd_index<=CMD58; cmd_arg<=0; cmd_extra_len<=4;
                    cmd_start<=1'b1; state<=ST_CMD58_WAIT;
                end
                ST_CMD58_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout || cmd_r1!=8'h00) fail(`ERR_SD_CMD58);
                    else begin
                        card_sdhc<=cmd_extra_data[30];
                        sd_cs_n<=1'b1;
                        if(cmd_extra_data[30]) begin
                            after_gap_state<=ST_READY; state<=ST_GAP_REQ;
                        end else begin after_gap_state<=ST_CMD16_START; state<=ST_GAP_REQ; end
                    end
                end
                ST_CMD16_START: if(!cmd_busy && !phy_busy) begin
                    sd_cs_n<=1'b0;
                    cmd_index<=CMD16; cmd_arg<=512; cmd_extra_len<=0;
                    cmd_start<=1'b1; state<=ST_CMD16_WAIT;
                end
                ST_CMD16_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout || cmd_r1!=8'h00) fail(`ERR_SD_CMD16);
                    else begin
                        sd_cs_n<=1'b1;
                        after_gap_state<=ST_READY; state<=ST_GAP_REQ;
                    end
                end
                ST_READY: begin
                    sd_cs_n<=1'b1; rd_busy<=1'b0;
                    if(rd_req) begin
                        active_lba<=rd_lba; rd_busy<=1'b1; sd_cs_n<=1'b0;
                        state<=ST_RD_CMD_START;
                    end
                end
                ST_RD_CMD_START: if(!cmd_busy && !phy_busy) begin
                    cmd_index<=CMD17;
                    cmd_arg<=card_sdhc ? active_lba : {active_lba[22:0],9'b0};
                    cmd_extra_len<=0; cmd_start<=1'b1; state<=ST_RD_CMD_WAIT;
                end
                ST_RD_CMD_WAIT: if(cmd_done) begin
                    last_r1<=cmd_r1;
                    if(cmd_timeout || cmd_r1!=8'h00) fail(`ERR_SD_CMD17);
                    else begin token_poll<=0; state<=ST_TOKEN_REQ; end
                end
                ST_TOKEN_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_TOKEN_WAIT;
                end
                ST_TOKEN_WAIT: if(phy_done) begin
                    if(phy_rx==8'hFE) begin
                        data_index<=0; block_count<=0; crc16_calc<=0; state<=ST_DATA_REQ;
                    end else if(phy_rx!=8'hFF || token_poll==TOKEN_POLL_MAX-1)
                        fail(`ERR_SD_TOKEN);
                    else begin token_poll<=token_poll+1'b1; state<=ST_TOKEN_REQ; end
                end
                ST_DATA_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if(phy_done) begin
                    data_byte<=phy_rx; data_index<=block_count; data_valid<=1'b1;
                    crc16_calc<=crc16_byte(crc16_calc,phy_rx);
                    if(block_count==9'd511) state<=ST_CRC1_REQ;
                    else begin block_count<=block_count+1'b1; state<=ST_DATA_REQ; end
                end
                ST_CRC1_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_CRC1_WAIT;
                end
                ST_CRC1_WAIT: if(phy_done) begin
                    crc16_recv[15:8]<=phy_rx; state<=ST_CRC2_REQ;
                end
                ST_CRC2_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_CRC2_WAIT;
                end
                ST_CRC2_WAIT: if(phy_done) begin
                    crc16_recv[7:0]<=phy_rx;
                    if(crc16_calc!={crc16_recv[15:8],phy_rx}) fail(`ERR_SD_DATA_CRC);
                    else begin sd_cs_n<=1'b1; state<=ST_RELEASE_REQ; end
                end
                ST_RELEASE_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_RELEASE_WAIT;
                end
                ST_RELEASE_WAIT: if(phy_done) begin
                    rd_busy<=1'b0; sector_done<=1'b1; state<=ST_READY;
                end
                ST_GAP_REQ: if(!phy_busy && !cmd_busy) begin
                    raw_tx<=8'hFF; raw_start<=1'b1; state<=ST_GAP_WAIT;
                end
                ST_GAP_WAIT: if(phy_done) begin
                    if(after_gap_state==ST_READY) card_ready<=1'b1;
                    state<=after_gap_state;
                end
                ST_ERROR: begin sd_cs_n<=1'b1; rd_busy<=1'b0; end
                default: fail(`ERR_SD_CMD_TIMEOUT);
            endcase
        end
    end
endmodule
