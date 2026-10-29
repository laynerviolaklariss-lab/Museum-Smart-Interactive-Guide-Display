`timescale 1ns/1ps
module sdram_frame_verify(
    input wire clk,input wire rst,input wire start,
    input wire init_done,input wire init_ref_vld,
    input wire [20:0] base_addr,
    input wire [31:0] total_words,input wire [31:0] image_width,
    input wire [31:0] expected_sum,input wire [31:0] expected_xor,
    input wire [31:0] exp_tl,input wire [31:0] exp_tr,
    input wire [31:0] exp_bl,input wire [31:0] exp_br,
    output wire app_rd_en,output wire [20:0] app_rd_addr,
    input wire sdr_rd_en,input wire [31:0] sdr_rd_data,
    output reg busy,output reg done,output reg pass,output reg protocol_error,
    output reg [7:0] failure_code
);
    reg [31:0] issue_count,response_count,actual_sum,actual_xor;
    reg finalize;
    reg [20:0] issue_addr;
    wire issue_fire=busy&&init_done&&!init_ref_vld&&(issue_count<total_words);
    assign app_rd_en=issue_fire;
    assign app_rd_addr=issue_addr;
    wire [31:0] sum_with_word=actual_sum+sdr_rd_data;
    wire [31:0] xor_with_word=actual_xor^sdr_rd_data;
    // Register a selected corner word before comparing it.  The hard SDRAM
    // output used to feed four 32-bit compares and an OR tree in one 100 MHz
    // cycle; this pipeline keeps the frame check identical while removing the
    // marginal SDRAM-to-corner_error timing path.
    wire corner_tl=(response_count==0);
    wire corner_tr=(response_count==image_width-1);
    wire corner_bl=(response_count==total_words-image_width);
    wire corner_br=(response_count==total_words-1);
    wire corner_now=corner_tl||corner_tr||corner_bl||corner_br;
    wire [31:0] corner_expected_now=corner_tl?exp_tl:
        corner_tr?exp_tr:corner_bl?exp_bl:exp_br;
    reg corner_error,corner_pending;
    reg [31:0] corner_data_q,corner_expected_q;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            issue_count<=0;issue_addr<=0;response_count<=0;actual_sum<=0;actual_xor<=0;
            busy<=0;done<=0;pass<=0;protocol_error<=0;corner_error<=0;
            corner_pending<=0;corner_data_q<=0;corner_expected_q<=0;
            failure_code<=8'h00;finalize<=0;
        end else begin
            done<=0;
            if(finalize) begin
                finalize<=0;busy<=0;done<=1;
                pass<=(actual_sum==expected_sum)&&(actual_xor==expected_xor)&&
                    !(corner_error||(corner_pending&&(corner_data_q!=corner_expected_q)));
                if(corner_error||(corner_pending&&(corner_data_q!=corner_expected_q))) failure_code<=8'h46;
                else if(actual_sum!=expected_sum) failure_code<=8'h45;
                else if(actual_xor!=expected_xor) failure_code<=8'h47;
                else failure_code<=8'h00;
            end
            if(start&&!busy) begin
                issue_count<=0;issue_addr<=base_addr;
                response_count<=0;actual_sum<=0;actual_xor<=0;
                busy<=1;pass<=0;protocol_error<=0;corner_error<=0;corner_pending<=0;
                failure_code<=8'h00;finalize<=0;
            end
            if(issue_fire) begin
                issue_count<=issue_count+1'b1;
                issue_addr<=issue_addr+1'b1;
            end
            if(corner_pending) begin
                if(corner_data_q!=corner_expected_q) corner_error<=1;
                corner_pending<=0;
            end
            if(sdr_rd_en) begin
                if(!busy||response_count>=total_words) begin
                    protocol_error<=1;busy<=0;done<=1;pass<=0;
                    failure_code<=8'h44;
                end else begin
                    actual_sum<=sum_with_word;actual_xor<=xor_with_word;
                    if(corner_now) begin
                        corner_pending<=1;
                        corner_data_q<=sdr_rd_data;
                        corner_expected_q<=corner_expected_now;
                    end
                    if(response_count+1'b1==total_words) begin
                        // Evaluate the registered totals on the next clock;
                        // do not put the 32-bit accumulator and full compare
                        // in one 100 MHz path.
                        finalize<=1;
                    end else response_count<=response_count+1'b1;
                end
            end
        end
    end
endmodule
