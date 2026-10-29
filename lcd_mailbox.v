`timescale 1ns/1ps
// Bundled payload held until request/ack completes. Shared reset required.
// Status snapshots may skip an update when busy; touch events are 20ms apart.
module lcd_mailbox #(parameter WIDTH=3)(
    input wire reset,input wire src_clk,input wire src_valid,
    input wire [WIDTH-1:0] src_data,output wire src_ready,
    input wire dst_clk,output reg dst_valid,output reg [WIDTH-1:0] dst_data
);
    reg [WIDTH-1:0] held;
    reg request,ack,ack_s1,ack_s2,req_d1,req_d2,seen;
    assign src_ready=(ack_s2==request);
    always @(posedge src_clk or posedge reset)begin
        if(reset)begin held<=0;request<=0;ack_s1<=0;ack_s2<=0;end
        else begin
            ack_s1<=ack;ack_s2<=ack_s1;
            if(src_valid&&src_ready)begin held<=src_data;request<=~request;end
        end
    end
    always @(posedge dst_clk or posedge reset)begin
        if(reset)begin req_d1<=0;req_d2<=0;seen<=0;ack<=0;dst_valid<=0;dst_data<=0;end
        else begin
            req_d1<=request;req_d2<=req_d1;dst_valid<=0;
            if(req_d2!=seen)begin
                dst_data<=held;dst_valid<=1;seen<=req_d2;ack<=req_d2;
            end
        end
    end
endmodule
