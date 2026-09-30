`timescale 1ns/1ps
module tb_uart_packet_tx;
    parameter integer CPB=4;
    reg clk=0, rst_n=0, valid_i=0;
    reg [31:0] result_i=0;
    wire ready_o,done_o,tx_o;
    integer completions=0;
    always #5 clk=~clk;
    uart_packet_tx #(.CLKS_PER_BIT(CPB)) dut (.*);
    always @(posedge clk) if (done_o) completions<=completions+1;
    task automatic expect_byte(input reg [7:0] value);
        reg [9:0] frame;
        frame={1'b1,value,1'b0};
        @(negedge tx_o); #1;
        for (int c=0;c<10*CPB;c++) begin
            if (tx_o!==frame[c/CPB] || ready_o || done_o)
                $fatal(1,"Packet TX bit/duration/handshake error");
            @(posedge clk); #1;
        end
    endtask
    task automatic check_result(input reg [31:0] value);
        reg [7:0] checkbyte;
        checkbyte=value[7:0]^value[15:8]^value[23:16]^value[31:24];
        fork
            begin
                @(negedge clk); result_i=value; valid_i=1;
                @(negedge clk); valid_i=0; result_i=~value;
                // A pulse during busy must not overwrite or queue a packet.
                repeat(3) @(negedge clk);
                valid_i=1; @(negedge clk); valid_i=0;
            end
            begin
                expect_byte(8'h5A);
                for (int b=0;b<4;b++) expect_byte(value[b*8 +: 8]);
                expect_byte(checkbyte);
            end
        join
        wait(done_o); @(negedge clk);
        if (!ready_o) $fatal(1,"TX did not return ready");
        @(negedge clk);
        if (done_o) $fatal(1,"TX done is not a pulse");
        repeat(12*CPB) @(negedge clk);
        if (tx_o!==1 || !ready_o) $fatal(1,"Busy input unexpectedly queued");
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        check_result(32'h12345678);
        check_result(32'hffffffff);
        check_result(32'h80000000);
        check_result(32'h00000000);
        check_result(32'h5aa5817f);
        if (completions!=5) $fatal(1,"Completion count mismatch");
        // Reset in a packet, then accept a fresh result.
        @(negedge clk); result_i=32'h55aa55aa; valid_i=1;
        @(negedge clk); valid_i=0;
        @(negedge tx_o); repeat(3*CPB) @(negedge clk);
        rst_n=0; #1;
        if (tx_o!==1 || ready_o || done_o) $fatal(1,"TX reset failed");
        repeat(3) @(negedge clk); rst_n=1;
        check_result(32'h87654321);
        if (completions!=6) $fatal(1,"Reset produced stale completion");
        $display("PASS: packet TX framing, latching, busy rejection, reset; CPB=%0d",CPB);
        $finish;
    end
    initial begin #10_000_000; $fatal(1,"Packet TX watchdog"); end
endmodule
