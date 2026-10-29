`timescale 1ns/1ps

// SPI mode 0 byte engine. The clock is generated with clock-enables; all
// registers remain in the clk domain. SCK idles low, data is sampled on the
// rising edge and changed on the falling edge.
module spi_byte_master(
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] half_div,
    input  wire        start,
    input  wire [7:0]  tx_data,
    output reg  [7:0]  rx_data,
    output reg         busy,
    output reg         done,
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso
);
    reg [15:0] div_count;
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;
    reg [3:0] edge_count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_data   <= 8'hFF;
            busy      <= 1'b0;
            done      <= 1'b0;
            spi_sck   <= 1'b0;
            spi_mosi  <= 1'b1;
            div_count <= 16'd0;
            tx_shift  <= 8'hFF;
            rx_shift  <= 8'h00;
            edge_count<= 4'd0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                spi_sck  <= 1'b0;
                spi_mosi <= 1'b1;
                if (start) begin
                    busy       <= 1'b1;
                    div_count  <= (half_div > 0) ? half_div - 1'b1 : 16'd0;
                    tx_shift   <= tx_data;
                    rx_shift   <= 8'h00;
                    edge_count <= 4'd0;
                    spi_mosi   <= tx_data[7];
                end
            end else if (div_count != 0) begin
                div_count <= div_count - 1'b1;
            end else begin
                div_count <= (half_div > 0) ? half_div - 1'b1 : 16'd0;
                if (!spi_sck) begin
                    // Rising edge: card and FPGA sample MOSI/MISO.
                    spi_sck  <= 1'b1;
                    rx_shift <= {rx_shift[6:0], spi_miso};
                    edge_count <= edge_count + 1'b1;
                end else begin
                    // Falling edge: present the next MOSI bit.
                    spi_sck <= 1'b0;
                    if (edge_count == 4'd8) begin
                        busy     <= 1'b0;
                        done     <= 1'b1;
                        rx_data  <= rx_shift;
                        spi_mosi <= 1'b1;
                    end else begin
                        tx_shift <= {tx_shift[6:0],1'b1};
                        spi_mosi <= tx_shift[6];
                    end
                end
            end
        end
    end
endmodule
