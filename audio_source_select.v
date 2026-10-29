`timescale 1ns/1ps
// Pixel->audio bundled-data request/ack. The payload is held until ACK.
// The original music FIFO continues consuming normally in every source mode.
module audio_source_select(
    input wire pixel_clk,input wire pixel_reset,input wire mode_press,
    input wire audio_clk,input wire audio_reset,
    input wire [15:0] music_sample,
    output wire [15:0] output_sample,output reg [2:0] source_mode
);
    reg [2:0] request_mode,pending_mode;
    reg request_toggle,ack_toggle;
    reg ack_p1,ack_p2,request_a1,request_a2,request_seen;
    always @(posedge pixel_clk or posedge pixel_reset) begin
        if(pixel_reset) begin request_mode<=0;request_toggle<=0;ack_p1<=0;ack_p2<=0;end
        else begin
            ack_p1<=ack_toggle;ack_p2<=ack_p1;
            if(mode_press&&(ack_p2==request_toggle)) begin
                request_mode<=(request_mode==4)?3'd0:request_mode+1'b1;
                request_toggle<=~request_toggle;
            end
        end
    end
    localparam RUN=0,FADE_OUT=1,FADE_IN=2;
    reg [1:0] state;
    reg [2:0] gain_step;
    reg [5:0] ramp_count;
    reg [6:0] phase;
    wire [6:0] phase_step=(source_mode==1)?7'd1:(source_mode==2)?7'd2:7'd4;
    wire signed [15:0] tone_sample;
    audio_sine96 u_sine(.phase(phase),.value(tone_sample));
    always @(posedge audio_clk or posedge audio_reset) begin
        if(audio_reset) begin
            request_a1<=0;request_a2<=0;request_seen<=0;ack_toggle<=0;
            source_mode<=0;pending_mode<=0;state<=RUN;gain_step<=4;
            ramp_count<=0;phase<=0;
        end else begin
            request_a1<=request_toggle;request_a2<=request_a1;
            if(source_mode>=1&&source_mode<=3)
                phase<=(phase>=7'd96-phase_step)?phase-(7'd96-phase_step):phase+phase_step;
            else phase<=0;
            if(request_a2!=request_seen) begin
                request_seen<=request_a2;ack_toggle<=request_a2;
                pending_mode<=request_mode;
                if(request_mode!=source_mode) begin state<=FADE_OUT;ramp_count<=0;end
            end else begin
                case(state)
                    FADE_OUT: begin
                        if(gain_step==0) begin
                            source_mode<=pending_mode;phase<=0;
                            state<=FADE_IN;ramp_count<=0;
                        end else if(ramp_count==63) begin
                            ramp_count<=0;gain_step<=gain_step-1'b1;
                        end else ramp_count<=ramp_count+1'b1;
                    end
                    FADE_IN: begin
                        if(ramp_count==63) begin
                            ramp_count<=0;
                            if(gain_step==3) begin gain_step<=4;state<=RUN;end
                            else gain_step<=gain_step+1'b1;
                        end else ramp_count<=ramp_count+1'b1;
                    end
                    default:begin gain_step<=4;ramp_count<=0;end
                endcase
            end
        end
    end
    wire signed [15:0] selected=(source_mode==0)?$signed(music_sample):
                               (source_mode==4)?16'sd0:tone_sample;
    wire signed [17:0] wide_sample={{2{selected[15]}},selected};
    reg signed [17:0] ramped_sample;
    always @(*) begin
        case(gain_step)
            0:ramped_sample=18'sd0;
            1:ramped_sample=wide_sample>>>2;
            2:ramped_sample=wide_sample>>>1;
            3:ramped_sample=((wide_sample<<<1)+wide_sample)>>>2;
            default:ramped_sample=wide_sample;
        endcase
    end
    assign output_sample=ramped_sample[15:0];
endmodule
