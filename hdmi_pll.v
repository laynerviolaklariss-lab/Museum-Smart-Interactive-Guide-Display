// EG4S20 PLL for HDMI: 50 MHz reference -> 500 MHz VCO.
//   CLKC0 /10 = 50 MHz  (external feedback, normal mode)
//   CLKC1 /4  = 125 MHz = clk_5x    (TMDS serial clock)
//   CLKC2 /20 = 25 MHz  = clk_pixel (independent pixel clock for hdl-util)
module hdmi_pll (
    input  wire refclk,
    input  wire reset,
    output wire clk_pixel,
    output wire clk_5x,
    output wire locked
);
    wire [4:0] pll_clk;
    wire feedback_clk;
    EG_LOGIC_BUFG u_feedback_buf (.i(pll_clk[0]), .o(feedback_clk));
    EG_LOGIC_BUFG u_x5_buf       (.i(pll_clk[1]), .o(clk_5x));
    EG_LOGIC_BUFG u_pixel_buf    (.i(pll_clk[2]), .o(clk_pixel));

    EG_PHY_PLL #(
        .FIN("50.000"),
        .REFCLK_DIV(1),
        .FBCLK_DIV(1),
        .FEEDBK_MODE("NORMAL"),
        .FEEDBK_PATH("CLKC0_EXT"),
        .CLKC0_ENABLE("ENABLE"),
        .CLKC0_DIV(10),
        .CLKC0_CPHASE(9),
        .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),
        .CLKC1_DIV(4),
        .CLKC1_CPHASE(3),
        .CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),
        .CLKC2_DIV(20),
        .CLKC2_CPHASE(19),
        .CLKC2_FPHASE(0),
        .STDBY_ENABLE("ENABLE"),
        .PLLRST_ENA("ENABLE"),
        .DPHASE_SOURCE("DISABLE"),
        .DYNCFG("DISABLE"),
        .SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(4),
        .ICP_CURRENT(13),
        .KVCO(4),
        .LPF_CAPACITOR(1),
        .LPF_RESISTOR(4)
    ) u_pll (
        .refclk(refclk),
        .reset(reset),
        .stdby(1'b0),
        .extlock(locked),
        .fbclk(feedback_clk),
        .clkc(pll_clk),
        .load_reg(1'b0),
        .psclk(1'b0),
        .psdown(1'b0),
        .psstep(1'b0),
        .psclksel(3'b000),
        .psdone(),
        .dclk(1'b0),
        .dcs(1'b0),
        .dwe(1'b0),
        .di(8'b00000000),
        .daddr(6'b000000),
        .do()
    );
endmodule
