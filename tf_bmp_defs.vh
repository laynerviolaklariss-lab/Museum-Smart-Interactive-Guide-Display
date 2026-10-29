`ifndef TF_BMP_DEFS_VH
`define TF_BMP_DEFS_VH

`define ERR_NONE             8'h00
`define ERR_SD_CMD0          8'h01
`define ERR_SD_CMD8          8'h02
`define ERR_SD_ACMD41        8'h03
`define ERR_SD_CMD58         8'h04
`define ERR_SD_CMD16         8'h05
`define ERR_SD_CMD17         8'h06
`define ERR_SD_TOKEN         8'h07
`define ERR_SD_DATA_CRC      8'h08
`define ERR_SD_CMD_TIMEOUT   8'h09

`define ERR_FS_SIGNATURE     8'h10
`define ERR_FS_BPS           8'h11
`define ERR_FS_NOT_FAT32     8'h12
`define ERR_FS_CLUSTER       8'h13
`define ERR_FILE_NOT_FOUND   8'h20

`define ERR_BMP_MAGIC        8'h30
`define ERR_BMP_DIB          8'h31
`define ERR_BMP_PLANES       8'h32
`define ERR_BMP_DEPTH        8'h33
`define ERR_BMP_COMPRESSED   8'h34
`define ERR_BMP_SIZE         8'h35
`define ERR_BMP_TRUNCATED    8'h36

`define ERR_SDRAM_NOT_READY  8'h40
`define ERR_SDRAM_RANGE      8'h41
`define ERR_SDRAM_VERIFY     8'h42
`define ERR_SDRAM_WRITE_CNT  8'h43
`define ERR_SDRAM_PROTOCOL   8'h44
`define ERR_SDRAM_SUM        8'h45
`define ERR_SDRAM_CORNER     8'h46
`define ERR_SDRAM_XOR        8'h47
`define ERR_SCALE_RANGE      8'h48
`define ERR_SCALE_PROTOCOL   8'h49
`define ERR_SCALE_STATE      8'h4A
`define ERR_SCALE_OUT_COUNT  8'h4B
`define ERR_SCALE_ROW_COUNT  8'h4C

`endif
