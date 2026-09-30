`timescale 1ns/1ps
module tb_fpga_top;
    parameter integer CPB=16;
    reg clk=0, reset_n=0, rx=1;
    always #5 clk=~clk;
    wire tx,busy,done,error;
    reg [39:0] vectors[0:23];
    reg [31:0] expected[0:23];
    integer done_count=0, start_count=0;
    reg previous_done=0;
    fpga_top #(
        .CLKS_PER_BIT(CPB),
        .L1_WMEM_FILE("07_top_integration/tb/mem/wmem_l1.mem"),
        .L1_BMEM_FILE("07_top_integration/tb/mem/bmem_l1.mem"),
        .L2_WMEM_FILE("07_top_integration/tb/mem/wmem_l2.mem"),
        .L2_BMEM_FILE("07_top_integration/tb/mem/bmem_l2.mem"),
        .L3_WMEM_FILE("07_top_integration/tb/mem/wmem_l3.mem"),
        .L3_BMEM_FILE("07_top_integration/tb/mem/bmem_l3.mem")
    ) dut (.clk(clk),.reset_n(reset_n),.uart_rx_i(rx),
           .uart_tx_o(tx),.busy(busy),.done(done),.error(error));

    always @(posedge clk) begin
        if (dut.rst_n && dut.mlp_start) start_count<=start_count+1;
        #1;
        if (done) begin
            if (previous_done || busy || tx!==1 || dut.u_packet_tx.byte_busy)
                $fatal(1,"Invalid completion pulse or premature completion");
            done_count=done_count+1;
        end
        previous_done=done;
    end

    task automatic reset_dut;
        @(negedge clk); #2; reset_n=0; rx=1;
        #1;
        if (dut.rst_n!==0 || tx!==1 || busy!==0) $fatal(1,"Async reset failed");
        repeat(3) @(negedge clk);
        reset_n=1;
        @(posedge clk); #1;
        if (dut.rst_n!==0) $fatal(1,"Reset released early");
        @(posedge clk); #1;
        if (dut.rst_n!==1) $fatal(1,"Reset release failed");
        repeat(3) @(negedge clk);
        if (busy || done || error) $fatal(1,"Reset did not clear status");
    endtask

    task automatic send_byte(input reg [7:0] value,input bit bad_stop=0);
        @(negedge clk); rx=0;
        repeat(CPB) @(negedge clk);
        for (int b=0;b<8;b++) begin
            rx=value[b]; repeat(CPB) @(negedge clk);
        end
        rx=!bad_stop; repeat(CPB) @(negedge clk);
        rx=1;
    endtask
    task automatic send_packet(input reg [39:0] value,input bit corrupt=0);
        reg [7:0] checksum;
        checksum=0;
        send_byte(8'hA5);
        for (int b=0;b<5;b++) begin
            send_byte(value[b*8 +: 8]);
            checksum=checksum^value[b*8 +: 8];
        end
        send_byte(checksum^{7'b0,corrupt});
    endtask

    // Independent serial-pin checker: every clock of every 8N1 frame.
    task automatic expect_byte(input reg [7:0] value);
        reg [9:0] frame;
        frame={1'b1,value,1'b0};
        @(negedge tx); #1;
        for (int c=0;c<10*CPB;c++) begin
            if (tx!==frame[c/CPB]) $fatal(1,"TX frame mismatch byte=%h cycle=%0d",value,c);
            if (!busy || done) $fatal(1,"Busy ended before final stop bit");
            @(posedge clk); #1;
        end
    endtask
    task automatic expect_packet(input reg [31:0] value);
        reg [7:0] checksum;
        checksum=0;
        expect_byte(8'h5A);
        for (int b=0;b<4;b++) begin
            expect_byte(value[b*8 +: 8]);
            checksum=checksum^value[b*8 +: 8];
        end
        expect_byte(checksum);
    endtask
    task automatic exchange(input integer index);
        integer before_done,before_start;
        before_done=done_count; before_start=start_count;
        fork
            send_packet(vectors[index]);
            expect_packet(expected[index]);
        join
        wait(done); @(negedge clk);
        if (done_count!=before_done+1 || start_count!=before_start+1)
            $fatal(1,"Duplicate or missing inference");
        repeat(4) @(negedge clk);
    endtask
    task automatic check_quiet(input integer old_starts,input integer old_done);
        repeat(12*CPB) @(negedge clk);
        if (busy || tx!==1 || start_count!=old_starts || done_count!=old_done)
            $fatal(1,"Rejected/aborted request caused work");
    endtask

    initial begin
        integer s,d;
        $readmemh("07_top_integration/tb/mem/features.mem",vectors);
        $readmemh("07_top_integration/tb/mem/expected.mem",expected);
        reset_dut();
        // Corrupt checksum must not write features or start inference.
        s=start_count; d=done_count;
        send_packet(vectors[3],1);
        check_quiet(s,d);
        if (!error) $fatal(1,"Checksum error not latched");
        exchange(3); // Sticky error must not prevent a valid request.
        if (!error) $fatal(1,"Error must remain sticky");
        reset_dut();
        s=start_count; d=done_count;
        send_byte(8'hA5); send_byte(8'h55,1);
        repeat(2*CPB) @(negedge clk);
        check_quiet(s,d);
        if (!error) $fatal(1,"Framing error not latched");
        exchange(4); // Payload includes A5 and 5A.
        reset_dut();
        for (int n=0;n<24;n++) exchange(n);
        // Abort incomplete RX, then ensure no stale packet.
        send_byte(8'hA5); send_byte(8'h80);
        reset_dut(); s=start_count; d=done_count; check_quiet(s,d);
        exchange(2);
        // Abort a running inference. Driver finishes before reset sequence.
        fork
            send_packet(vectors[1]);
            begin wait(dut.mlp_busy); reset_dut(); end
        join
        s=start_count; d=done_count; check_quiet(s,d); exchange(1);
        // Abort serial response in its data bits.
        fork
            send_packet(vectors[0]);
            begin @(negedge tx); repeat(3*CPB) @(negedge clk); reset_dut(); end
        join
        s=start_count; d=done_count; check_quiet(s,d); exchange(0);
        $display("PASS: 29 real UART/MLP responses, 24 golden vectors, checksum/framing rejection, reset recovery; CPB=%0d",CPB);
        $finish;
    end
    initial begin #100_000_000; $fatal(1,"Integration watchdog"); end
endmodule
