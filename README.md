# Museum Smart Interactive Guide Display

基于安路 EG4S20BG256 FPGA 的博物馆互动导览屏参赛源码。

## 提交内容

本仓库收录参赛提交目录“代码”中的 60 个文件，并添加本说明。原始源码、约束和字库保持原样；不包含本地 `.git` 历史、账号凭据、作品视频、图片素材或其他提交文档。

- 顶层模块：`TfBmpImg0001Top`，对应 `tf_bmp_img0001_top.v`。
- 硬件平台：硬木 EG4S20，核心器件 EG4S20BG256。
- 设计语言：Verilog 与 SystemVerilog。
- 开发工具：安路 Tang Dynasty（TD）。

## 文件结构

所有提交文件保持原目录的平铺结构。

| 模块方向 | 主要文件 |
| --- | --- |
| TF 卡与文件系统 | `spi_byte_master.v`、`sd_cmd_engine.v`、`sd_spi_host.v`、`fat32_file_locator.v`、`fat32_file_stream.v` |
| BMP 解析与缩放 | `bmp24_parser.v`、`bmp_stream_scaler.v` |
| SDRAM 与缓存 | `sdr_*.enc.v`、`sdram_frame_verify.v`、`pixel_fifo.v`、`video_async_fifo.v` |
| HDMI 音视频 | `hdmi.sv`、`hdmi_framebuffer.sv`、`packet_*.sv`、`audio_*.v`、`audio_*.sv` 等 |
| 字幕与图层 | `osd_*.v`、`anlogic_logo_rom.v`、`museum_compare_*.v` |
| LCD 与交互 | `lcd_*.v`、`museum_key_matrix.v`、`image_adjust_control.v` 等 |
| 工程约束 | `tf_bmp_img0001.adc`、`tf_bmp_img0001.sdc` |

## 字库与工程设置

以下初始化文件必须与源码一起保留，并确保 TD 构建时能从模块中指定的相对路径找到它们：

- `museum_font_bank0.dat`
- `museum_font_bank1.dat`
- `lcd_ui_font.dat`

`.sv` 文件需要按 SystemVerilog 编译。器件原语及厂商控制器需要相应安路工具支持，不能仅凭通用 Verilog 编译器完成上板构建。

本次按要求仅提交代码目录，其中没有 TD `.al` 工程文件、构建脚本或 `.bit` 镜像。本仓库不是可直接双击 `.al` 打开的完整工程备份；重建时需要在 TD 中设置器件和顶层，加入源码、初始化资产及 ADC/SDC 约束，并核对目标硬件连接。

## 来源说明

保留源码中原有的作者和厂商注释。项目含安路 SDRAM 控制器与带有原作者标注的 HDMI 模块。公开上传不改变这些模块原有的权利归属或许可要求；本仓库未统一改授 MIT 等开源许可证。
