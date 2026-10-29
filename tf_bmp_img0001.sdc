create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]
derive_clocks
# Tighten the system-clock hold target beyond TD's default uncertainty.
# This makes short BRAM address paths visible to physical hold repair;
# it does not exempt paths or lower the operating clock frequency.
set_clock_uncertainty -hold 0.200 [get_clocks {u_pll/pll_inst.clkc[1]}]
# The existing HDMI audio divider is not a PLL output: explicitly constrain
# its registers at 125 MHz / 2604. Do not change the proven divider or ACR.
create_generated_clock -name clk_audio_48k -source [get_pins {u_video/u_hdmi_pll/u_pll.clkc[1]}] -master_clock {u_video/u_hdmi_pll/u_pll.clkc[1]} -divide_by 2604 [get_nets {u_video/clk_audio}]
# Every audio<->system/pixel transfer uses a Gray-pointer FIFO or a held
# bundled-data/toggle synchronizer (HDMI PCM/ACR and mode request/ACK).
# Only these domain crossings are excluded, not any intra-domain datapaths.
set_clock_groups -asynchronous -group [get_clocks {clk_audio_48k}] -group [get_clocks {u_pll/pll_inst.clkc[1] u_video/u_hdmi_pll/u_pll.clkc[2]}]
# Two independent PLLs: the SDRAM/system PLL and the HDMI PLL do not
# provide a guaranteed inter-PLL phase relationship. Their crossings use
# two-flop toggle synchronizers, held request/ack mailboxes, Gray FIFOs,
# or true dual-clock BRAM with ready/consumed ownership handshakes.
# Keep 100MHz <-> system-PLL 25MHz synchronous; keep HDMI 25MHz <->
# HDMI 125MHz synchronous. Do not exclude either intra-PLL datapath.
set_clock_groups -asynchronous -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[1] u_pll/pll_inst.clkc[2]}] -group [get_clocks {u_video/u_hdmi_pll/u_pll.clkc[0] u_video/u_hdmi_pll/u_pll.clkc[1] u_video/u_hdmi_pll/u_pll.clkc[2]}]
set_false_path -from [get_clocks {u_pll/pll_inst.clkc[2]}] -to [get_clocks {u_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_pll/pll_inst.clkc[1]}] -to [get_clocks {u_pll/pll_inst.clkc[2]}]
