`timescale 1ns / 1ps

module tb_axis_fifo;

    localparam int DATA_WIDTH = 8;
    localparam int DEPTH      = 8; // Small depth to stress full/empty/backpressure often
    localparam int CLK_PER    = 10; // 100 MHz

    logic                  clk;
    logic                  rst;

    logic [DATA_WIDTH-1:0] s_axis_data;
    logic                  s_axis_valid;
    logic                  s_axis_ready;

    logic [DATA_WIDTH-1:0] m_axis_data;
    logic                  m_axis_valid;
    logic                  m_axis_ready;

    logic                  full;
    logic                  empty;
    logic                  almost_full;
    logic                  almost_empty;

    logic [DATA_WIDTH-1:0] ref_queue[$];
    logic [DATA_WIDTH-1:0] next_tx_byte;

    int pass_count = 0;
    int fail_count = 0;

    axis_fifo #(
        .DATA_WIDTH   (DATA_WIDTH),
        .DEPTH        (DEPTH),
        .AFULL_THRESH (DEPTH - 2),
        .AEMPTY_THRESH(2)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .s_axis_data  (s_axis_data),
        .s_axis_valid (s_axis_valid),
        .s_axis_ready (s_axis_ready),
        .m_axis_data  (m_axis_data),
        .m_axis_valid (m_axis_valid),
        .m_axis_ready (m_axis_ready),
        .full         (full),
        .empty        (empty),
        .almost_full  (almost_full),
        .almost_empty (almost_empty)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PER / 2) clk = ~clk;
    end

    // Random master ready generator (simulates downstream backpressure)
    always @(posedge clk) begin
        if (rst) begin
            m_axis_ready <= 1'b0;
        end else begin
            // ~60% ready, ~40% backpressure
            m_axis_ready <= ($urandom_range(0, 99) < 60);
        end
    end

    // Random slave valid & payload generator
    always @(posedge clk) begin
        if (rst) begin
            s_axis_valid <= 1'b0;
            s_axis_data  <= '0;
            next_tx_byte <= 8'h00;
        end else begin
            // If previous beat was accepted, decide whether to drive a new byte
            if (s_axis_valid && s_axis_ready) begin
                ref_queue.push_back(s_axis_data);
                if ($urandom_range(0, 99) < 65) begin
                    s_axis_valid <= 1'b1;
                    s_axis_data  <= next_tx_byte;
                    next_tx_byte <= next_tx_byte + 8'h01;
                end else begin
                    s_axis_valid <= 1'b0;
                end
            end else if (!s_axis_valid) begin
                if ($urandom_range(0, 99) < 65) begin
                    s_axis_valid <= 1'b1;
                    s_axis_data  <= next_tx_byte;
                    next_tx_byte <= next_tx_byte + 8'h01;
                end
            end
        end
    end

    // Scoreboard checker on AXI4-Stream Master handshake
    always @(posedge clk) begin
        if (!rst && m_axis_valid && m_axis_ready) begin
            if (ref_queue.size() == 0) begin
                $display("[FAIL] Extra/duplicate byte 8'h%02h when ref_queue empty at t=%0t",
                         m_axis_data, $time);
                fail_count++;
            end else begin
                logic [DATA_WIDTH-1:0] exp_b;
                exp_b = ref_queue.pop_front();
                if (m_axis_data === exp_b) begin
                    pass_count++;
                end else begin
                    $display("[FAIL] Data mismatch at t=%0t: expected 8'h%02h, got 8'h%02h",
                             $time, exp_b, m_axis_data);
                    fail_count++;
                end
            end
        end
    end

    // Main test control
    initial begin
        rst <= 1'b1;
        repeat (5) @(posedge clk);
        rst <= 1'b0;

        // Run randomized stress traffic for 2,000 clock cycles
        repeat (2000) @(posedge clk);

        // Stop driving new slave data and drain remaining FIFO entries
        @(posedge clk);
        s_axis_valid <= 1'b0;

        begin
            int drain_cycles = 0;
            while ((ref_queue.size() > 0 || m_axis_valid) && drain_cycles < 500) begin
                @(posedge clk);
                drain_cycles++;
            end
        end

        if (ref_queue.size() > 0) begin
            $display("[FAIL] %0d byte(s) lost/undrained in ref_queue at end of test",
                     ref_queue.size());
            fail_count += ref_queue.size();
        end

        if (!empty) begin
            $display("[FAIL] FIFO not empty after draining all expected data");
            fail_count++;
        end

        $display("--------------------------------------------------");
        $display("AXI4-Stream FIFO Stress Test: PASS=%0d, FAIL=%0d", pass_count, fail_count);
        $display("--------------------------------------------------");

        if (fail_count == 0 && pass_count > 0) begin
            $display("ALL FIFO TESTS PASSED!");
        end else begin
            $display("SOME FIFO TESTS FAILED!");
        end

        $finish;
    end

endmodule
