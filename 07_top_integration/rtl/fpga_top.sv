`timescale 1ns/1ps
`default_nettype none
// UART request -> buffered features -> real mlp_top -> UART response.
module fpga_top #(
    parameter integer N_FEATURES=5, FEATURE_W=8, N_OUTPUTS=1, OUTPUT_W=32,
    parameter integer CLK_FREQ_HZ=100_000_000, BAUD_RATE=115_200,
    parameter integer CLKS_PER_BIT=CLK_FREQ_HZ/BAUD_RATE,
    parameter L1_WMEM_FILE="wmem_l1.mem", L1_BMEM_FILE="bmem_l1.mem",
    parameter L2_WMEM_FILE="wmem_l2.mem", L2_BMEM_FILE="bmem_l2.mem",
    parameter L3_WMEM_FILE="wmem_l3.mem", L3_BMEM_FILE="bmem_l3.mem"
)(
    input wire clk, reset_n, uart_rx_i,
    output wire uart_tx_o, busy,
    output reg done, error
);
    localparam integer ADDR_W=(N_FEATURES>1)?$clog2(N_FEATURES):1;
    localparam integer VEC_W=N_FEATURES*FEATURE_W;
    typedef enum logic [2:0] {
        IDLE, STORE_FEATURES, START_CORE, WAIT_CORE, SEND_RESULT, WAIT_TX
    } state_t;
    state_t state;
    wire rst_n;
    wire [VEC_W-1:0] rx_features;
    wire rx_valid, rx_ready, rx_error;
    reg [VEC_W-1:0] features_hold;
    reg [ADDR_W-1:0] feature_idx;
    wire feature_wr_en=rst_n && (state==STORE_FEATURES);
    wire signed [FEATURE_W-1:0] feature_wr_data=
        $signed(features_hold[feature_idx*FEATURE_W +: FEATURE_W]);
    wire mlp_busy, mlp_done;
    wire signed [31:0] mlp_result;
    wire mlp_start=rst_n && (state==START_CORE) && !mlp_busy;
    reg [31:0] result_hold;
    wire tx_ready, tx_done;
    wire tx_valid=rst_n && (state==SEND_RESULT);

    // Current core has fixed 16/8 hidden layers and a single int32 result.
    initial begin
        if (N_FEATURES<1 || N_FEATURES>16 || FEATURE_W!=8 ||
            N_OUTPUTS!=1 || OUTPUT_W!=32 || CLKS_PER_BIT<4)
            $fatal(1,"Requires 1..16 int8 features, one int32 result, CLKS_PER_BIT >= 4");
    end
    assign busy=rst_n && (state!=IDLE);
    assign rx_ready=rst_n && (state==IDLE) && !mlp_busy;
    reset_sync u_reset (.clk(clk),.async_rst_n(reset_n),.rst_n(rst_n));
    uart_packet_rx #(
        .N_FEATURES(N_FEATURES),.FEATURE_W(FEATURE_W),
        .CLK_FREQ_HZ(CLK_FREQ_HZ),.BAUD_RATE(BAUD_RATE),.CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_packet_rx (
        .clk(clk),.rst_n(rst_n),.rx_i(uart_rx_i),
        .features_o(rx_features),.valid_o(rx_valid),.ready_i(rx_ready),.error_o(rx_error)
    );
    // mlp_top owns the feature buffer, controller and result register.
    mlp_top #(
        .N_INPUTS(N_FEATURES),.FEATURE_W(FEATURE_W),.FEAT_ADDR_W(ADDR_W),.ACC_W(32),
        .L1_WMEM_FILE(L1_WMEM_FILE),.L1_BMEM_FILE(L1_BMEM_FILE),
        .L2_WMEM_FILE(L2_WMEM_FILE),.L2_BMEM_FILE(L2_BMEM_FILE),
        .L3_WMEM_FILE(L3_WMEM_FILE),.L3_BMEM_FILE(L3_BMEM_FILE)
    ) u_mlp_top (
        .i_clk(clk),.i_rstn(rst_n),.i_mlp_start(mlp_start),
        .o_mlp_busy(mlp_busy),.o_mlp_done(mlp_done),
        .i_feat_wr_en(feature_wr_en),.i_feat_wr_addr(feature_idx),
        .i_feat_wr_data(feature_wr_data),.o_soh_data(mlp_result)
    );
    uart_packet_tx #(.OUTPUT_W(32),.CLKS_PER_BIT(CLKS_PER_BIT)) u_packet_tx (
        .clk(clk),.rst_n(rst_n),.result_i(result_hold),.valid_i(tx_valid),
        .ready_o(tx_ready),.done_o(tx_done),.tx_o(uart_tx_o)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE;
            features_hold<='0;
            feature_idx<='0;
            result_hold<='0;
            done<=0;
            error<=0;
        end else begin
            done<=0;
            if (rx_error) error<=1; // Sticky until reset; permits later valid requests.
            case (state)
                IDLE: if (rx_valid && rx_ready) begin
                    features_hold<=rx_features;
                    feature_idx<='0;
                    state<=STORE_FEATURES;
                end
                STORE_FEATURES: begin
                    if (feature_idx==ADDR_W'(N_FEATURES-1)) begin
                        feature_idx<='0;
                        state<=START_CORE;
                    end else feature_idx<=feature_idx+1'b1;
                end
                // Final feature was written on the previous rising edge.
                START_CORE: if (!mlp_busy) state<=WAIT_CORE;
                WAIT_CORE: if (mlp_done) begin
                    result_hold<=mlp_result;
                    state<=SEND_RESULT;
                end
                SEND_RESULT: if (tx_ready) state<=WAIT_TX;
                WAIT_TX: if (tx_done) begin
                    state<=IDLE;
                    done<=1; // Checksum stop bit has fully completed.
                end
                default: begin state<=IDLE; error<=1; end
            endcase
        end
    end
endmodule
`default_nettype wire
