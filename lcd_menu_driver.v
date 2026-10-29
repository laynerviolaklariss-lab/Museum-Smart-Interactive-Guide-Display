`timescale 1ns/1ps
// ILI9341V 240x320 RGB565. Initial full paint; only header/footer thereafter.
// All raster generation is independent of SDRAM and TF, with no framebuffer.
module lcd_menu_driver #(parameter CLK_HZ=100000000,parameter SPI_HALF=10)(
    input wire clk,reset,input wire [56:0] status,input wire [46:0] zoom_status,input wire [7:0] main_error,
    input wire main_ready,touch_present,touch_fault,
    output wire lcd_cs_n,output reg lcd_rst_n,output wire lcd_dc,lcd_mosi,lcd_sck,lcd_bl
);
    localparam R_HIGH=0,R_LOW=1,R_RELEASE=2,INIT_SEND=3,INIT_WAIT=4,SLEEP_WAIT=5,
        WIN_SEND=6,WIN_WAIT=7,PREP0=8,PREP1=9,PREP2=10,
        HI_SEND=11,HI_WAIT=12,LO_SEND=13,LO_WAIT=14,IDLE=15;
    reg [3:0] state;reg [25:0] timer;reg [6:0] init_index;
    reg [3:0] win_index;reg [7:0] x;reg [8:0] y;
    reg first_paint,footer;reg [46:0] shown_zoom;reg [56:0] shown_status;reg [7:0] shown_error;
    reg shown_ready,shown_touch,shown_fault;
    reg tx_valid,tx_dc;reg [7:0] tx_data;wire tx_ready,tx_done;
    wire [8:0] init_token;wire init_last;
    wire [8:0] top_y=footer?9'd304:9'd0;
    wire [8:0] end_y=(first_paint||footer)?9'd319:(shown_zoom[46]?9'd183:9'd143);
    wire dirty=(zoom_status!=shown_zoom)||(status!=shown_status)||(main_error!=shown_error)||
        (main_ready!=shown_ready)||(touch_present!=shown_touch)||(touch_fault!=shown_fault);
    wire select=(state>=INIT_SEND)&&(state!=IDLE);
    assign lcd_bl=!reset;
    lcd_ili9341_init u_init(init_index,init_token,init_last);
    lcd_spi_write #(.HALF_CYCLES(SPI_HALF)) u_spi(clk,reset,tx_valid,tx_data,
        tx_dc,select,tx_ready,tx_done,lcd_cs_n,lcd_sck,lcd_mosi,lcd_dc);
    wire [15:0] render_pixel;reg [15:0] pixel;
    lcd_menu_pixels u_pixels(clk,x,y,shown_status,shown_error,shown_ready,
        shown_touch,shown_fault,render_pixel,shown_zoom);
    reg [8:0] window_token;
    always @(*)begin
        case(win_index)
            0:window_token=9'h02A;
            1,2,3:window_token=9'h100;
            4:window_token=9'h1EF;
            5:window_token=9'h02B;
            6:window_token={1'b1,7'd0,top_y[8]};
            7:window_token={1'b1,top_y[7:0]};
            8:window_token={1'b1,7'd0,end_y[8]};
            9:window_token={1'b1,end_y[7:0]};
            default:window_token=9'h02C;
        endcase
    end
    always @(posedge clk or posedge reset)begin
        if(reset)begin
            state<=R_HIGH;timer<=0;lcd_rst_n<=1;init_index<=0;win_index<=0;
            x<=0;y<=0;first_paint<=1;footer<=0;shown_status<=0;shown_error<=0;
            shown_ready<=0;shown_touch<=0;shown_fault<=0;pixel<=0;shown_zoom<=0;
            tx_valid<=0;tx_dc<=0;tx_data<=0;
        end else begin
            tx_valid<=0;
            case(state)
                R_HIGH:if(timer==CLK_HZ/20-1)begin timer<=0;lcd_rst_n<=0;state<=R_LOW;end else timer<=timer+1'b1;
                R_LOW:if(timer==CLK_HZ/10-1)begin timer<=0;lcd_rst_n<=1;state<=R_RELEASE;end else timer<=timer+1'b1;
                R_RELEASE:if(timer==CLK_HZ/20-1)begin timer<=0;state<=INIT_SEND;end else timer<=timer+1'b1;
                INIT_SEND:if(tx_ready)begin tx_data<=init_token[7:0];tx_dc<=init_token[8];tx_valid<=1;state<=INIT_WAIT;end
                INIT_WAIT:if(tx_done)begin
                    if(init_last)begin
                        shown_status<=status;shown_error<=main_error;shown_zoom<=zoom_status;shown_ready<=main_ready;
                        shown_touch<=touch_present;shown_fault<=touch_fault;state<=WIN_SEND;win_index<=0;
                    end else begin
                        init_index<=init_index+1'b1;
                        if(init_token==9'h011)begin timer<=0;state<=SLEEP_WAIT;end else state<=INIT_SEND;
                    end
                end
                SLEEP_WAIT:if(timer==CLK_HZ*12/100-1)begin timer<=0;state<=INIT_SEND;end else timer<=timer+1'b1;
                WIN_SEND:if(tx_ready)begin tx_data<=window_token[7:0];tx_dc<=window_token[8];tx_valid<=1;state<=WIN_WAIT;end
                WIN_WAIT:if(tx_done)begin
                    if(win_index==10)begin x<=0;y<=top_y;state<=PREP0;end
                    else begin win_index<=win_index+1'b1;state<=WIN_SEND;end
                end
                PREP0:state<=PREP1;
                PREP1:state<=PREP2;
                PREP2:begin pixel<=render_pixel;state<=HI_SEND;end
                HI_SEND:if(tx_ready)begin tx_dc<=1;tx_data<=pixel[15:8];tx_valid<=1;state<=HI_WAIT;end
                HI_WAIT:if(tx_done)state<=LO_SEND;
                LO_SEND:if(tx_ready)begin tx_dc<=1;tx_data<=pixel[7:0];tx_valid<=1;state<=LO_WAIT;end
                LO_WAIT:if(tx_done)begin
                    if(x==239)begin
                        x<=0;
                        if(y==end_y)begin
                            if(first_paint||footer)begin first_paint<=0;footer<=0;state<=IDLE;timer<=0;end
                            else begin footer<=1;win_index<=0;state<=WIN_SEND;end
                        end else begin y<=y+1'b1;state<=PREP0;end
                    end else begin x<=x+1'b1;state<=PREP0;end
                end
                IDLE:if(timer==CLK_HZ/5-1)begin
                    timer<=0;
                    if(dirty)begin
                        shown_status<=status;shown_error<=main_error;shown_zoom<=zoom_status;shown_ready<=main_ready;
                        shown_touch<=touch_present;shown_fault<=touch_fault;
                        // Redraw the whole page on page switches, otherwise just top/footer.
                        if(zoom_status[46]!=shown_zoom[46])first_paint<=1;
                        footer<=0;win_index<=0;state<=WIN_SEND;
                    end
                end else timer<=timer+1'b1;
                default:state<=R_HIGH;
            endcase
        end
    end
endmodule
