`timescale 1ns/1ps
`include "tf_bmp_defs.vh"

// Locates IMG0001.BMP through IMG0013.BMP, or MUSIC001.PCM, in the FAT32
// root directory. target_music selects the 8.3 music name; otherwise
// target_index selects the decimal image number (0 -> 1, ... 12 -> 13).
// The module owns a 512-byte
// sector buffer and uses an abstract read-sector service supplied by the SD
// host, keeping filesystem parsing independent of SPI timing.
module fat32_file_locator(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        target_music,
    input  wire [3:0]  target_index,
    output reg         sec_req,
    output reg  [31:0] sec_lba,
    input  wire        sec_busy,
    input  wire        sec_data_valid,
    input  wire [8:0]  sec_data_index,
    input  wire [7:0]  sec_data_byte,
    input  wire        sec_done,
    input  wire        sec_error,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] max_cluster,
    output reg  [31:0] file_first_cluster,
    output reg  [31:0] file_size
);
    // Capture only the BPB/MBR bytes actually consumed. Directory and FAT
    // records already have tagged streaming captures; no 512-byte read mux.
    reg [15:0] bpb_bps,bpb_reserved,bpb_total16,bpb_signature;
    reg [31:0] bpb_total32,bpb_fat,bpb_root;
    reg [7:0] bpb_spc,bpb_nfats;
    reg [7:0] part_types[0:3];reg [31:0] part_lbas[0:3];
    wire [7:0] sector[0:511]; // retained diagnostic signature aliases
    assign sector[13]=bpb_spc;assign sector[16]=bpb_nfats;
    assign sector[510]=bpb_signature[7:0];assign sector[511]=bpb_signature[15:8];
    localparam [4:0] S_IDLE=0,S_LBA0_REQ=1,S_LBA0_WAIT=2,S_LBA0_PARSE=3,
        S_PART_SCAN=4,S_BOOT_REQ=5,S_BOOT_WAIT=6,S_BOOT_PARSE=7,
        S_DIR_REQ=8,S_DIR_WAIT=9,S_DIR_SCAN=10,S_DIR_ADV=11,
        S_FAT_REQ=12,S_FAT_WAIT=13,S_FAT_PARSE=14,S_DONE=15,S_ERROR=16,
        S_BOOT_CALC1=17,S_BOOT_CALC2=18,S_BOOT_CALC3=19,
        S_DIR_ADDR1=20,S_DIR_ADDR2=21,S_DIR_CHECK=22,S_PART_FETCH=23,S_BOOT_CALC4=24;
    reg [4:0] state;
    reg [31:0] partition_lba;
    reg [31:0] root_cluster,current_cluster;
    reg [7:0] sector_in_cluster;
    reg [4:0] dir_entry;
    reg [1:0] part_index;
    reg [7:0] part_type;reg [31:0] part_lba_capture;
    reg [31:0] total_sectors,fat_sectors;
    reg [15:0] reserved_sectors;
    reg [7:0] number_of_fats;
    reg [31:0] cluster_count;
    reg [31:0] fat_area_sectors;
    reg [8:0] fat_byte_offset;
    reg [31:0] fat_entry_capture;
    reg [31:0] cluster_sector_offset,cluster_base_lba;
    reg [7:0] selected_first,selected_attrs;
    reg selected_match,selected_bmp_ext;
    reg [31:0] selected_cluster,selected_size;
    reg dir_match[0:15],dir_bmp_ext[0:15];
    reg [7:0] dir_first[0:15],dir_attrs[0:15];
    reg [15:0] dir_hi[0:15],dir_lo[0:15];
    reg [31:0] dir_sizes[0:15];
    reg name_valid;
    reg [7:0] name_upper,name_expected;
    reg [3:0] name_position,name_slot;
    reg name_valid2,name_equal;
    reg [3:0] name_position2,name_slot2;
    function [15:0] le16;
        input integer a;
        begin case(a)11:le16=bpb_bps;14:le16=bpb_reserved;19:le16=bpb_total16;510:le16=bpb_signature;default:le16=0;endcase end
    endfunction
    function [31:0] le32;
        input integer a;
        begin case(a)32:le32=bpb_total32;36:le32=bpb_fat;44:le32=bpb_root;default:le32=0;endcase end
    endfunction
    // FAT32 8.3 short names are case-insensitive. Normalize a-z to A-Z.
    function [7:0] to_upper;
        input [7:0] ch;
        begin
            if(ch>=8'h61 && ch<=8'h7A) to_upper=ch-8'h20;
            else to_upper=ch;
        end
    endfunction
    function is_fat32_type;
        input [7:0] t;
        begin is_fat32_type=(t==8'h0B)||(t==8'h0C)||(t==8'h1B)||(t==8'h1C); end
    endfunction
    function is_power_two_spc;
        input [7:0] v;
        begin is_power_two_spc=(v!=0)&&((v&(v-1'b1))==0)&&(v<=128); end
    endfunction
    function [2:0] spc_shift;
        input [7:0] v;
        begin
            case(v)
                8'd1:spc_shift=0;8'd2:spc_shift=1;8'd4:spc_shift=2;8'd8:spc_shift=3;
                8'd16:spc_shift=4;8'd32:spc_shift=5;8'd64:spc_shift=6;
                default:spc_shift=7;
            endcase
        end
    endfunction
    function [7:0] expected_name_char;
        input [3:0] n;
        input       music;
        input [3:0] image;
        begin
            if(music&&image[3:1]==3'b111)begin
                case(n)
                    0:expected_name_char="G";1:expected_name_char="U";2:expected_name_char="I";
                    3:expected_name_char="D";4:expected_name_char="E";5:expected_name_char="0";
                    6:expected_name_char="0";7:expected_name_char=image[0]?"1":"0";8:expected_name_char="V";
                    9:expected_name_char="I";default:expected_name_char="D";
                endcase
            end else if(music) begin
                case(n)
                    0:expected_name_char="M"; 1:expected_name_char="U";
                    2:expected_name_char="S"; 3:expected_name_char="I";
                    4:expected_name_char="C"; 5:expected_name_char="0";
                    6:expected_name_char="0"; 7:expected_name_char="1";
                    8:expected_name_char="P"; 9:expected_name_char="C";
                    default:expected_name_char="M";
                endcase
            end else begin
                case(n)
                    0:expected_name_char="I"; 1:expected_name_char="M";
                    2:expected_name_char="G"; 3:expected_name_char="0";
                    4:expected_name_char="0";
                    5:expected_name_char=(image>=9)?"1":"0";
                    6:expected_name_char=(image>=9)?(8'd39+image):(8'd49+image);
                    7:expected_name_char=" "; 8:expected_name_char="B";
                    9:expected_name_char="M"; default:expected_name_char="P";
                endcase
            end
        end
    endfunction
    function [31:0] cluster_lba;
        input [31:0] c;
        begin cluster_lba=data_start_lba+((c-2)<<spc_shift(sectors_per_cluster)); end
    endfunction

    task fail;
        input [7:0] code;
        begin error<=1; error_code<=code; busy<=0; state<=S_ERROR; end
    endtask

    // Only the eleven name bytes are retimed. All metadata remains on the
    // proven path. Normalize, compare, then write the match result; the
    // final result is retired by entry byte 12, well before directory scan.
    always @(posedge clk or posedge rst)begin
        if(rst)begin name_valid<=0;name_upper<=0;name_expected<=0;name_position<=0;name_slot<=0;
            name_valid2<=0;name_equal<=0;name_position2<=0;name_slot2<=0;end
        else begin
            name_valid<=sec_data_valid&&state==S_DIR_WAIT&&sec_data_index[4:0]<=10;
            name_valid2<=name_valid;
            if(name_valid)begin name_equal<=name_upper==name_expected;name_position2<=name_position;name_slot2<=name_slot;end
            if(sec_data_valid&&state==S_DIR_WAIT&&sec_data_index[4:0]<=10)begin
                name_upper<=to_upper(sec_data_byte);
                name_expected<=expected_name_char(sec_data_index[3:0],target_music,target_index);
                name_position<=sec_data_index[3:0];name_slot<=sec_data_index[8:5];
            end
        end
    end
    always @(posedge clk)begin
        if(!rst&&name_valid2)begin
            case(name_position2)
                0:begin dir_match[name_slot2]<=name_equal;dir_bmp_ext[name_slot2]<=1;end
                1,2,3,4,5,6,7:if(!name_equal)dir_match[name_slot2]<=0;
                8,9,10:if(!name_equal)begin dir_match[name_slot2]<=0;dir_bmp_ext[name_slot2]<=0;end
            endcase
        end
    end
    integer base;
    reg [31:0] data_sectors,next_cluster;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=S_IDLE; sec_req<=0; sec_lba<=0; busy<=0; done<=0;
            error<=0; error_code<=`ERR_NONE; partition_lba<=0;
            fat_start_lba<=0; data_start_lba<=0; sectors_per_cluster<=0;
            max_cluster<=0; file_first_cluster<=0; file_size<=0;
            root_cluster<=0; current_cluster<=0; sector_in_cluster<=0;
            part_type<=0;part_lba_capture<=0;
            dir_entry<=0; part_index<=0; total_sectors<=0; fat_sectors<=0;
            reserved_sectors<=0; number_of_fats<=0; cluster_count<=0;
            data_sectors<=0; next_cluster<=0;
            fat_area_sectors<=0;
            fat_byte_offset<=0;fat_entry_capture<=0;
            cluster_sector_offset<=0;cluster_base_lba<=0;
            bpb_bps<=0;bpb_reserved<=0;bpb_total16<=0;bpb_signature<=0;
            bpb_total32<=0;bpb_fat<=0;bpb_root<=0;bpb_spc<=0;bpb_nfats<=0;
            part_types[0]<=0;part_types[1]<=0;part_types[2]<=0;part_types[3]<=0;
            part_lbas[0]<=0;part_lbas[1]<=0;part_lbas[2]<=0;part_lbas[3]<=0;
            selected_first<=0;selected_attrs<=0;selected_match<=0;selected_bmp_ext<=0;
            selected_cluster<=0;selected_size<=0;
        end else begin
            sec_req<=0; done<=0;
            if(sec_data_valid) begin
                if(state==S_LBA0_WAIT||state==S_BOOT_WAIT)begin
                    case(sec_data_index)
                        11:bpb_bps[7:0]<=sec_data_byte;
                        12:bpb_bps[15:8]<=sec_data_byte;
                        14:bpb_reserved[7:0]<=sec_data_byte;
                        15:bpb_reserved[15:8]<=sec_data_byte;
                        19:bpb_total16[7:0]<=sec_data_byte;
                        20:bpb_total16[15:8]<=sec_data_byte;
                        510:bpb_signature[7:0]<=sec_data_byte;
                        511:bpb_signature[15:8]<=sec_data_byte;
                        32:bpb_total32[7:0]<=sec_data_byte;
                        33:bpb_total32[15:8]<=sec_data_byte;
                        34:bpb_total32[23:16]<=sec_data_byte;
                        35:bpb_total32[31:24]<=sec_data_byte;
                        36:bpb_fat[7:0]<=sec_data_byte;
                        37:bpb_fat[15:8]<=sec_data_byte;
                        38:bpb_fat[23:16]<=sec_data_byte;
                        39:bpb_fat[31:24]<=sec_data_byte;
                        44:bpb_root[7:0]<=sec_data_byte;
                        45:bpb_root[15:8]<=sec_data_byte;
                        46:bpb_root[23:16]<=sec_data_byte;
                        47:bpb_root[31:24]<=sec_data_byte;
                        13:bpb_spc<=sec_data_byte;
                        16:bpb_nfats<=sec_data_byte;
                        450:part_types[0]<=sec_data_byte;
                        454:part_lbas[0][7:0]<=sec_data_byte;
                        455:part_lbas[0][15:8]<=sec_data_byte;
                        456:part_lbas[0][23:16]<=sec_data_byte;
                        457:part_lbas[0][31:24]<=sec_data_byte;
                        466:part_types[1]<=sec_data_byte;
                        470:part_lbas[1][7:0]<=sec_data_byte;
                        471:part_lbas[1][15:8]<=sec_data_byte;
                        472:part_lbas[1][23:16]<=sec_data_byte;
                        473:part_lbas[1][31:24]<=sec_data_byte;
                        482:part_types[2]<=sec_data_byte;
                        486:part_lbas[2][7:0]<=sec_data_byte;
                        487:part_lbas[2][15:8]<=sec_data_byte;
                        488:part_lbas[2][23:16]<=sec_data_byte;
                        489:part_lbas[2][31:24]<=sec_data_byte;
                        498:part_types[3]<=sec_data_byte;
                        502:part_lbas[3][7:0]<=sec_data_byte;
                        503:part_lbas[3][15:8]<=sec_data_byte;
                        504:part_lbas[3][23:16]<=sec_data_byte;
                        505:part_lbas[3][31:24]<=sec_data_byte;
                    endcase
                end
                if(state==S_FAT_WAIT) begin
                    if(sec_data_index==fat_byte_offset)fat_entry_capture[7:0]<=sec_data_byte;
                    if(sec_data_index==fat_byte_offset+1'b1)fat_entry_capture[15:8]<=sec_data_byte;
                    if(sec_data_index==fat_byte_offset+2'd2)fat_entry_capture[23:16]<=sec_data_byte;
                    if(sec_data_index==fat_byte_offset+2'd3)fat_entry_capture[31:24]<=sec_data_byte;
                end
                if(state==S_DIR_WAIT) begin
                    case(sec_data_index[4:0])
                        0:dir_first[sec_data_index[8:5]]<=sec_data_byte;
                        11:dir_attrs[sec_data_index[8:5]]<=sec_data_byte;
                        20:dir_hi[sec_data_index[8:5]][7:0]<=sec_data_byte;
                        21:dir_hi[sec_data_index[8:5]][15:8]<=sec_data_byte;
                        26:dir_lo[sec_data_index[8:5]][7:0]<=sec_data_byte;
                        27:dir_lo[sec_data_index[8:5]][15:8]<=sec_data_byte;
                        28:dir_sizes[sec_data_index[8:5]][7:0]<=sec_data_byte;
                        29:dir_sizes[sec_data_index[8:5]][15:8]<=sec_data_byte;
                        30:dir_sizes[sec_data_index[8:5]][23:16]<=sec_data_byte;
                        31:dir_sizes[sec_data_index[8:5]][31:24]<=sec_data_byte;
                    endcase
                end
            end
            if(sec_error && busy) fail(`ERR_SD_CMD17);
            else case(state)
                S_IDLE: if(start) begin
                    busy<=1; error<=0; error_code<=`ERR_NONE; part_index<=0;
                    state<=S_LBA0_REQ;
                end
                S_LBA0_REQ: if(!sec_busy) begin sec_lba<=0; sec_req<=1; state<=S_LBA0_WAIT; end
                S_LBA0_WAIT: if(sec_done) state<=S_LBA0_PARSE;
                S_LBA0_PARSE: begin
                    if(le16(510)!=16'hAA55) fail(`ERR_FS_SIGNATURE);
                    // A plausible BPB means the volume starts at LBA0.
                    else if(le16(11)==512 && is_power_two_spc(sector[13]) && le16(14)!=0) begin
                        partition_lba<=0; state<=S_BOOT_PARSE;
                    end else begin part_index<=0; state<=S_PART_FETCH; end
                end
                S_PART_FETCH: begin
                    part_type<=part_types[part_index];part_lba_capture<=part_lbas[part_index];
                    state<=S_PART_SCAN;
                end
                S_PART_SCAN: begin
                    if(is_fat32_type(part_type) && part_lba_capture!=0) begin
                        partition_lba<=part_lba_capture; sec_lba<=part_lba_capture;
                        state<=S_BOOT_REQ;
                    end else if(part_index==3) fail(`ERR_FS_NOT_FAT32);
                    else begin part_index<=part_index+1'b1;state<=S_PART_FETCH;end
                end
                S_BOOT_REQ: if(!sec_busy) begin sec_req<=1; state<=S_BOOT_WAIT; end
                S_BOOT_WAIT: if(sec_done) state<=S_BOOT_PARSE;
                S_BOOT_PARSE: begin
                    if(le16(510)!=16'hAA55) fail(`ERR_FS_SIGNATURE);
                    else if(le16(11)!=512) fail(`ERR_FS_BPS);
                    else if(!is_power_two_spc(sector[13]) || le16(14)==0 ||
                            sector[16]==0 || sector[16]>4 || le32(36)==0 || le32(44)<2)
                        fail(`ERR_FS_NOT_FAT32);
                    else begin
                        sectors_per_cluster<=sector[13];
                        reserved_sectors<=le16(14); number_of_fats<=sector[16];
                        fat_sectors<=le32(36); root_cluster<=le32(44);
                        total_sectors<=(le16(19)!=0)?le16(19):le32(32);
                        fat_start_lba<=partition_lba+le16(14);
                        state<=S_BOOT_CALC1;
                    end
                end
                S_BOOT_CALC1: begin
                    case(number_of_fats)
                        1:fat_area_sectors<=fat_sectors;
                        2:fat_area_sectors<=fat_sectors<<1;
                        3:fat_area_sectors<=(fat_sectors<<1)+fat_sectors;
                        default:fat_area_sectors<=fat_sectors<<2;
                    endcase
                    state<=S_BOOT_CALC2;
                end
                S_BOOT_CALC2: begin
                    data_start_lba<=partition_lba+reserved_sectors+fat_area_sectors;
                    data_sectors<=total_sectors-reserved_sectors-fat_area_sectors;
                    state<=S_BOOT_CALC3;
                end
                S_BOOT_CALC3: begin
                    cluster_count<=data_sectors>>spc_shift(sectors_per_cluster);
                    state<=S_BOOT_CALC4;
                end
                S_BOOT_CALC4: begin
                    max_cluster<=cluster_count+1'b1;
                    current_cluster<=root_cluster;sector_in_cluster<=0;state<=S_DIR_ADDR1;
                end
                S_DIR_ADDR1: begin
                    cluster_sector_offset<=(current_cluster-2)<<spc_shift(sectors_per_cluster);
                    state<=S_DIR_ADDR2;
                end
                S_DIR_ADDR2: begin
                    cluster_base_lba<=data_start_lba+cluster_sector_offset;
                    state<=S_DIR_REQ;
                end
                S_DIR_REQ: if(!sec_busy) begin
                    sec_lba<=cluster_base_lba+sector_in_cluster;
                    sec_req<=1; dir_entry<=0; state<=S_DIR_WAIT;
                end
                S_DIR_WAIT: if(sec_done) state<=S_DIR_SCAN;
                S_DIR_SCAN: begin
                    selected_first<=dir_first[dir_entry];
                    selected_attrs<=dir_attrs[dir_entry];
                    selected_match<=dir_match[dir_entry];
                    selected_bmp_ext<=dir_bmp_ext[dir_entry];
                    selected_cluster<={dir_hi[dir_entry],dir_lo[dir_entry]};
                    selected_size<=dir_sizes[dir_entry];
                    state<=S_DIR_CHECK;
                end
                S_DIR_CHECK: begin
                    if(selected_first==8'h00) fail(`ERR_FILE_NOT_FOUND);
                    else if(selected_first!=8'hE5 && selected_attrs!=8'h0F &&
                            !selected_attrs[3] && !selected_attrs[4] && selected_match) begin
                        file_first_cluster<=selected_cluster;
                        file_size<=selected_size;
                        if(selected_cluster<2 || selected_size==0)
                            fail(`ERR_FS_CLUSTER);
                        else state<=S_DONE;
                    end else begin
                        if(dir_entry==15) state<=S_DIR_ADV;
                        else begin
                            dir_entry<=dir_entry+1'b1;
                            // Reload the newly selected array entry.  Staying
                            // in S_DIR_CHECK repeats entry 0 sixteen times.
                            state<=S_DIR_SCAN;
                        end
                    end
                end
                S_DIR_ADV: begin
                    if(sector_in_cluster+1'b1<sectors_per_cluster) begin
                        sector_in_cluster<=sector_in_cluster+1'b1; state<=S_DIR_REQ;
                    end else state<=S_FAT_REQ;
                end
                S_FAT_REQ: if(!sec_busy) begin
                    sec_lba<=fat_start_lba+(current_cluster>>7);
                    fat_byte_offset<={current_cluster[6:0],2'b00};fat_entry_capture<=0;
                    sec_req<=1; state<=S_FAT_WAIT;
                end
                S_FAT_WAIT: if(sec_done) state<=S_FAT_PARSE;
                S_FAT_PARSE: begin
                    next_cluster=fat_entry_capture&32'h0FFFFFFF;
                    if(next_cluster>=32'h0FFFFFF8) fail(`ERR_FILE_NOT_FOUND);
                    else if(next_cluster<2 || next_cluster==32'h0FFFFFF7 ||
                            next_cluster>max_cluster) fail(`ERR_FS_CLUSTER);
                        else begin current_cluster<=next_cluster; sector_in_cluster<=0; state<=S_DIR_ADDR1; end
                end
                S_DONE: begin busy<=0; done<=1; state<=S_IDLE; end
                S_ERROR: busy<=0;
                default: fail(`ERR_FS_NOT_FAT32);
            endcase
        end
    end
endmodule
