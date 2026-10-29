`timescale 1ns/1ps
// All I2C pins are open drain: only drive 0 or Z. Reads actual SCL to honor
// clock stretching. Timeout releases the bus and never resets other modules.
module lcd_i2c_byte #(parameter HALF_CYCLES=500,parameter TIMEOUT_CYCLES=1000000)(
    input wire clk,reset,input wire start,input wire [1:0] command,
    input wire [7:0] tx_data,input wire read_ack,
    output reg busy,done,error,nack,output reg [7:0] rx_data,
    inout wire scl,sda
);
    localparam IDLE=0,START_LOW=1,START_HIGH=2,START_HOLD=3,
        STOP_LOW=4,STOP_HIGH=5,STOP_HOLD=6,BIT_LOW=7,BIT_HIGH=8,BIT_FALL=9;
    reg [3:0] state;reg scl_low,sda_low;reg [9:0] timer;
    reg [19:0] timeout;reg [3:0] bit_index;
    reg [7:0] shift;reg reading,ack_value;
    reg scl_s1,scl_s2,sda_s1,sda_s2;
    assign scl=scl_low?1'b0:1'bz;assign sda=sda_low?1'b0:1'bz;
    always @(posedge clk)begin scl_s1<=scl;scl_s2<=scl_s1;sda_s1<=sda;sda_s2<=sda_s1;end
    always @(posedge clk or posedge reset)begin
        if(reset)begin
            state<=IDLE;scl_low<=0;sda_low<=0;timer<=0;timeout<=0;
            bit_index<=0;shift<=0;reading<=0;ack_value<=0;
            busy<=0;done<=0;error<=0;nack<=0;rx_data<=0;
        end else begin
            done<=0;
            if(busy)timeout<=timeout+1'b1;
            if(busy&&timeout==TIMEOUT_CYCLES-1)begin
                state<=IDLE;busy<=0;done<=1;error<=1;scl_low<=0;sda_low<=0;
            end else case(state)
                IDLE:if(start)begin
                    busy<=1;error<=0;nack<=0;timer<=0;timeout<=0;
                    shift<=tx_data;bit_index<=0;reading<=command==3;ack_value<=read_ack;
                    scl_low<=1;
                    if(command==0)begin sda_low<=0;state<=START_LOW;end
                    else if(command==1)begin sda_low<=1;state<=STOP_LOW;end
                    else begin sda_low<=(command==2)&&!tx_data[7];state<=BIT_LOW;end
                end
                START_LOW:if(timer==HALF_CYCLES-1)begin timer<=0;scl_low<=0;state<=START_HIGH;end else timer<=timer+1'b1;
                START_HIGH:if(scl_s2)begin
                    if(timer==HALF_CYCLES-1)begin timer<=0;sda_low<=1;state<=START_HOLD;end else timer<=timer+1'b1;
                end else timer<=0;
                START_HOLD:if(timer==HALF_CYCLES-1)begin timer<=0;scl_low<=1;state<=IDLE;busy<=0;done<=1;end else timer<=timer+1'b1;
                STOP_LOW:if(timer==HALF_CYCLES-1)begin timer<=0;scl_low<=0;state<=STOP_HIGH;end else timer<=timer+1'b1;
                STOP_HIGH:if(scl_s2)begin
                    if(timer==HALF_CYCLES-1)begin timer<=0;sda_low<=0;state<=STOP_HOLD;end else timer<=timer+1'b1;
                end else timer<=0;
                STOP_HOLD:if(timer==HALF_CYCLES-1)begin timer<=0;state<=IDLE;busy<=0;done<=1;end else timer<=timer+1'b1;
                BIT_LOW:if(timer==HALF_CYCLES-1)begin timer<=0;scl_low<=0;state<=BIT_HIGH;end else timer<=timer+1'b1;
                BIT_HIGH:if(scl_s2)begin
                    if(timer==HALF_CYCLES-1)begin
                        timer<=0;
                        if(bit_index<8&&reading)shift<={shift[6:0],sda_s2};
                        if(bit_index==8&&!reading)nack<=sda_s2;
                        scl_low<=1;state<=BIT_FALL;
                    end else timer<=timer+1'b1;
                end else timer<=0;
                BIT_FALL:begin
                    if(bit_index==8)begin rx_data<=shift;state<=IDLE;busy<=0;done<=1;sda_low<=0;end
                    else begin
                        bit_index<=bit_index+1'b1;state<=BIT_LOW;
                        if(bit_index==7)sda_low<=reading&&ack_value;
                        else sda_low<=!reading&&!shift[6-bit_index];
                    end
                end
                default:begin state<=IDLE;busy<=0;scl_low<=0;sda_low<=0;error<=1;done<=1;end
            endcase
        end
    end
endmodule
