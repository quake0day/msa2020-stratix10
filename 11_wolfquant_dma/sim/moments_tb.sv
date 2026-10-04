`timescale 1ns / 1ps

module moments_tb;
    logic clk = 0;
    always #2 clk = ~clk;
    logic rst = 1;

    logic [15:0] reg_wr_addr = 0, reg_rd_addr = 0;
    logic [31:0] reg_wr_data = 0;
    logic [3:0] reg_wr_strb = 4'hf;
    logic reg_wr_en = 0, reg_rd_en = 0;
    wire reg_wr_wait, reg_wr_ack, reg_rd_wait, reg_rd_ack;
    wire [31:0] reg_rd_data;

    logic [1:0] dma_ram_wr_cmd_valid = 0;
    logic [63:0] dma_ram_wr_cmd_be = 0;
    logic [19:0] dma_ram_wr_cmd_addr = 0;
    logic [511:0] dma_ram_wr_cmd_data = 0;
    wire [1:0] dma_ram_wr_cmd_ready, dma_ram_wr_done;
    logic [1:0] dma_ram_rd_cmd_valid = 0;
    logic [19:0] dma_ram_rd_cmd_addr = 0;
    wire [1:0] dma_ram_rd_cmd_ready, dma_ram_rd_resp_valid;
    wire [511:0] dma_ram_rd_resp_data;
    logic [1:0] dma_ram_rd_resp_ready = 2'b11;

    wire m_axis_dma_read_desc_valid, m_axis_dma_write_desc_valid;
    logic m_axis_dma_read_desc_ready = 1;
    logic m_axis_dma_write_desc_ready = 1;
    logic [15:0] s_axis_dma_read_desc_status_tag = 0;
    logic [3:0] s_axis_dma_read_desc_status_error = 0;
    logic s_axis_dma_read_desc_status_valid = 0;
    logic [15:0] s_axis_dma_write_desc_status_tag = 0;
    logic [3:0] s_axis_dma_write_desc_status_error = 0;
    logic s_axis_dma_write_desc_status_valid = 0;

    dma_bench #(
        .REG_ADDR_WIDTH(16)
    ) dut (
        .clk(clk), .rst(rst),
        .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
        .reg_wr_strb(reg_wr_strb), .reg_wr_en(reg_wr_en),
        .reg_wr_wait(reg_wr_wait), .reg_wr_ack(reg_wr_ack),
        .reg_rd_addr(reg_rd_addr), .reg_rd_en(reg_rd_en),
        .reg_rd_data(reg_rd_data), .reg_rd_wait(reg_rd_wait),
        .reg_rd_ack(reg_rd_ack),
        .m_axis_dma_read_desc_dma_addr(),
        .m_axis_dma_read_desc_ram_sel(),
        .m_axis_dma_read_desc_ram_addr(),
        .m_axis_dma_read_desc_len(),
        .m_axis_dma_read_desc_tag(),
        .m_axis_dma_read_desc_valid(m_axis_dma_read_desc_valid),
        .m_axis_dma_read_desc_ready(m_axis_dma_read_desc_ready),
        .s_axis_dma_read_desc_status_tag(s_axis_dma_read_desc_status_tag),
        .s_axis_dma_read_desc_status_error(s_axis_dma_read_desc_status_error),
        .s_axis_dma_read_desc_status_valid(s_axis_dma_read_desc_status_valid),
        .m_axis_dma_write_desc_dma_addr(),
        .m_axis_dma_write_desc_ram_sel(),
        .m_axis_dma_write_desc_ram_addr(),
        .m_axis_dma_write_desc_imm(),
        .m_axis_dma_write_desc_imm_en(),
        .m_axis_dma_write_desc_len(),
        .m_axis_dma_write_desc_tag(),
        .m_axis_dma_write_desc_valid(m_axis_dma_write_desc_valid),
        .m_axis_dma_write_desc_ready(m_axis_dma_write_desc_ready),
        .s_axis_dma_write_desc_status_tag(s_axis_dma_write_desc_status_tag),
        .s_axis_dma_write_desc_status_error(s_axis_dma_write_desc_status_error),
        .s_axis_dma_write_desc_status_valid(s_axis_dma_write_desc_status_valid),
        .dma_ram_wr_cmd_sel('0),
        .dma_ram_wr_cmd_be(dma_ram_wr_cmd_be),
        .dma_ram_wr_cmd_addr(dma_ram_wr_cmd_addr),
        .dma_ram_wr_cmd_data(dma_ram_wr_cmd_data),
        .dma_ram_wr_cmd_valid(dma_ram_wr_cmd_valid),
        .dma_ram_wr_cmd_ready(dma_ram_wr_cmd_ready),
        .dma_ram_wr_done(dma_ram_wr_done),
        .dma_ram_rd_cmd_sel('0),
        .dma_ram_rd_cmd_addr(dma_ram_rd_cmd_addr),
        .dma_ram_rd_cmd_valid(dma_ram_rd_cmd_valid),
        .dma_ram_rd_cmd_ready(dma_ram_rd_cmd_ready),
        .dma_ram_rd_resp_data(dma_ram_rd_resp_data),
        .dma_ram_rd_resp_valid(dma_ram_rd_resp_valid),
        .dma_ram_rd_resp_ready(dma_ram_rd_resp_ready)
    );

    logic signed [31:0] xs [0:1023], ys [0:1023];
    longint signed want_x, want_y, want_x2, want_y2, want_xy;
    int i;

    task automatic write_reg(input logic [15:0] addr, input logic [31:0] data);
        @(negedge clk);
        reg_wr_addr = addr;
        reg_wr_data = data;
        reg_wr_en = 1;
        @(posedge clk); #1;
        if (!reg_wr_ack) $fatal(1, "register write 0x%h was not acknowledged", addr);
        @(negedge clk);
        reg_wr_en = 0;
        @(posedge clk); #1;
    endtask

    task automatic read_reg(input logic [15:0] addr, output logic [31:0] data);
        @(negedge clk);
        reg_rd_addr = addr;
        reg_rd_en = 1;
        @(posedge clk); #1;
        if (!reg_rd_ack) $fatal(1, "register read 0x%h was not acknowledged", addr);
        data = reg_rd_data;
        @(negedge clk);
        reg_rd_en = 0;
        @(posedge clk); #1;
    endtask

    task automatic read_i64(input logic [15:0] addr, output longint signed value);
        logic [31:0] low_word, high_word;
        read_reg(addr, low_word);
        read_reg(addr + 4, high_word);
        value = $signed({high_word, low_word});
    endtask

    task automatic load_samples(input int count);
        logic [511:0] row_data;
        int row, lane, idx;
        for (row = 0; row < (count + 7)/8; row++) begin
            row_data = 0;
            for (lane = 0; lane < 8; lane++) begin
                idx = row*8 + lane;
                if (idx < count) begin
                    row_data[lane*64 +: 32] = xs[idx];
                    row_data[lane*64+32 +: 32] = ys[idx];
                end
            end
            @(negedge clk);
            dma_ram_wr_cmd_addr = {10'(row), 10'(row)};
            dma_ram_wr_cmd_data = row_data;
            dma_ram_wr_cmd_be = '1;
            dma_ram_wr_cmd_valid = 2'b11;
            #1;
            if (dma_ram_wr_cmd_ready != 2'b11)
                $fatal(1, "DMA RAM write failed at row %0d", row);
            @(posedge clk); #1;
            @(negedge clk);
            dma_ram_wr_cmd_valid = 0;
            @(posedge clk); #1;
        end
    endtask

    task automatic wait_done(output logic [31:0] status);
        int tries;
        for (tries = 0; tries < 10000; tries++) begin
            read_reg('h510, status);
            if (status[1]) return;
        end
        $fatal(1, "moments engine timed out");
    endtask

    task automatic check_case(input int count, input bit handoff,
                              input bit stagger);
        logic [31:0] value, status;
        logic [511:0] expected_first_row;
        longint signed got;
        int j;

        load_samples(count);
        want_x = 0; want_y = 0; want_x2 = 0; want_y2 = 0; want_xy = 0;
        for (j = 0; j < count; j++) begin
            want_x += longint'(xs[j]);
            want_y += longint'(ys[j]);
            want_x2 += longint'(xs[j])*longint'(xs[j]);
            want_y2 += longint'(ys[j])*longint'(ys[j]);
            want_xy += longint'(xs[j])*longint'(ys[j]);
        end

        write_reg('h508, 32'(count));
        if (stagger)
            force dut.mom_ram_rd_resp_ready[1] = 1'b0;
        write_reg('h50c, 1);
        read_reg('h510, status);
        if (!status[0] && !status[1])
            $fatal(1, "engine did not start for count %0d", count);

        if (stagger) begin
            repeat (5) @(posedge clk);
            #1;
            if (dut.mom_resp_seen_reg !== 2'b01)
                $fatal(1, "the two RAM segments did not stagger as expected");
            release dut.mom_ram_rd_resp_ready[1];
        end

        if (handoff) begin
            expected_first_row = 0;
            for (j = 0; j < 8; j++) begin
                expected_first_row[j*64 +: 32] = xs[j];
                expected_first_row[j*64+32 +: 32] = ys[j];
            end
            @(negedge clk);
            dma_ram_rd_cmd_addr = 0;
            dma_ram_rd_cmd_valid = 2'b11;
            #1;
            if (dma_ram_rd_cmd_ready !== 2'b00)
                $fatal(1, "DMA RAM read was not stalled during moments job");
            read_reg('h510, status);
            if (!status[0] || dma_ram_rd_cmd_ready !== 2'b00)
                $fatal(1, "DMA RAM read was accepted before moments finished");
            @(negedge clk);
            dma_ram_rd_cmd_valid = 0;
            m_axis_dma_read_desc_ready = 0;
            m_axis_dma_write_desc_ready = 0;
            write_reg('h114, 'h123);
            write_reg('h214, 'h456);
            if (m_axis_dma_read_desc_valid || m_axis_dma_write_desc_valid)
                $fatal(1, "a new DMA descriptor launched during moments job");
        end

        wait_done(status);
        if (status !== 32'h2)
            $fatal(1, "count %0d status 0x%h", count, status);
        read_i64('h520, got); if (got !== want_x)
            $fatal(1, "sum_x: got %0d wanted %0d", got, want_x);
        read_i64('h528, got); if (got !== want_y)
            $fatal(1, "sum_y: got %0d wanted %0d", got, want_y);
        read_i64('h530, got); if (got !== want_x2)
            $fatal(1, "sum_x2: got %0d wanted %0d", got, want_x2);
        read_i64('h538, got); if (got !== want_y2)
            $fatal(1, "sum_y2: got %0d wanted %0d", got, want_y2);
        read_i64('h540, got); if (got !== want_xy)
            $fatal(1, "sum_xy: got %0d wanted %0d", got, want_xy);

        if (handoff) begin
            if (!m_axis_dma_read_desc_valid || !m_axis_dma_write_desc_valid)
                $fatal(1, "queued DMA descriptors did not resume after moments job");
            @(negedge clk);
            dma_ram_rd_cmd_valid = 2'b11;
            #1;
            if (dma_ram_rd_cmd_ready !== 2'b11)
                $fatal(1, "DMA RAM read did not resume after moments job");
            @(posedge clk); #1;
            @(negedge clk);
            dma_ram_rd_cmd_valid = 0;
            for (j = 0; j < 10; j++) begin
                @(posedge clk); #1;
                if (dma_ram_rd_resp_valid == 2'b11) begin
                    if (dma_ram_rd_resp_data !== expected_first_row)
                        $fatal(1, "DMA RAM handoff returned wrong data");
                    break;
                end
            end
            if (j == 10) $fatal(1, "DMA RAM handoff returned no response");

            @(negedge clk);
            m_axis_dma_read_desc_ready = 1;
            m_axis_dma_write_desc_ready = 1;
            @(posedge clk); #1;
            if (m_axis_dma_read_desc_valid || m_axis_dma_write_desc_valid)
                $fatal(1, "queued DMA descriptors were not consumed");
            @(negedge clk);
            s_axis_dma_read_desc_status_tag = 'h123;
            s_axis_dma_write_desc_status_tag = 'h456;
            s_axis_dma_read_desc_status_valid = 1;
            s_axis_dma_write_desc_status_valid = 1;
            @(posedge clk); #1;
            @(negedge clk);
            s_axis_dma_read_desc_status_valid = 0;
            s_axis_dma_write_desc_status_valid = 0;
            read_reg('h118, value);
            if (value !== 32'h80000123)
                $fatal(1, "DMA read completion lost after moments job: %h", value);
            read_reg('h218, value);
            if (value !== 32'h80000456)
                $fatal(1, "DMA write completion lost after moments job: %h", value);
        end

        write_reg('h50c, 2);
        read_reg('h510, status);
        if (status !== 0) $fatal(1, "CLEAR did not reset status");
        $display("PASS count=%0d handoff=%0d stagger=%0d", count,
                 handoff, stagger);
    endtask

    initial begin
        logic [31:0] value, status;
        for (i = 0; i < 1024; i++) begin
            xs[i] = 32'(i%211 - 105);
            ys[i] = 32'(67 - (i*3)%139);
        end
        xs[0] = -20000; ys[0] = 30000;
        xs[1] = 8388607; ys[1] = -8388608;
        xs[1023] = -8388608; ys[1023] = 8388607;

        repeat (5) @(posedge clk);
        @(negedge clk); rst = 0;
        read_reg('h500, value);
        if (value !== 32'h57514d31) $fatal(1, "wrong moments magic");
        read_reg('h504, value);
        if (value !== 32'h00010000) $fatal(1, "wrong moments ABI");

        check_case(1, 0, 0);
        check_case(20, 1, 0);
        check_case(9, 0, 1);
        check_case(1024, 0, 0);

        write_reg('h508, 0);
        write_reg('h50c, 1);
        read_reg('h510, status);
        read_reg('h514, value);
        if (status !== 32'h6 || value !== 1)
            $fatal(1, "count=0 was not rejected: status=%h error=%d", status, value);
        write_reg('h50c, 2);
        read_reg('h510, status);
        if (status !== 0) $fatal(1, "CLEAR after count error failed");

        write_reg('h508, 1025);
        write_reg('h50c, 1);
        read_reg('h510, status);
        read_reg('h514, value);
        if (status !== 32'h6 || value !== 1)
            $fatal(1, "count=1025 was not rejected");
        write_reg('h50c, 2);

        xs[0] = 8388608;
        load_samples(1);
        write_reg('h508, 1);
        write_reg('h50c, 1);
        wait_done(status);
        read_reg('h514, value);
        if (status !== 32'h6 || value !== 3)
            $fatal(1, "range error was not detected: status=%h error=%d", status, value);
        write_reg('h50c, 2);

        xs[0] = -8388609;
        load_samples(1);
        write_reg('h50c, 1);
        wait_done(status);
        read_reg('h514, value);
        if (status !== 32'h6 || value !== 3)
            $fatal(1, "negative range error was not detected");
        write_reg('h50c, 2);

        // A simultaneous DMA RAM command makes START fail before it owns RAM.
        @(negedge clk);
        dma_ram_wr_cmd_be = 0;
        dma_ram_wr_cmd_valid = 2'b01;
        reg_wr_addr = 'h50c;
        reg_wr_data = 1;
        reg_wr_en = 1;
        @(posedge clk); #1;
        @(negedge clk);
        dma_ram_wr_cmd_valid = 0;
        reg_wr_en = 0;
        @(posedge clk); #1;
        read_reg('h510, status);
        read_reg('h514, value);
        if (status !== 32'h6 || value !== 2)
            $fatal(1, "DMA busy was not rejected: status=%h error=%d", status, value);
        write_reg('h50c, 2);
        read_reg('h510, status);
        if (status !== 0) $fatal(1, "CLEAR after DMA busy failed");

        $display("ALL MOMENTS TESTS PASSED");
        $finish;
    end
endmodule
