`timescale 1ns/1ps
`include "tf_bmp_defs.vh"

module fat32_file_stream #(parameter USE_BRAM=0)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        abort,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] max_cluster,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    output reg         sec_req,
    output reg  [31:0] sec_lba,
    input  wire        sec_busy,
    input  wire        sec_data_valid,
    input  wire [8:0]  sec_data_index,
    input  wire [7:0]  sec_data_byte,
    input  wire        sec_done,
    input  wire        sec_error,
    output wire        byte_valid,
    input  wire        byte_ready,
    output wire [7:0]  byte_data,
    output reg  [31:0] file_offset,
    output wire        file_last,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [7:0]  error_code
);
    localparam S_IDLE=0,S_DATA_REQ=1,S_DATA_WAIT=2,S_STREAM=3,
               S_FAT_REQ=4,S_FAT_WAIT=5,S_FAT_PARSE=6,S_DONE=7,S_ERROR=8,
               S_INIT=9,S_ADDR1=10,S_ADDR2=11,S_STREAM_LOAD=12,S_BUFFER_READY=13;
    reg [3:0] state;
    reg [7:0] sector[0:511];
    reg [31:0] current_cluster,remaining_bytes;
    reg [7:0] sector_in_cluster;
    // 10 bits: the index must be able to reach exactly 512 so that the
    // end-of-sector compare below can fire.  As a 9-bit reg it wrapped
    // 511 -> 0 and the compare `buffer_index==512` was constant-false,
    // which stopped the reader from ever fetching the next sector: the
    // sector RAM kept replaying its stale contents and the BMP parser
    // therefore never saw a valid header for anything past byte 511.
    reg [9:0] buffer_index;
    reg [31:0] clusters_seen,max_clusters_needed;
    reg [8:0] fat_byte_offset;
    reg [31:0] fat_entry_capture;
    reg [31:0] cluster_sector_offset,cluster_base_lba;
    reg [7:0] byte_data_reg;
    integer base;
    reg [31:0] next_cluster;
    reg last_byte;
    wire [7:0] sector_q;
    generate if(USE_BRAM)begin:music_buffer
        EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.DATA_WIDTH_B(8),
          .ADDR_WIDTH_A(9),.ADDR_WIDTH_B(9),.DATA_DEPTH_A(512),.DATA_DEPTH_B(512),
          .BYTE_ENABLE(0),.BYTE_A(1),.BYTE_B(1),.MODE("DP"),
          .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.FORCE_KEEP("ON"),.IMPLEMENT("9K")) ram(
          .doa(),.dob(sector_q),.dia(sec_data_byte),.dib(8'd0),
          .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(sec_data_valid),.rsta(1'b0),.bea(1'b0),
          .ceb(1'b1),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
          .addra(sec_data_index),.addrb(buffer_index[8:0]));
    end else begin:legacy_buffer
        assign sector_q=sector[buffer_index[8:0]];
    end endgenerate

    function [31:0] le32;
        input integer a;
        begin le32={sector[a+3],sector[a+2],sector[a+1],sector[a]}; end
    endfunction
    function [2:0] spc_shift;
        input [7:0] v;
        begin
            case(v)
                8'd1:spc_shift=0;8'd2:spc_shift=1;8'd4:spc_shift=2;8'd8:spc_shift=3;
                8'd16:spc_shift=4;8'd32:spc_shift=5;8'd64:spc_shift=6;
                default:spc_shift=7;
            endcase
        end
    endfunction
    function [31:0] cluster_lba;
        input [31:0] c;
        begin cluster_lba=data_start_lba+((c-2)<<spc_shift(sectors_per_cluster)); end
    endfunction
    // S_STREAM invariant: at least one byte remains. For the new independent
    // readers, avoid the 32-bit zero-compare -> FIFO -> control chain.
    assign byte_valid=(state==S_STREAM);
    assign byte_data=byte_data_reg;
    assign file_last=byte_valid&&last_byte;
    wire byte_take=byte_valid&&byte_ready;

    task fail;
        input [7:0] code;
        begin error<=1;error_code<=code;busy<=0;state<=S_ERROR;end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=S_IDLE;sec_req<=0;sec_lba<=0;file_offset<=0;busy<=0;
            done<=0;error<=0;error_code<=`ERR_NONE;current_cluster<=0;
            remaining_bytes<=0;sector_in_cluster<=0;buffer_index<=0;
            clusters_seen<=0;max_clusters_needed<=0;next_cluster<=0;
            fat_byte_offset<=0;fat_entry_capture<=0;
            cluster_sector_offset<=0;cluster_base_lba<=0;
            byte_data_reg<=0;last_byte<=0;
        end else begin
            sec_req<=0;done<=0;
            if(sec_data_valid) begin
                if(!USE_BRAM)sector[sec_data_index]<=sec_data_byte;
                if(state==S_FAT_WAIT) begin
                    if(sec_data_index==fat_byte_offset)fat_entry_capture[7:0]<=sec_data_byte;
                    if(sec_data_index==fat_byte_offset+1'b1)fat_entry_capture[15:8]<=sec_data_byte;
                    if(sec_data_index==fat_byte_offset+2'd2)fat_entry_capture[23:16]<=sec_data_byte;
                    if(sec_data_index==fat_byte_offset+2'd3)fat_entry_capture[31:24]<=sec_data_byte;
                end
            end
            if(abort) begin busy<=0;state<=S_IDLE; end
            else if(sec_error&&busy) fail(`ERR_SD_CMD17);
            else case(state)
                S_IDLE: if(start) begin
                    busy<=1;error<=0;error_code<=`ERR_NONE;state<=S_INIT;
                end
                S_INIT: begin
                    if(first_cluster<2||file_size==0||sectors_per_cluster==0)
                        fail(`ERR_FS_CLUSTER);
                    else begin
                        current_cluster<=first_cluster;remaining_bytes<=file_size;last_byte<=file_size==1;
                        file_offset<=0;sector_in_cluster<=0;clusters_seen<=1;
                        // A file can never legitimately consume more clusters than
                        // its number of 512-byte sectors. This conservative bound
                        // catches cyclic FAT chains without synthesizing a divider.
                        max_clusters_needed<=(file_size+511)>>9;
                        state<=S_ADDR1;
                    end
                end
                S_ADDR1: begin
                    cluster_sector_offset<=(current_cluster-2)<<spc_shift(sectors_per_cluster);
                    state<=S_ADDR2;
                end
                S_ADDR2: begin
                    cluster_base_lba<=data_start_lba+cluster_sector_offset;
                    state<=S_DATA_REQ;
                end
                S_DATA_REQ: if(!sec_busy) begin
                    sec_lba<=cluster_base_lba+sector_in_cluster;
                    sec_req<=1;state<=S_DATA_WAIT;
                end
                // A new 512-byte block has arrived: restart the byte walk.
                S_DATA_WAIT: if(sec_done) begin
                    buffer_index<=0;state<=USE_BRAM?S_BUFFER_READY:S_STREAM_LOAD;
                end
                S_BUFFER_READY:state<=S_STREAM_LOAD;
                // Register the sector RAM output before presenting it to the
                // BMP parser.  SPI is much slower than this two-cycle/byte
                // path, and the register removes the final RAM-address-to-
                // parser-header timing violation.
                //
                // buffer_index is incremented here rather than in S_STREAM so
                // that walking the sector never forms a combinational loop
                // through the large read mux: the index used to read is now a
                // register output, which closes the previously failing
                // pixel_fifo->byte_ready->buffer_index setup path.
                S_STREAM_LOAD: begin
                    buffer_index<=buffer_index+1'b1;
                    byte_data_reg<=sector_q;
                    state<=S_STREAM;
                end
                S_STREAM: if(byte_take) begin
                    file_offset<=file_offset+1'b1;remaining_bytes<=remaining_bytes-1'b1;
                    last_byte<=remaining_bytes==2;
                    if(last_byte) begin busy<=0;done<=1;state<=S_DONE;end
                    else if(buffer_index==10'd512) begin
                        buffer_index<=0;
                        if(sector_in_cluster+1'b1<sectors_per_cluster) begin
                            sector_in_cluster<=sector_in_cluster+1'b1;state<=S_DATA_REQ;
                        end else state<=S_FAT_REQ;
                    end else state<=S_STREAM_LOAD;
                end
                S_FAT_REQ: if(!sec_busy) begin
                    sec_lba<=fat_start_lba+(current_cluster>>7);
                    fat_byte_offset<={current_cluster[6:0],2'b00};fat_entry_capture<=0;
                    sec_req<=1;state<=S_FAT_WAIT;
                end
                S_FAT_WAIT: if(sec_done) state<=S_FAT_PARSE;
                S_FAT_PARSE: begin
                    next_cluster=fat_entry_capture&32'h0FFFFFFF;
                    if(next_cluster>=32'h0FFFFFF8) fail(`ERR_FS_CLUSTER);
                    else if(next_cluster<2||next_cluster==32'h0FFFFFF7||next_cluster>max_cluster||
                            clusters_seen>=max_clusters_needed) fail(`ERR_FS_CLUSTER);
                    else begin
                        current_cluster<=next_cluster;sector_in_cluster<=0;
                        clusters_seen<=clusters_seen+1'b1;state<=S_ADDR1;
                    end
                end
                // Allow the same reader to stream the next selected file.
                S_DONE: if(start) begin
                    busy<=1;error<=0;error_code<=`ERR_NONE;state<=S_INIT;
                end
                S_ERROR: state<=S_ERROR;
                default: fail(`ERR_FS_CLUSTER);
            endcase
        end
    end
endmodule
