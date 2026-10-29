`timescale 1ns/1ps
// Write-only SPI mode 0. CS stays active between bytes of a command stream.
module lcd_spi_write #(parameter HALF_CYCLES=10)(
    input wire clk,reset,input wire valid,input wire [7:0] data,
    input wire dc,input wire select,output wire ready,output reg done,
    output wire cs_n,output reg sck,mosi,output reg dc_out
);
    localparam CW=(HALF_CYCLES<=1)?1:$clog2(HALF_CYCLES);
    reg [CW-1:0] divider;reg [7:0] shift;reg [2:0] bit_index;reg busy;
    assign ready=!busy;assign cs_n=!select||reset;
    always @(posedge clk or posedge reset)begin
        if(reset)begin divider<=0;shift<=0;bit_index<=0;busy<=0;sck<=0;mosi<=0;dc_out<=0;done<=0;end
        else begin
            done<=0;
            if(!busy)begin
                sck<=0;
                if(valid&&select)begin
                    shift<=data;mosi<=data[7];dc_out<=dc;
                    bit_index<=7;divider<=0;busy<=1;
                end
            end else if(divider==HALF_CYCLES-1)begin
                divider<=0;
                if(!sck)sck<=1;
                else begin
                    sck<=0;
                    if(bit_index==0)begin busy<=0;done<=1;end
                    else begin bit_index<=bit_index-1'b1;shift<={shift[6:0],1'b0};mosi<=shift[6];end
                end
            end else divider<=divider+1'b1;
        end
    end
endmodule
