`timescale 1ns/1ps

// ============================================================================
//  key_input: 单键输入处理
//    - 两级触发器同步（外部拨码/按键进入 clk 域）
//    - 消抖：输入与当前稳定电平不同并保持 DEBOUNCE_MS 才更新
//    - pressed: 按下（0->1）当拍输出一个周期脉冲
//    - 长按连发（REPEAT_EN=1）：首次按下立即给一个脉冲，持续按住
//      LONG_MS 后，每隔 REPEAT_MS 再给一个脉冲；松开即停
//    - level: 消抖后的稳定电平（高=按下/拨到上方）
// 注：板上为拨码开关，向上=1。单次触发要求拨上后拨回，才能再次触发；
//     若保持向上（长按），在 REPEAT_EN=1 时按上述规则连发。
// ============================================================================
module key_input #(
    parameter integer CLK_HZ      = 100_000_000, // 采样时钟频率
    parameter integer DEBOUNCE_MS = 20,          // 消抖时间
    parameter integer LONG_MS     = 800,         // 长按起连发阈值
    parameter integer REPEAT_MS   = 300,         // 连发间隔
    parameter integer REPEAT_EN   = 1            // 1=长按连发, 0=仅单次
)(
    input  wire clk,
    input  wire rst,          // 高有效
    input  wire raw,          // 原始输入，高=按下
    output reg  pressed,      // 单周期有效脉冲（含连发）
    output wire level         // 消抖后稳定电平
);
    localparam integer DEB_LIMIT = (CLK_HZ/1000)*DEBOUNCE_MS;
    localparam integer LONG_LIMIT = (CLK_HZ/1000)*LONG_MS;
    localparam integer REP_LIMIT  = (CLK_HZ/1000)*REPEAT_MS;

    // ---- 两级同步 ----
    reg sync0, sync1;
    always @(posedge clk) begin
        if (rst) begin sync0 <= 1'b0; sync1 <= 1'b0; end
        else        begin sync0 <= raw;  sync1 <= sync0; end
    end

    // ---- 消抖 ----
    reg db;
    reg [31:0] deb_cnt;
    always @(posedge clk) begin
        if (rst) begin db <= 1'b0; deb_cnt <= 32'd0; end
        else if (sync1 != db) begin
            if (deb_cnt == DEB_LIMIT-1) begin db <= sync1; deb_cnt <= 32'd0; end
            else                         deb_cnt <= deb_cnt + 1'b1;
        end else begin
            deb_cnt <= 32'd0;
        end
    end
    assign level = db;

    // ---- 边沿与长按连发 ----
    reg db_d;                 // db 延迟一拍
    reg armed;                // 已发首次脉冲、处于按住跟踪
    reg [31:0] hold_cnt;
    wire press_edge   =  db & ~db_d;
    always @(posedge clk) begin
        if (rst) begin
            db_d <= 1'b0; armed <= 1'b0; hold_cnt <= 32'd0; pressed <= 1'b0;
        end else begin
            db_d <= db;
            pressed <= 1'b0;
            if (press_edge) begin
                // 首次按下：立即一个脉冲
                pressed  <= 1'b1;
                armed    <= 1'b1;
                hold_cnt <= 32'd0;
            end else if (db && armed && (REPEAT_EN != 0)) begin
                // 持续按住：到长按阈值后开始周期连发
                if (hold_cnt == LONG_LIMIT-1) begin
                    pressed  <= 1'b1;
                    // This branch already proves hold_cnt == LONG_LIMIT-1.
                    // Constant reload is exactly equal modulo 32 bits and
                    // removes a 32-bit subtractor from the repeat feedback.
                    hold_cnt <= LONG_LIMIT - REP_LIMIT;
                end else begin
                    hold_cnt <= hold_cnt + 1'b1;
                end
            end else if (~db) begin
                // 松开：复位
                armed <= 1'b0; hold_cnt <= 32'd0;
            end
        end
    end
endmodule
