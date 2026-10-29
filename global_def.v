


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				1000000000/100000000
// Minimum SDRAM timing counts use a conservative 10 ns design base.
// Actual core/SDRAM period is 12 ns. Refresh: 2500 cycles = 30 us.
`define   SELF_REFRESH_INTERVAL			2500

