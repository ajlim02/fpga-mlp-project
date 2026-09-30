`timescale 1ns/1ps
`default_nettype none
// 5A | little-endian result bytes | XOR of payload bytes.
// A result is latched on valid_i && ready_o. done_o follows the last stop bit.
module uart_packet_tx #(
    parameter integer N_OUTPUTS=1, OUTPUT_W=32,
    parameter integer CLK_FREQ_HZ=100_000_000, BAUD_RATE=115_200,
    parameter integer CLKS_PER_BIT=CLK_FREQ_HZ/BAUD_RATE
)(
    input wire clk, rst_n,
    input wire [N_OUTPUTS*OUTPUT_W-1:0] result_i,
    input wire valid_i,
    output wire ready_o,
    output reg done_o,
    output wire tx_o
);
    localparam integer PAYLOAD_BYTES=N_OUTPUTS*OUTPUT_W/8;
    localparam integer INDEX_W=$clog2(PAYLOAD_BYTES+2);
    typedef enum logic [1:0] {IDLE,LAUNCH,WAIT_BUSY,WAIT_BYTE} state_t;
    state_t state;
    reg [N_OUTPUTS*OUTPUT_W-1:0] payload;
    reg [INDEX_W-1:0] index;
    reg [7:0] checksum, byte_data;
    wire byte_busy, serial_tx;
    wire byte_start=rst_n && (state==LAUNCH) && !byte_busy;
    assign ready_o=rst_n && (state==IDLE);
    assign tx_o=rst_n ? serial_tx : 1'b1;
    initial begin
        if (N_OUTPUTS<1 || OUTPUT_W<8 || OUTPUT_W%8!=0 || CLKS_PER_BIT<1)
            $fatal(1,"Invalid uart_packet_tx parameters");
    end
    always @* begin
        byte_data=checksum;
        if (index==0) byte_data=8'h5A;
        else if (index<=INDEX_W'(PAYLOAD_BYTES))
            byte_data=payload[(int'(index)-1)*8 +: 8];
    end
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (
        .clk(clk),.rst(!rst_n),.tx_start(byte_start),
        .tx_data(byte_data),.tx(serial_tx),.tx_busy(byte_busy)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; payload<='0; index<='0; checksum<='0; done_o<=0;
        end else begin
            done_o<=0;
            case (state)
                IDLE: if (valid_i && ready_o) begin
                    payload<=result_i; index<='0; checksum<='0; state<=LAUNCH;
                end
                LAUNCH: if (!byte_busy) begin
                    if (index>0 && index<=INDEX_W'(PAYLOAD_BYTES))
                        checksum<=checksum^byte_data;
                    state<=WAIT_BUSY;
                end
                WAIT_BUSY: if (byte_busy) state<=WAIT_BYTE;
                WAIT_BYTE: if (!byte_busy) begin
                    if (index==INDEX_W'(PAYLOAD_BYTES+1)) begin
                        done_o<=1; state<=IDLE;
                    end else begin index<=index+1'b1; state<=LAUNCH; end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
