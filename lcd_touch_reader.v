`timescale 1ns/1ps
// FT6336G: poll registers 02..06 at 50Hz, single contact, two-sample debounce.
// Seven menu commands: next,prev,auto,audio,brightness,contrast,default.
module lcd_touch_reader #(parameter CLK_HZ=100000000,parameter I2C_HALF=500)(
    input wire clk,reset,inout wire scl,sda,input wire interrupt_n,
    output reg reset_n,output reg present,output reg event_valid,
    output reg [3:0] event_code,output reg fault,
    output reg slider_valid,output reg [9:0] slider_position,
    input wire zoom_page,output reg locate_valid,output reg [9:0] locate_x,locate_y,
    output reg zoom_valid,output reg [3:0] zoom_command
);
    localparam RESET_LOW=0,BOOT=1,POLL=2,SEND=3,WAIT=4,CHECK=5;
    reg [2:0] state;reg [25:0] timer;reg [3:0] step;
    reg byte_start;reg [1:0] byte_command;reg [7:0] byte_tx;reg byte_ack;
    wire byte_busy,byte_done,byte_error,byte_nack;wire [7:0] byte_rx;
    reg [7:0] count,xh,xl,yh,yl;
    reg held,transaction_failed;reg [1:0] stable_count;reg [3:0] previous_button;
    reg [4:0] repeat_polls;
    wire [11:0] touch_x={xh[3:0],xl},touch_y={yh[3:0],yl};
    wire touch_valid=(count[3:0]==1)&&(xh[7:6]!=2'b01)&&(touch_x<240)&&(touch_y>=144)&&(touch_y<304);
    wire [1:0] button_row=(touch_y<184)?0:(touch_y<224)?1:(touch_y<264)?2:3;
    wire [3:0] button=(button_row==2)?
        ((touch_x<60)?4'd8:(touch_x<120)?4'd4:(touch_x<180)?4'd9:4'd5):
        {1'b0,button_row,(touch_x>=120)};
    wire repeat_button=(button==4||button==5||button==8||button==9);
    wire slider_contact=(count[3:0]==1)&&(xh[7:6]!=2'b01)&&
        touch_y>=128&&touch_y<144&&touch_x>=12&&touch_x<228;
    wire [11:0] slider_x=touch_x-12;
    wire [11:0] slider_scaled=(slider_x<<1)+slider_x;
    // Decode during the I2C STOP interval, before CHECK consumes a sample.
    // Keep the coordinate comparisons out of the command/held feedback cone.
    reg contact_q,release_q,touch_valid_q,slider_contact_q,locator_q,zoom_buttons_q;
    reg [3:0] button_q,zoom_button_q;reg repeat_q;
    reg [9:0] locate_x_q,locate_y_q,slider_q;
    always @(posedge clk or posedge reset)begin
        if(reset)begin
            zoom_buttons_q<=0;contact_q<=0;release_q<=1;touch_valid_q<=0;slider_contact_q<=0;locator_q<=0;
            button_q<=0;zoom_button_q<=0;repeat_q<=0;locate_x_q<=0;locate_y_q<=0;slider_q<=320;
        end else begin
            contact_q<=(count[3:0]==1)&&(xh[7:6]!=2'b01);
            release_q<=(count[3:0]==0)||(xh[7:6]==2'b01);
            touch_valid_q<=touch_valid;slider_contact_q<=slider_contact;button_q<=button;repeat_q<=repeat_button;
            zoom_buttons_q<=(touch_x<240&&touch_y>=184&&touch_y<304);
            locator_q<=(touch_x>=40&&touch_x<200&&touch_y>=40&&touch_y<160);
            locate_x_q<=(touch_x-12'd40)<<2;locate_y_q<=(touch_y-12'd40)<<2;
            slider_q<=(slider_scaled>=640)?10'd640:slider_scaled[9:0];
            zoom_button_q<=(touch_y<224)?((touch_x<120)?4'd0:4'd1):
                           (touch_y<264)?((touch_x<120)?4'd2:4'd3):4'd4;
        end
    end
    lcd_i2c_byte #(.HALF_CYCLES(I2C_HALF)) u_i2c(clk,reset,byte_start,byte_command,
        byte_tx,byte_ack,byte_busy,byte_done,byte_error,byte_nack,byte_rx,scl,sda);
    always @(posedge clk or posedge reset)begin
        if(reset)begin
            state<=RESET_LOW;timer<=0;step<=0;byte_start<=0;byte_command<=0;
            byte_tx<=0;byte_ack<=0;reset_n<=0;present<=0;fault<=0;
            event_valid<=0;event_code<=0;held<=0;stable_count<=0;previous_button<=0;repeat_polls<=0;
            count<=0;xh<=0;xl<=0;yh<=0;yl<=0;transaction_failed<=0;
            slider_valid<=0;slider_position<=320;
            locate_valid<=0;locate_x<=320;locate_y<=240;zoom_valid<=0;zoom_command<=0;
        end else begin
            byte_start<=0;event_valid<=0;slider_valid<=0;locate_valid<=0;zoom_valid<=0;
            case(state)
                RESET_LOW:if(timer==CLK_HZ/10-1)begin timer<=0;reset_n<=1;state<=BOOT;end else timer<=timer+1'b1;
                BOOT:if(timer==CLK_HZ*3/10-1)begin timer<=0;state<=POLL;end else timer<=timer+1'b1;
                POLL:if(timer==CLK_HZ/50-1)begin timer<=0;step<=0;transaction_failed<=0;state<=SEND;end else timer<=timer+1'b1;
                SEND:if(!byte_busy)begin
                    byte_start<=1;byte_ack<=1;byte_tx<=0;
                    case(step)
                        0,3:byte_command<=0;
                        1:begin byte_command<=2;byte_tx<=8'h70;end
                        2:begin byte_command<=2;byte_tx<=8'h02;end
                        4:begin byte_command<=2;byte_tx<=8'h71;end
                        5,6,7,8:byte_command<=3;
                        9:begin byte_command<=3;byte_ack<=0;end
                        default:byte_command<=1;
                    endcase
                    state<=WAIT;
                end
                WAIT:if(byte_done)begin
                    if(byte_error||(byte_nack&&step>=1&&step<=4&&step!=3))begin
                        present<=0;fault<=1;held<=0;stable_count<=0;transaction_failed<=1;repeat_polls<=0;
                        if(step==10)state<=POLL;else begin step<=10;state<=SEND;end
                    end else begin
                        case(step)5:count<=byte_rx;6:xh<=byte_rx;7:xl<=byte_rx;8:yh<=byte_rx;9:yl<=byte_rx;endcase
                        if(step==10)begin
                            if(transaction_failed)state<=POLL;
                            else begin present<=1;fault<=0;state<=CHECK;end
                        end
                        else begin step<=step+1'b1;state<=SEND;end
                    end
                end
                CHECK:begin
                    state<=POLL;
                    if(zoom_page)begin
                        // Locator is 160x120 at (40,40): exactly 4 canvas pixels per touch pixel.
                        if(release_q)begin held<=0;stable_count<=0;end
                        else if(contact_q&&locator_q)begin
                            locate_valid<=1;locate_x<=locate_x_q;locate_y<=locate_y_q;
                            held<=1;stable_count<=0;
                        end else if(contact_q&&zoom_buttons_q&&!held)begin
                            if(stable_count!=0)begin
                                zoom_valid<=1;held<=1;stable_count<=0;
                                zoom_command<=zoom_button_q;
                            end else stable_count<=1;
                        end else stable_count<=0;
                    end else if(slider_contact_q)begin
                        held<=1;stable_count<=0;slider_valid<=1;repeat_polls<=0;
                        slider_position<=slider_q;
                    end else if(release_q)begin held<=0;stable_count<=0;repeat_polls<=0;end
                    else if(!touch_valid_q)begin stable_count<=0;repeat_polls<=0;end
                    else if(!held)begin
                        if(stable_count!=0&&button_q==previous_button)begin
                            held<=1;stable_count<=0;repeat_polls<=0;
                            begin event_code<=button_q;event_valid<=1;end
                        end else begin previous_button<=button_q;stable_count<=1;end
                    end else if(repeat_q&&button_q==previous_button)begin
                        if(repeat_polls==14)begin
                            event_code<=button_q;event_valid<=1;repeat_polls<=9;
                        end else repeat_polls<=repeat_polls+1'b1;
                    end else if(repeat_q&&button!=previous_button)begin
                        held<=0;stable_count<=0;repeat_polls<=0;
                    end
                end
                default:state<=RESET_LOW;
            endcase
        end
    end
endmodule
