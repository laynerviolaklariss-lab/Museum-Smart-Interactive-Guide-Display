`timescale 1ns/1ps

// Dual-clock PCM FIFO.  Gray-coded pointers isolate the 100 MHz TF/FAT
// producer from the approximately 48 kHz HDMI audio consumer.
module audio_async_fifo #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 12,
    parameter SHOWAHEAD = 0
)(
    input  wire                  rst,
    input  wire                  wr_clk,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    input  wire                  rd_clk,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    output wire [ADDR_WIDTH:0]    wr_used
);
    localparam PTR_WIDTH = ADDR_WIDTH + 1;
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    reg [PTR_WIDTH-1:0] wr_bin,wr_gray;
    reg [PTR_WIDTH-1:0] rd_bin,rd_gray;
    reg [PTR_WIDTH-1:0] rd_gray_w1,rd_gray_w2;
    reg [PTR_WIDTH-1:0] wr_gray_r1,wr_gray_r2;
    reg full_reg,empty_reg;

    // Precompute both pointer candidates.  Selecting between two already
    // encoded/computed values keeps wr_en out of the adder/XOR/comparator
    // chain and closes the 100 MHz TF-stream -> FIFO-full timing path.
    wire wr_push=wr_en&&!full_reg;
    wire rd_pop=rd_en&&!empty_reg;
    wire [PTR_WIDTH-1:0] wr_bin_inc=wr_bin+1'b1;
    wire [PTR_WIDTH-1:0] wr_gray_inc=(wr_bin_inc>>1)^wr_bin_inc;
    wire [PTR_WIDTH-1:0] rd_bin_inc=rd_bin+1'b1;
    wire [PTR_WIDTH-1:0] rd_gray_inc=(rd_bin_inc>>1)^rd_bin_inc;
    wire [PTR_WIDTH-1:0] wr_bin_next=wr_push?wr_bin_inc:wr_bin;
    wire [PTR_WIDTH-1:0] wr_gray_next=wr_push?wr_gray_inc:wr_gray;
    wire [PTR_WIDTH-1:0] rd_bin_next=rd_pop?rd_bin_inc:rd_bin;
    wire [PTR_WIDTH-1:0] rd_gray_next=rd_pop?rd_gray_inc:rd_gray;
    wire [PTR_WIDTH-1:0] full_compare=
        {~rd_gray_w2[PTR_WIDTH-1:PTR_WIDTH-2],rd_gray_w2[PTR_WIDTH-3:0]};
    wire full_next=wr_push?(wr_gray_inc==full_compare)
                           :(wr_gray==full_compare);
    wire empty_next=rd_pop?(rd_gray_inc==wr_gray_r2)
                           :(rd_gray==wr_gray_r2);
    assign full=full_reg;
    assign empty=empty_reg;
    function [PTR_WIDTH-1:0] gray_to_bin(input [PTR_WIDTH-1:0] g);
        integer k;
        begin gray_to_bin[PTR_WIDTH-1]=g[PTR_WIDTH-1];
            for(k=PTR_WIDTH-2;k>=0;k=k-1)gray_to_bin[k]=gray_to_bin[k+1]^g[k];
        end
    endfunction
    assign wr_used=wr_bin-gray_to_bin(rd_gray_w2);

    always @(posedge wr_clk or posedge rst) begin
        if(rst) begin
            wr_bin<=0;wr_gray<=0;rd_gray_w1<=0;rd_gray_w2<=0;full_reg<=0;
        end else begin
            rd_gray_w1<=rd_gray;rd_gray_w2<=rd_gray_w1;
            full_reg<=full_next;
            if(wr_push) begin
                mem[wr_bin[ADDR_WIDTH-1:0]]<=wr_data;
                wr_bin<=wr_bin_next;wr_gray<=wr_gray_next;
            end
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if(rst) begin
            rd_bin<=0;rd_gray<=0;wr_gray_r1<=0;wr_gray_r2<=0;rd_data<=0;
            empty_reg<=1'b1;
        end else begin
            wr_gray_r1<=wr_gray;wr_gray_r2<=wr_gray_r1;
            empty_reg<=empty_next;
            if(SHOWAHEAD)rd_data<=mem[rd_bin_next[ADDR_WIDTH-1:0]];
            if(rd_pop) begin
                if(!SHOWAHEAD)rd_data<=mem[rd_bin[ADDR_WIDTH-1:0]];
                rd_bin<=rd_bin_next;rd_gray<=rd_gray_next;
            end
        end
    end
endmodule
