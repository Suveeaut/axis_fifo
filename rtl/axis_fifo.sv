`timescale 1ns / 1ps

module axis_fifo #(
    parameter int DATA_WIDTH    = 8,
    parameter int DEPTH         = 16,
    parameter int AFULL_THRESH  = DEPTH - 2,
    parameter int AEMPTY_THRESH = 2
)(
    input  logic                  clk,
    input  logic                  rst,

    // AXI4-Stream Slave interface (write side)
    input  logic [DATA_WIDTH-1:0] s_axis_data,
    input  logic                  s_axis_valid,
    output logic                  s_axis_ready,

    // AXI4-Stream Master interface (read side)
    output logic [DATA_WIDTH-1:0] m_axis_data,
    output logic                  m_axis_valid,
    input  logic                  m_axis_ready,

    // FIFO status flags
    output logic                  full,
    output logic                  empty,
    output logic                  almost_full,
    output logic                  almost_empty
);

    localparam int ADDR_WIDTH  = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

    // Dual-port synchronous RAM storage
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    logic [ADDR_WIDTH-1:0] wr_ptr;
    logic [ADDR_WIDTH-1:0] rd_ptr;
    logic [COUNT_WIDTH-1:0] fifo_count;

    // Internal FIFO read/write control signals
    logic wr_fire;
    logic pop_from_fifo;
    logic push_to_out_reg;
    logic out_accept;

    // Slave can accept data whenever internal storage is not full
    // Note: for strict AXI4-Stream, s_axis_ready depends only on internal capacity
    assign s_axis_ready = (fifo_count < DEPTH);

    // Handshake on master output port
    assign out_accept = m_axis_valid && m_axis_ready;

    // Write into RAM when slave handshake occurs
    assign wr_fire = s_axis_valid && s_axis_ready;

    // Load output register when output is currently empty, or being accepted this cycle
    // while internal FIFO still has unread data
    assign push_to_out_reg = (fifo_count > 0) && (!m_axis_valid || out_accept);

    // Advance FIFO read pointer whenever a word is moved into the output stage
    assign pop_from_fifo = push_to_out_reg;

    // Status flags based on total buffered words (RAM + output register)
    logic [COUNT_WIDTH-1:0] total_occupancy;
    assign total_occupancy = fifo_count + (m_axis_valid ? 1'b1 : 1'b0);

    assign full         = (fifo_count == DEPTH);
    assign empty        = (total_occupancy == 0);
    assign almost_full  = (total_occupancy >= AFULL_THRESH);
    assign almost_empty = (total_occupancy <= AEMPTY_THRESH);

    // Write pointer and memory write
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
        end else if (wr_fire) begin
            mem[wr_ptr] <= s_axis_data;
            if (wr_ptr == DEPTH - 1) begin
                wr_ptr <= '0;
            end else begin
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    // Read pointer update
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr <= '0;
        end else if (pop_from_fifo) begin
            if (rd_ptr == DEPTH - 1) begin
                rd_ptr <= '0;
            end else begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

    // Internal RAM occupancy counter
    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_count <= '0;
        end else begin
            case ({wr_fire, pop_from_fifo})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // AXI4-Stream Master output stage
    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_valid <= 1'b0;
            m_axis_data  <= '0;
        end else begin
            if (push_to_out_reg) begin
                m_axis_data  <= mem[rd_ptr];
                m_axis_valid <= 1'b1;
            end else if (out_accept) begin
                m_axis_valid <= 1'b0;
            end
        end
    end

endmodule
