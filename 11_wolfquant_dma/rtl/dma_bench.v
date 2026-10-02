// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2021-2023 The Regents of the University of California
 */


// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * DMA benchmark module
 */
module dma_bench #
(
    // DMA interface configuration
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 16,
    parameter RAM_SEL_WIDTH = 4,
    parameter RAM_ADDR_WIDTH = 16,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 256*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    // Register interface
    parameter REG_ADDR_WIDTH = 7,
    parameter REG_DATA_WIDTH = 32,
    parameter REG_STRB_WIDTH = (REG_DATA_WIDTH/8),
    parameter RB_BASE_ADDR = 0,
    parameter RB_NEXT_PTR = 0
)
(
    input  wire                                         clk,
    input  wire                                         rst,

    /*
     * Register interface
     */
    input  wire [REG_ADDR_WIDTH-1:0]                    reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]                    reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]                    reg_wr_strb,
    input  wire                                         reg_wr_en,
    output wire                                         reg_wr_wait,
    output wire                                         reg_wr_ack,
    input  wire [REG_ADDR_WIDTH-1:0]                    reg_rd_addr,
    input  wire                                         reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]                    reg_rd_data,
    output wire                                         reg_rd_wait,
    output wire                                         reg_rd_ack,

    /*
     * DMA read descriptor output
     */
    output wire [DMA_ADDR_WIDTH-1:0]                    m_axis_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                     m_axis_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                    m_axis_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                     m_axis_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                     m_axis_dma_read_desc_tag,
    output wire                                         m_axis_dma_read_desc_valid,
    input  wire                                         m_axis_dma_read_desc_ready,

    /*
     * DMA read descriptor status input
     */
    input  wire [DMA_TAG_WIDTH-1:0]                     s_axis_dma_read_desc_status_tag,
    input  wire [3:0]                                   s_axis_dma_read_desc_status_error,
    input  wire                                         s_axis_dma_read_desc_status_valid,

    /*
     * DMA write descriptor output
     */
    output wire [DMA_ADDR_WIDTH-1:0]                    m_axis_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                     m_axis_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                    m_axis_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                     m_axis_dma_write_desc_imm,
    output wire                                         m_axis_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                     m_axis_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                     m_axis_dma_write_desc_tag,
    output wire                                         m_axis_dma_write_desc_valid,
    input  wire                                         m_axis_dma_write_desc_ready,

    /*
     * DMA write descriptor status input
     */
    input  wire [DMA_TAG_WIDTH-1:0]                     s_axis_dma_write_desc_status_tag,
    input  wire [3:0]                                   s_axis_dma_write_desc_status_error,
    input  wire                                         s_axis_dma_write_desc_status_valid,

    /*
     * DMA RAM interface
     */
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]       dma_ram_wr_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]    dma_ram_wr_cmd_be,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]  dma_ram_wr_cmd_addr,
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  dma_ram_wr_cmd_data,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_wr_done,
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]       dma_ram_rd_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]  dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_ready
);

localparam RAM_ADDR_IMM_WIDTH = (DMA_IMM_ENABLE && (DMA_IMM_WIDTH > RAM_ADDR_WIDTH)) ? DMA_IMM_WIDTH : RAM_ADDR_WIDTH;

localparam RBB = RB_BASE_ADDR & {REG_ADDR_WIDTH{1'b1}};

// check configuration
initial begin
    if (REG_DATA_WIDTH != 32) begin
        $error("Error: Register interface width must be 32 (instance %m)");
        $finish;
    end

    if (REG_STRB_WIDTH * 8 != REG_DATA_WIDTH) begin
        $error("Error: Register interface requires byte (8-bit) granularity (instance %m)");
        $finish;
    end

    if (REG_ADDR_WIDTH < 12) begin
        $error("Error: Register address width too narrow (instance %m)");
        $finish;
    end

    if (RB_NEXT_PTR && RB_NEXT_PTR >= RB_BASE_ADDR && RB_NEXT_PTR < RB_BASE_ADDR + 13'h1000) begin
        $error("Error: RB_NEXT_PTR overlaps block (instance %m)");
        $finish;
    end

    if (RAM_SEG_COUNT != 2 || RAM_SEG_DATA_WIDTH != 256 ||
            RAM_SEG_BE_WIDTH != 32 || RAM_SEG_ADDR_WIDTH < 8) begin
        $error("Error: WolfQuant moments requires two 256-bit RAM segments (instance %m)");
        $finish;
    end
end

// control registers
reg reg_wr_ack_reg = 1'b0, reg_wr_ack_next;
reg [REG_DATA_WIDTH-1:0] reg_rd_data_reg = 0, reg_rd_data_next;
reg reg_rd_ack_reg = 1'b0, reg_rd_ack_next;

reg [63:0] cycle_count_reg = 0;
reg [15:0] dma_read_active_count_reg = 0;
reg [15:0] dma_write_active_count_reg = 0;

reg [DMA_ADDR_WIDTH-1:0] dma_read_desc_dma_addr_reg = 0, dma_read_desc_dma_addr_next;
reg [RAM_ADDR_WIDTH-1:0] dma_read_desc_ram_addr_reg = 0, dma_read_desc_ram_addr_next;
reg [DMA_LEN_WIDTH-1:0] dma_read_desc_len_reg = 0, dma_read_desc_len_next;
reg [DMA_TAG_WIDTH-1:0] dma_read_desc_tag_reg = 0, dma_read_desc_tag_next;
reg dma_read_desc_valid_reg = 0, dma_read_desc_valid_next;

reg [DMA_TAG_WIDTH-1:0] dma_read_desc_status_tag_reg = 0, dma_read_desc_status_tag_next;
reg [3:0] dma_read_desc_status_error_reg = 0, dma_read_desc_status_error_next;
reg dma_read_desc_status_valid_reg = 0, dma_read_desc_status_valid_next;

reg [DMA_ADDR_WIDTH-1:0] dma_write_desc_dma_addr_reg = 0, dma_write_desc_dma_addr_next;
reg [RAM_ADDR_IMM_WIDTH-1:0] dma_write_desc_ram_addr_imm_reg = 0, dma_write_desc_ram_addr_imm_next;
reg dma_write_desc_imm_en_reg = 0, dma_write_desc_imm_en_next;
reg [DMA_LEN_WIDTH-1:0] dma_write_desc_len_reg = 0, dma_write_desc_len_next;
reg [DMA_TAG_WIDTH-1:0] dma_write_desc_tag_reg = 0, dma_write_desc_tag_next;
reg dma_write_desc_valid_reg = 0, dma_write_desc_valid_next;

reg [DMA_TAG_WIDTH-1:0] dma_write_desc_status_tag_reg = 0, dma_write_desc_status_tag_next;
reg [3:0] dma_write_desc_status_error_reg = 0, dma_write_desc_status_error_next;
reg dma_write_desc_status_valid_reg = 0, dma_write_desc_status_valid_next;

reg dma_rd_int_en_reg = 0, dma_rd_int_en_next;
reg dma_wr_int_en_reg = 0, dma_wr_int_en_next;

reg dma_read_block_run_reg = 1'b0, dma_read_block_run_next;
reg [DMA_LEN_WIDTH-1:0] dma_read_block_len_reg = 0, dma_read_block_len_next;
reg [31:0] dma_read_block_count_reg = 0, dma_read_block_count_next;
reg [63:0] dma_read_block_cycle_count_reg = 0, dma_read_block_cycle_count_next;
reg [DMA_ADDR_WIDTH-1:0] dma_read_block_dma_base_addr_reg = 0, dma_read_block_dma_base_addr_next;
reg [DMA_ADDR_WIDTH-1:0] dma_read_block_dma_offset_reg = 0, dma_read_block_dma_offset_next;
reg [DMA_ADDR_WIDTH-1:0] dma_read_block_dma_offset_mask_reg = 0, dma_read_block_dma_offset_mask_next;
reg [DMA_ADDR_WIDTH-1:0] dma_read_block_dma_stride_reg = 0, dma_read_block_dma_stride_next;
reg [RAM_ADDR_WIDTH-1:0] dma_read_block_ram_base_addr_reg = 0, dma_read_block_ram_base_addr_next;
reg [RAM_ADDR_WIDTH-1:0] dma_read_block_ram_offset_reg = 0, dma_read_block_ram_offset_next;
reg [RAM_ADDR_WIDTH-1:0] dma_read_block_ram_offset_mask_reg = 0, dma_read_block_ram_offset_mask_next;
reg [RAM_ADDR_WIDTH-1:0] dma_read_block_ram_stride_reg = 0, dma_read_block_ram_stride_next;

reg dma_write_block_run_reg = 1'b0, dma_write_block_run_next;
reg [DMA_LEN_WIDTH-1:0] dma_write_block_len_reg = 0, dma_write_block_len_next;
reg [31:0] dma_write_block_count_reg = 0, dma_write_block_count_next;
reg [63:0] dma_write_block_cycle_count_reg = 0, dma_write_block_cycle_count_next;
reg [DMA_ADDR_WIDTH-1:0] dma_write_block_dma_base_addr_reg = 0, dma_write_block_dma_base_addr_next;
reg [DMA_ADDR_WIDTH-1:0] dma_write_block_dma_offset_reg = 0, dma_write_block_dma_offset_next;
reg [DMA_ADDR_WIDTH-1:0] dma_write_block_dma_offset_mask_reg = 0, dma_write_block_dma_offset_mask_next;
reg [DMA_ADDR_WIDTH-1:0] dma_write_block_dma_stride_reg = 0, dma_write_block_dma_stride_next;
reg [RAM_ADDR_WIDTH-1:0] dma_write_block_ram_base_addr_reg = 0, dma_write_block_ram_base_addr_next;
reg [RAM_ADDR_WIDTH-1:0] dma_write_block_ram_offset_reg = 0, dma_write_block_ram_offset_next;
reg [RAM_ADDR_WIDTH-1:0] dma_write_block_ram_offset_mask_reg = 0, dma_write_block_ram_offset_mask_next;
reg [RAM_ADDR_WIDTH-1:0] dma_write_block_ram_stride_reg = 0, dma_write_block_ram_stride_next;

// WolfQuant moments v1.  Input is up to 1024 pairs of little-endian signed
// 32-bit Q20 values in the first 8 KiB of application RAM.  Each value must
// be the sign extension of a signed 24-bit integer.  The five raw integer
// sums are exact 64-bit values; software applies the Q20/Q40 scaling.
localparam [2:0] MOM_IDLE = 0, MOM_REQ = 1, MOM_WAIT = 2,
                 MOM_LOAD = 3, MOM_PROCESS = 4, MOM_FLUSH = 5;
localparam [7:0] MOM_ERR_COUNT = 1, MOM_ERR_DMA_BUSY = 2,
                 MOM_ERR_RANGE = 3;

reg [2:0] mom_state_reg = MOM_IDLE;
reg [31:0] mom_count_reg = 0;
reg [10:0] mom_remaining_reg = 0;
reg [3:0] mom_row_remaining_reg = 0;
reg [RAM_SEG_ADDR_WIDTH-1:0] mom_row_addr_reg = 0;
reg [RAM_SEG_COUNT-1:0] mom_req_pending_reg = 0;
reg [RAM_SEG_COUNT-1:0] mom_resp_seen_reg = 0;
reg [255:0] mom_seg0_reg = 0, mom_seg1_reg = 0;
reg [511:0] mom_row_data_reg = 0;
reg mom_done_reg = 0, mom_error_reg = 0;
reg [7:0] mom_error_code_reg = 0;
reg signed [63:0] mom_sum_x_reg = 0, mom_sum_y_reg = 0;
reg signed [63:0] mom_sum_x2_reg = 0, mom_sum_y2_reg = 0;
reg signed [63:0] mom_sum_xy_reg = 0;
reg signed [31:0] mom_x_reg = 0, mom_y_reg = 0;
reg signed [63:0] mom_prod_x2_reg = 0, mom_prod_y2_reg = 0,
                  mom_prod_xy_reg = 0;
reg mom_xy_valid_reg = 0, mom_prod_valid_reg = 0;

wire mom_busy = mom_state_reg != MOM_IDLE;
wire signed [31:0] mom_input_x = mom_row_data_reg[31:0];
wire signed [31:0] mom_input_y = mom_row_data_reg[63:32];
wire mom_input_valid = mom_input_x[31:23] == {9{mom_input_x[23]}} &&
                       mom_input_y[31:23] == {9{mom_input_y[23]}};

wire [RAM_SEG_COUNT-1:0] ram_wr_cmd_ready_int;
wire [RAM_SEG_COUNT-1:0] ram_wr_done_int;
wire [RAM_SEG_COUNT-1:0] ram_rd_cmd_ready_int;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] ram_rd_resp_data_int;
wire [RAM_SEG_COUNT-1:0] ram_rd_resp_valid_int;
wire [RAM_SEG_COUNT-1:0] mom_ram_rd_cmd_valid =
    mom_state_reg == MOM_REQ ? mom_req_pending_reg : 0;
wire [RAM_SEG_COUNT-1:0] mom_ram_rd_resp_ready =
    mom_state_reg == MOM_WAIT ? {RAM_SEG_COUNT{1'b1}} : 0;
wire dma_idle_for_mom = !dma_read_active_count_reg &&
    !dma_write_active_count_reg && !dma_read_desc_valid_reg &&
    !dma_write_desc_valid_reg && !dma_read_block_run_reg &&
    !dma_write_block_run_reg && !(|dma_ram_wr_cmd_valid) &&
    !(|dma_ram_rd_cmd_valid) && !(|ram_rd_resp_valid_int);

// dma_psdpram has one read and one write port per segment.  The moments
// engine takes the read ports only after all DMA descriptors have completed;
// during a job, incoming DMA RAM commands and new descriptor launches stall.
assign dma_ram_wr_cmd_ready = mom_busy ? 0 : ram_wr_cmd_ready_int;
assign dma_ram_wr_done = mom_busy ? 0 : ram_wr_done_int;
assign dma_ram_rd_cmd_ready = mom_busy ? 0 : ram_rd_cmd_ready_int;
assign dma_ram_rd_resp_data = mom_busy ? 0 : ram_rd_resp_data_int;
assign dma_ram_rd_resp_valid = mom_busy ? 0 : ram_rd_resp_valid_int;

assign reg_wr_wait = 1'b0;
assign reg_wr_ack = reg_wr_ack_reg;
assign reg_rd_data = reg_rd_data_reg;
assign reg_rd_wait = 1'b0;
assign reg_rd_ack = reg_rd_ack_reg;

assign m_axis_dma_read_desc_dma_addr = dma_read_desc_dma_addr_reg;
assign m_axis_dma_read_desc_ram_sel = 0;
assign m_axis_dma_read_desc_ram_addr = dma_read_desc_ram_addr_reg;
assign m_axis_dma_read_desc_len = dma_read_desc_len_reg;
assign m_axis_dma_read_desc_tag = dma_read_desc_tag_reg;
assign m_axis_dma_read_desc_valid = dma_read_desc_valid_reg && !mom_busy;

assign m_axis_dma_write_desc_dma_addr = dma_write_desc_dma_addr_reg;
assign m_axis_dma_write_desc_ram_sel = 0;
assign m_axis_dma_write_desc_ram_addr = dma_write_desc_ram_addr_imm_reg;
assign m_axis_dma_write_desc_imm = dma_write_desc_ram_addr_imm_reg;
assign m_axis_dma_write_desc_imm_en = dma_write_desc_imm_en_reg;
assign m_axis_dma_write_desc_len = dma_write_desc_len_reg;
assign m_axis_dma_write_desc_tag = dma_write_desc_tag_reg;
assign m_axis_dma_write_desc_valid = dma_write_desc_valid_reg && !mom_busy;

always @* begin
    reg_wr_ack_next = 1'b0;
    reg_rd_data_next = 0;
    reg_rd_ack_next = 1'b0;

    dma_read_desc_dma_addr_next = dma_read_desc_dma_addr_reg;
    dma_read_desc_ram_addr_next = dma_read_desc_ram_addr_reg;
    dma_read_desc_len_next = dma_read_desc_len_reg;
    dma_read_desc_tag_next = dma_read_desc_tag_reg;
    dma_read_desc_valid_next = dma_read_desc_valid_reg &&
        !(m_axis_dma_read_desc_ready && !mom_busy);

    dma_read_desc_status_tag_next = dma_read_desc_status_tag_reg;
    dma_read_desc_status_error_next = dma_read_desc_status_error_reg;
    dma_read_desc_status_valid_next = dma_read_desc_status_valid_reg;

    dma_write_desc_dma_addr_next = dma_write_desc_dma_addr_reg;
    dma_write_desc_ram_addr_imm_next = dma_write_desc_ram_addr_imm_reg;
    dma_write_desc_imm_en_next = dma_write_desc_imm_en_reg;
    dma_write_desc_len_next = dma_write_desc_len_reg;
    dma_write_desc_tag_next = dma_write_desc_tag_reg;
    dma_write_desc_valid_next = dma_write_desc_valid_reg &&
        !(m_axis_dma_write_desc_ready && !mom_busy);

    dma_write_desc_status_tag_next = dma_write_desc_status_tag_reg;
    dma_write_desc_status_error_next = dma_write_desc_status_error_reg;
    dma_write_desc_status_valid_next = dma_write_desc_status_valid_reg;

    dma_rd_int_en_next = dma_rd_int_en_reg;
    dma_wr_int_en_next = dma_wr_int_en_reg;

    dma_read_block_run_next = dma_read_block_run_reg;
    dma_read_block_len_next = dma_read_block_len_reg;
    dma_read_block_count_next = dma_read_block_count_reg;
    dma_read_block_cycle_count_next = dma_read_block_cycle_count_reg;
    dma_read_block_dma_base_addr_next = dma_read_block_dma_base_addr_reg;
    dma_read_block_dma_offset_next = dma_read_block_dma_offset_reg;
    dma_read_block_dma_offset_mask_next = dma_read_block_dma_offset_mask_reg;
    dma_read_block_dma_stride_next = dma_read_block_dma_stride_reg;
    dma_read_block_ram_base_addr_next = dma_read_block_ram_base_addr_reg;
    dma_read_block_ram_offset_next = dma_read_block_ram_offset_reg;
    dma_read_block_ram_offset_mask_next = dma_read_block_ram_offset_mask_reg;
    dma_read_block_ram_stride_next = dma_read_block_ram_stride_reg;

    dma_write_block_run_next = dma_write_block_run_reg;
    dma_write_block_len_next = dma_write_block_len_reg;
    dma_write_block_count_next = dma_write_block_count_reg;
    dma_write_block_cycle_count_next = dma_write_block_cycle_count_reg;
    dma_write_block_dma_base_addr_next = dma_write_block_dma_base_addr_reg;
    dma_write_block_dma_offset_next = dma_write_block_dma_offset_reg;
    dma_write_block_dma_offset_mask_next = dma_write_block_dma_offset_mask_reg;
    dma_write_block_dma_stride_next = dma_write_block_dma_stride_reg;
    dma_write_block_ram_base_addr_next = dma_write_block_ram_base_addr_reg;
    dma_write_block_ram_offset_next = dma_write_block_ram_offset_reg;
    dma_write_block_ram_offset_mask_next = dma_write_block_ram_offset_mask_reg;
    dma_write_block_ram_stride_next = dma_write_block_ram_stride_reg;

    if (reg_wr_en && !reg_wr_ack_reg) begin
        // write operation
        reg_wr_ack_next = 1'b1;
        case ({reg_wr_addr >> 2, 2'b00})
            // control
            RBB+12'h00c: begin
                dma_rd_int_en_next = reg_wr_data[0];
                dma_wr_int_en_next = reg_wr_data[1];
            end
            // single read
            RBB+12'h100: dma_read_desc_dma_addr_next[31:0] = reg_wr_data;
            RBB+12'h104: dma_read_desc_dma_addr_next[63:32] = reg_wr_data;
            RBB+12'h108: dma_read_desc_ram_addr_next = reg_wr_data;
            RBB+12'h110: dma_read_desc_len_next = reg_wr_data;
            RBB+12'h114: begin
                dma_read_desc_tag_next = reg_wr_data;
                dma_read_desc_valid_next = 1'b1;
            end
            // single write
            RBB+12'h200: dma_write_desc_dma_addr_next[31:0] = reg_wr_data;
            RBB+12'h204: dma_write_desc_dma_addr_next[63:32] = reg_wr_data;
            RBB+12'h208: dma_write_desc_ram_addr_imm_next = reg_wr_data;
            RBB+12'h210: dma_write_desc_len_next = reg_wr_data;
            RBB+12'h214: begin
                dma_write_desc_tag_next = reg_wr_data[23:0];
                dma_write_desc_imm_en_next = reg_wr_data[31];
                dma_write_desc_valid_next = 1'b1;
            end
            // block read
            RBB+12'h300: begin
                dma_read_block_run_next = reg_wr_data[0];
            end
            RBB+12'h308: dma_read_block_cycle_count_next[31:0] = reg_wr_data;
            RBB+12'h30c: dma_read_block_cycle_count_next[63:32] = reg_wr_data;
            RBB+12'h310: dma_read_block_len_next = reg_wr_data;
            RBB+12'h318: dma_read_block_count_next[31:0] = reg_wr_data;
            RBB+12'h380: dma_read_block_dma_base_addr_next[31:0] = reg_wr_data;
            RBB+12'h384: dma_read_block_dma_base_addr_next[63:32] = reg_wr_data;
            RBB+12'h388: dma_read_block_dma_offset_next[31:0] = reg_wr_data;
            RBB+12'h38c: dma_read_block_dma_offset_next[63:32] = reg_wr_data;
            RBB+12'h390: dma_read_block_dma_offset_mask_next[31:0] = reg_wr_data;
            RBB+12'h394: dma_read_block_dma_offset_mask_next[63:32] = reg_wr_data;
            RBB+12'h398: dma_read_block_dma_stride_next[31:0] = reg_wr_data;
            RBB+12'h39c: dma_read_block_dma_stride_next[63:32] = reg_wr_data;
            RBB+12'h3c0: dma_read_block_ram_base_addr_next = reg_wr_data;
            RBB+12'h3c8: dma_read_block_ram_offset_next = reg_wr_data;
            RBB+12'h3d0: dma_read_block_ram_offset_mask_next = reg_wr_data;
            RBB+12'h3d8: dma_read_block_ram_stride_next = reg_wr_data;
            // block write
            RBB+12'h400: begin
                dma_write_block_run_next = reg_wr_data[0];
            end
            RBB+12'h408: dma_write_block_cycle_count_next[31:0] = reg_wr_data;
            RBB+12'h40c: dma_write_block_cycle_count_next[63:32] = reg_wr_data;
            RBB+12'h410: dma_write_block_len_next = reg_wr_data;
            RBB+12'h418: dma_write_block_count_next[31:0] = reg_wr_data;
            RBB+12'h480: dma_write_block_dma_base_addr_next[31:0] = reg_wr_data;
            RBB+12'h484: dma_write_block_dma_base_addr_next[63:32] = reg_wr_data;
            RBB+12'h488: dma_write_block_dma_offset_next[31:0] = reg_wr_data;
            RBB+12'h48c: dma_write_block_dma_offset_next[63:32] = reg_wr_data;
            RBB+12'h490: dma_write_block_dma_offset_mask_next[31:0] = reg_wr_data;
            RBB+12'h494: dma_write_block_dma_offset_mask_next[63:32] = reg_wr_data;
            RBB+12'h498: dma_write_block_dma_stride_next[31:0] = reg_wr_data;
            RBB+12'h49c: dma_write_block_dma_stride_next[63:32] = reg_wr_data;
            RBB+12'h4c0: dma_write_block_ram_base_addr_next = reg_wr_data;
            RBB+12'h4c8: dma_write_block_ram_offset_next = reg_wr_data;
            RBB+12'h4d0: dma_write_block_ram_offset_mask_next = reg_wr_data;
            RBB+12'h4d8: dma_write_block_ram_stride_next = reg_wr_data;
            // WolfQuant moments v1 control; handled by the independent FSM.
            RBB+12'h508: begin end
            RBB+12'h50c: begin end
            default: reg_wr_ack_next = 1'b0;
        endcase
    end

    if (reg_rd_en && !reg_rd_ack_reg) begin
        // read operation
        reg_rd_ack_next = 1'b1;
        case ({reg_rd_addr >> 2, 2'b00})
            RBB+12'h000: reg_rd_data_next = 32'h12348101;  // Type
            RBB+12'h004: reg_rd_data_next = 32'h00000100;  // Version
            RBB+12'h008: reg_rd_data_next = RB_NEXT_PTR;   // Next header
            // control
            RBB+12'h00c: begin
                reg_rd_data_next[0] = dma_rd_int_en_reg;
                reg_rd_data_next[1] = dma_wr_int_en_reg;
            end
            RBB+12'h010: reg_rd_data_next = cycle_count_reg;
            RBB+12'h014: reg_rd_data_next = cycle_count_reg >> 32;
            RBB+12'h020: reg_rd_data_next = dma_read_active_count_reg;
            RBB+12'h028: reg_rd_data_next = dma_write_active_count_reg;
            // single read
            RBB+12'h100: reg_rd_data_next = dma_read_desc_dma_addr_reg;
            RBB+12'h104: reg_rd_data_next = dma_read_desc_dma_addr_reg >> 32;
            RBB+12'h108: reg_rd_data_next = dma_read_desc_ram_addr_reg;
            RBB+12'h10c: reg_rd_data_next = dma_read_desc_ram_addr_reg >> 32;
            RBB+12'h110: reg_rd_data_next = dma_read_desc_len_reg;
            RBB+12'h114: reg_rd_data_next = dma_read_desc_tag_reg;
            RBB+12'h118: begin
                reg_rd_data_next[15:0] = dma_read_desc_status_tag_reg;
                reg_rd_data_next[27:24] = dma_read_desc_status_error_reg;
                reg_rd_data_next[31] = dma_read_desc_status_valid_reg;
                dma_read_desc_status_valid_next = 1'b0;
            end
            // single write
            RBB+12'h200: reg_rd_data_next = dma_write_desc_dma_addr_reg;
            RBB+12'h204: reg_rd_data_next = dma_write_desc_dma_addr_reg >> 32;
            RBB+12'h208: reg_rd_data_next = dma_write_desc_ram_addr_imm_reg;
            RBB+12'h20c: reg_rd_data_next = dma_write_desc_ram_addr_imm_reg >> 32;
            RBB+12'h210: reg_rd_data_next = dma_write_desc_len_reg;
            RBB+12'h214: begin
                reg_rd_data_next[23:0] = dma_write_desc_tag_reg;
                reg_rd_data_next[31] = dma_write_desc_imm_en_reg;
            end
            RBB+12'h218: begin
                reg_rd_data_next[15:0] = dma_write_desc_status_tag_reg;
                reg_rd_data_next[27:24] = dma_write_desc_status_error_reg;
                reg_rd_data_next[31] = dma_write_desc_status_valid_reg;
                dma_write_desc_status_valid_next = 1'b0;
            end
            // block read
            RBB+12'h300: begin
                reg_rd_data_next[0] = dma_read_block_run_reg;
            end
            RBB+12'h308: reg_rd_data_next = dma_read_block_cycle_count_reg;
            RBB+12'h30c: reg_rd_data_next = dma_read_block_cycle_count_reg >> 32;
            RBB+12'h310: reg_rd_data_next = dma_read_block_len_reg;
            RBB+12'h318: reg_rd_data_next = dma_read_block_count_reg;
            RBB+12'h31c: reg_rd_data_next = dma_read_block_count_reg >> 32;
            RBB+12'h380: reg_rd_data_next = dma_read_block_dma_base_addr_reg;
            RBB+12'h384: reg_rd_data_next = dma_read_block_dma_base_addr_reg >> 32;
            RBB+12'h388: reg_rd_data_next = dma_read_block_dma_offset_reg;
            RBB+12'h38c: reg_rd_data_next = dma_read_block_dma_offset_reg >> 32;
            RBB+12'h390: reg_rd_data_next = dma_read_block_dma_offset_mask_reg;
            RBB+12'h394: reg_rd_data_next = dma_read_block_dma_offset_mask_reg >> 32;
            RBB+12'h398: reg_rd_data_next = dma_read_block_dma_stride_reg;
            RBB+12'h39c: reg_rd_data_next = dma_read_block_dma_stride_reg >> 32;
            RBB+12'h3c0: reg_rd_data_next = dma_read_block_ram_base_addr_reg;
            RBB+12'h3c4: reg_rd_data_next = dma_read_block_ram_base_addr_reg >> 32;
            RBB+12'h3c8: reg_rd_data_next = dma_read_block_ram_offset_reg;
            RBB+12'h3cc: reg_rd_data_next = dma_read_block_ram_offset_reg >> 32;
            RBB+12'h3d0: reg_rd_data_next = dma_read_block_ram_offset_mask_reg;
            RBB+12'h3d4: reg_rd_data_next = dma_read_block_ram_offset_mask_reg >> 32;
            RBB+12'h3d8: reg_rd_data_next = dma_read_block_ram_stride_reg;
            RBB+12'h3dc: reg_rd_data_next = dma_read_block_ram_stride_reg >> 32;
            // block write
            RBB+12'h400: begin
                reg_rd_data_next[0] = dma_write_block_run_reg;
            end
            RBB+12'h408: reg_rd_data_next = dma_write_block_cycle_count_reg;
            RBB+12'h40c: reg_rd_data_next = dma_write_block_cycle_count_reg >> 32;
            RBB+12'h410: reg_rd_data_next = dma_write_block_len_reg;
            RBB+12'h418: reg_rd_data_next = dma_write_block_count_reg;
            RBB+12'h41c: reg_rd_data_next = dma_write_block_count_reg >> 32;
            RBB+12'h480: reg_rd_data_next = dma_write_block_dma_base_addr_reg;
            RBB+12'h484: reg_rd_data_next = dma_write_block_dma_base_addr_reg >> 32;
            RBB+12'h488: reg_rd_data_next = dma_write_block_dma_offset_reg;
            RBB+12'h48c: reg_rd_data_next = dma_write_block_dma_offset_reg >> 32;
            RBB+12'h490: reg_rd_data_next = dma_write_block_dma_offset_mask_reg;
            RBB+12'h494: reg_rd_data_next = dma_write_block_dma_offset_mask_reg >> 32;
            RBB+12'h498: reg_rd_data_next = dma_write_block_dma_stride_reg;
            RBB+12'h49c: reg_rd_data_next = dma_write_block_dma_stride_reg >> 32;
            RBB+12'h4c0: reg_rd_data_next = dma_write_block_ram_base_addr_reg;
            RBB+12'h4c4: reg_rd_data_next = dma_write_block_ram_base_addr_reg >> 32;
            RBB+12'h4c8: reg_rd_data_next = dma_write_block_ram_offset_reg;
            RBB+12'h4cc: reg_rd_data_next = dma_write_block_ram_offset_reg >> 32;
            RBB+12'h4d0: reg_rd_data_next = dma_write_block_ram_offset_mask_reg;
            RBB+12'h4d4: reg_rd_data_next = dma_write_block_ram_offset_mask_reg >> 32;
            RBB+12'h4d8: reg_rd_data_next = dma_write_block_ram_stride_reg;
            RBB+12'h4dc: reg_rd_data_next = dma_write_block_ram_stride_reg >> 32;
            // WolfQuant moments v1, raw integer sums.  Low dword precedes high.
            RBB+12'h500: reg_rd_data_next = 32'h57514d31;  // WQM1
            RBB+12'h504: reg_rd_data_next = 32'h00010000;  // ABI 1.0
            RBB+12'h508: reg_rd_data_next = mom_count_reg;
            RBB+12'h50c: reg_rd_data_next = 0;
            RBB+12'h510: begin
                reg_rd_data_next[0] = mom_busy;
                reg_rd_data_next[1] = mom_done_reg;
                reg_rd_data_next[2] = mom_error_reg;
            end
            RBB+12'h514: reg_rd_data_next = mom_error_code_reg;
            RBB+12'h520: reg_rd_data_next = mom_sum_x_reg;
            RBB+12'h524: reg_rd_data_next = mom_sum_x_reg >> 32;
            RBB+12'h528: reg_rd_data_next = mom_sum_y_reg;
            RBB+12'h52c: reg_rd_data_next = mom_sum_y_reg >> 32;
            RBB+12'h530: reg_rd_data_next = mom_sum_x2_reg;
            RBB+12'h534: reg_rd_data_next = mom_sum_x2_reg >> 32;
            RBB+12'h538: reg_rd_data_next = mom_sum_y2_reg;
            RBB+12'h53c: reg_rd_data_next = mom_sum_y2_reg >> 32;
            RBB+12'h540: reg_rd_data_next = mom_sum_xy_reg;
            RBB+12'h544: reg_rd_data_next = mom_sum_xy_reg >> 32;
            default: reg_rd_ack_next = 1'b0;
        endcase
    end

    // store read response
    if (s_axis_dma_read_desc_status_valid) begin
        dma_read_desc_status_tag_next = s_axis_dma_read_desc_status_tag;
        dma_read_desc_status_error_next = s_axis_dma_read_desc_status_error;
        dma_read_desc_status_valid_next = s_axis_dma_read_desc_status_valid;
    end

    // store write response
    if (s_axis_dma_write_desc_status_valid) begin
        dma_write_desc_status_tag_next = s_axis_dma_write_desc_status_tag;
        dma_write_desc_status_error_next = s_axis_dma_write_desc_status_error;
        dma_write_desc_status_valid_next = s_axis_dma_write_desc_status_valid;
    end

    // block read
    if (dma_read_block_run_reg) begin
        dma_read_block_cycle_count_next = dma_read_block_cycle_count_reg + 1;

        if (dma_read_block_count_reg == 0) begin
            if (dma_read_active_count_reg == 0) begin
                dma_read_block_run_next = 1'b0;
            end
        end else begin
            if (!dma_read_desc_valid_reg || (m_axis_dma_read_desc_ready && !mom_busy)) begin
                dma_read_block_dma_offset_next = dma_read_block_dma_offset_reg + dma_read_block_dma_stride_reg;
                dma_read_desc_dma_addr_next = dma_read_block_dma_base_addr_reg + (dma_read_block_dma_offset_reg & dma_read_block_dma_offset_mask_reg);
                dma_read_block_ram_offset_next = dma_read_block_ram_offset_reg + dma_read_block_ram_stride_reg;
                dma_read_desc_ram_addr_next = dma_read_block_ram_base_addr_reg + (dma_read_block_ram_offset_reg & dma_read_block_ram_offset_mask_reg);
                dma_read_desc_len_next = dma_read_block_len_reg;
                dma_read_block_count_next = dma_read_block_count_reg - 1;
                dma_read_desc_tag_next = dma_read_block_count_reg;
                dma_read_desc_valid_next = 1'b1;
            end
        end
    end

    // block write
    if (dma_write_block_run_reg) begin
        dma_write_block_cycle_count_next = dma_write_block_cycle_count_reg + 1;

        if (dma_write_block_count_reg == 0) begin
            if (dma_write_active_count_reg == 0) begin
                dma_write_block_run_next = 1'b0;
            end
        end else begin
            if (!dma_write_desc_valid_reg || (m_axis_dma_write_desc_ready && !mom_busy)) begin
                dma_write_block_dma_offset_next = dma_write_block_dma_offset_reg + dma_write_block_dma_stride_reg;
                dma_write_desc_dma_addr_next = dma_write_block_dma_base_addr_reg + (dma_write_block_dma_offset_reg & dma_write_block_dma_offset_mask_reg);
                dma_write_block_ram_offset_next = dma_write_block_ram_offset_reg + dma_write_block_ram_stride_reg;
                dma_write_desc_ram_addr_imm_next = dma_write_block_ram_base_addr_reg + (dma_write_block_ram_offset_reg & dma_write_block_ram_offset_mask_reg);
                dma_write_desc_imm_en_next = 1'b0;
                dma_write_desc_len_next = dma_write_block_len_reg;
                dma_write_block_count_next = dma_write_block_count_reg - 1;
                dma_write_desc_tag_next = dma_write_block_count_reg;
                dma_write_desc_valid_next = 1'b1;
            end
        end
    end
end

always @(posedge clk) begin
    reg_wr_ack_reg <= reg_wr_ack_next;
    reg_rd_data_reg <= reg_rd_data_next;
    reg_rd_ack_reg <= reg_rd_ack_next;

    cycle_count_reg <= cycle_count_reg + 1;

    dma_read_active_count_reg <= dma_read_active_count_reg
        + (m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready)
        - s_axis_dma_read_desc_status_valid;
    dma_write_active_count_reg <= dma_write_active_count_reg
        + (m_axis_dma_write_desc_valid && m_axis_dma_write_desc_ready)
        - s_axis_dma_write_desc_status_valid;

    dma_read_desc_dma_addr_reg <= dma_read_desc_dma_addr_next;
    dma_read_desc_ram_addr_reg <= dma_read_desc_ram_addr_next;
    dma_read_desc_len_reg <= dma_read_desc_len_next;
    dma_read_desc_tag_reg <= dma_read_desc_tag_next;
    dma_read_desc_valid_reg <= dma_read_desc_valid_next;

    dma_read_desc_status_tag_reg <= dma_read_desc_status_tag_next;
    dma_read_desc_status_error_reg <= dma_read_desc_status_error_next;
    dma_read_desc_status_valid_reg <= dma_read_desc_status_valid_next;

    dma_write_desc_dma_addr_reg <= dma_write_desc_dma_addr_next;
    dma_write_desc_ram_addr_imm_reg <= dma_write_desc_ram_addr_imm_next;
    dma_write_desc_imm_en_reg <= dma_write_desc_imm_en_next;
    dma_write_desc_len_reg <= dma_write_desc_len_next;
    dma_write_desc_tag_reg <= dma_write_desc_tag_next;
    dma_write_desc_valid_reg <= dma_write_desc_valid_next;

    dma_write_desc_status_tag_reg <= dma_write_desc_status_tag_next;
    dma_write_desc_status_error_reg <= dma_write_desc_status_error_next;
    dma_write_desc_status_valid_reg <= dma_write_desc_status_valid_next;

    dma_rd_int_en_reg <= dma_rd_int_en_next;
    dma_wr_int_en_reg <= dma_wr_int_en_next;

    dma_read_block_run_reg <= dma_read_block_run_next;
    dma_read_block_len_reg <= dma_read_block_len_next;
    dma_read_block_count_reg <= dma_read_block_count_next;
    dma_read_block_cycle_count_reg <= dma_read_block_cycle_count_next;
    dma_read_block_dma_base_addr_reg <= dma_read_block_dma_base_addr_next;
    dma_read_block_dma_offset_reg <= dma_read_block_dma_offset_next;
    dma_read_block_dma_offset_mask_reg <= dma_read_block_dma_offset_mask_next;
    dma_read_block_dma_stride_reg <= dma_read_block_dma_stride_next;
    dma_read_block_ram_base_addr_reg <= dma_read_block_ram_base_addr_next;
    dma_read_block_ram_offset_reg <= dma_read_block_ram_offset_next;
    dma_read_block_ram_offset_mask_reg <= dma_read_block_ram_offset_mask_next;
    dma_read_block_ram_stride_reg <= dma_read_block_ram_stride_next;

    dma_write_block_run_reg <= dma_write_block_run_next;
    dma_write_block_len_reg <= dma_write_block_len_next;
    dma_write_block_count_reg <= dma_write_block_count_next;
    dma_write_block_cycle_count_reg <= dma_write_block_cycle_count_next;
    dma_write_block_dma_base_addr_reg <= dma_write_block_dma_base_addr_next;
    dma_write_block_dma_offset_reg <= dma_write_block_dma_offset_next;
    dma_write_block_dma_offset_mask_reg <= dma_write_block_dma_offset_mask_next;
    dma_write_block_dma_stride_reg <= dma_write_block_dma_stride_next;
    dma_write_block_ram_base_addr_reg <= dma_write_block_ram_base_addr_next;
    dma_write_block_ram_offset_reg <= dma_write_block_ram_offset_next;
    dma_write_block_ram_offset_mask_reg <= dma_write_block_ram_offset_mask_next;
    dma_write_block_ram_stride_reg <= dma_write_block_ram_stride_next;

    if (rst) begin
        reg_wr_ack_reg <= 1'b0;
        reg_rd_ack_reg <= 1'b0;

        cycle_count_reg <= 0;
        dma_read_active_count_reg <= 0;
        dma_write_active_count_reg <= 0;

        dma_read_desc_valid_reg <= 1'b0;
        dma_read_desc_status_valid_reg <= 1'b0;
        dma_write_desc_valid_reg <= 1'b0;
        dma_write_desc_status_valid_reg <= 1'b0;
        dma_rd_int_en_reg <= 1'b0;
        dma_wr_int_en_reg <= 1'b0;
        dma_read_block_run_reg <= 1'b0;
        dma_write_block_run_reg <= 1'b0;
    end
end

// The host first completes its H2C DMA into RAM, then starts this engine.
// New descriptors and RAM accesses are held off while the engine owns the
// read ports.  On completion the existing DMA read/write path resumes.
always @(posedge clk) begin
    mom_xy_valid_reg <= 1'b0;
    mom_prod_valid_reg <= mom_xy_valid_reg;

    if (mom_xy_valid_reg) begin
        mom_prod_x2_reg <= $signed(mom_x_reg) * $signed(mom_x_reg);
        mom_prod_y2_reg <= $signed(mom_y_reg) * $signed(mom_y_reg);
        mom_prod_xy_reg <= $signed(mom_x_reg) * $signed(mom_y_reg);
    end
    if (mom_prod_valid_reg) begin
        mom_sum_x2_reg <= mom_sum_x2_reg + mom_prod_x2_reg;
        mom_sum_y2_reg <= mom_sum_y2_reg + mom_prod_y2_reg;
        mom_sum_xy_reg <= mom_sum_xy_reg + mom_prod_xy_reg;
    end

    if (reg_wr_en && !reg_wr_ack_reg) begin
        if ({reg_wr_addr >> 2, 2'b00} == RBB+12'h508 && !mom_busy)
            mom_count_reg <= reg_wr_data;

        if ({reg_wr_addr >> 2, 2'b00} == RBB+12'h50c && !mom_busy) begin
            if (reg_wr_data[0]) begin
                mom_done_reg <= 1'b0;
                mom_error_reg <= 1'b0;
                mom_error_code_reg <= 0;
                mom_sum_x_reg <= 0;
                mom_sum_y_reg <= 0;
                mom_sum_x2_reg <= 0;
                mom_sum_y2_reg <= 0;
                mom_sum_xy_reg <= 0;
                mom_xy_valid_reg <= 1'b0;
                mom_prod_valid_reg <= 1'b0;

                if (!mom_count_reg || mom_count_reg > 1024) begin
                    mom_done_reg <= 1'b1;
                    mom_error_reg <= 1'b1;
                    mom_error_code_reg <= MOM_ERR_COUNT;
                end else if (!dma_idle_for_mom) begin
                    mom_done_reg <= 1'b1;
                    mom_error_reg <= 1'b1;
                    mom_error_code_reg <= MOM_ERR_DMA_BUSY;
                end else begin
                    mom_remaining_reg <= mom_count_reg[10:0];
                    mom_row_addr_reg <= 0;
                    mom_req_pending_reg <= {RAM_SEG_COUNT{1'b1}};
                    mom_resp_seen_reg <= 0;
                    mom_state_reg <= MOM_REQ;
                end
            end else if (reg_wr_data[1]) begin
                mom_done_reg <= 1'b0;
                mom_error_reg <= 1'b0;
                mom_error_code_reg <= 0;
            end
        end
    end

    case (mom_state_reg)
        MOM_REQ: begin
            mom_req_pending_reg <= mom_req_pending_reg & ~ram_rd_cmd_ready_int;
            if (!(|(mom_req_pending_reg & ~ram_rd_cmd_ready_int)))
                mom_state_reg <= MOM_WAIT;
        end
        MOM_WAIT: begin
            if (ram_rd_resp_valid_int[0] && mom_ram_rd_resp_ready[0]) begin
                mom_seg0_reg <= ram_rd_resp_data_int[0 +: 256];
                mom_resp_seen_reg[0] <= 1'b1;
            end
            if (ram_rd_resp_valid_int[1] && mom_ram_rd_resp_ready[1]) begin
                mom_seg1_reg <= ram_rd_resp_data_int[256 +: 256];
                mom_resp_seen_reg[1] <= 1'b1;
            end
            if (&mom_resp_seen_reg)
                mom_state_reg <= MOM_LOAD;
        end
        MOM_LOAD: begin
            mom_row_data_reg <= {mom_seg1_reg, mom_seg0_reg};
            mom_row_remaining_reg <= mom_remaining_reg > 8 ? 4'd8 :
                                     mom_remaining_reg[3:0];
            mom_state_reg <= MOM_PROCESS;
        end
        MOM_PROCESS: begin
            if (!mom_input_valid) begin
                mom_xy_valid_reg <= 1'b0;
                mom_prod_valid_reg <= 1'b0;
                mom_done_reg <= 1'b1;
                mom_error_reg <= 1'b1;
                mom_error_code_reg <= MOM_ERR_RANGE;
                mom_state_reg <= MOM_IDLE;
            end else begin
                mom_x_reg <= mom_input_x;
                mom_y_reg <= mom_input_y;
                mom_xy_valid_reg <= 1'b1;
                mom_sum_x_reg <= mom_sum_x_reg +
                    {{32{mom_input_x[31]}}, mom_input_x};
                mom_sum_y_reg <= mom_sum_y_reg +
                    {{32{mom_input_y[31]}}, mom_input_y};
                mom_row_data_reg <= mom_row_data_reg >> 64;
                mom_remaining_reg <= mom_remaining_reg - 1'b1;
                mom_row_remaining_reg <= mom_row_remaining_reg - 1'b1;

                if (mom_remaining_reg == 1) begin
                    mom_state_reg <= MOM_FLUSH;
                end else if (mom_row_remaining_reg == 1) begin
                    mom_row_addr_reg <= mom_row_addr_reg + 1'b1;
                    mom_req_pending_reg <= {RAM_SEG_COUNT{1'b1}};
                    mom_resp_seen_reg <= 0;
                    mom_state_reg <= MOM_REQ;
                end
            end
        end
        MOM_FLUSH: begin
            if (!mom_xy_valid_reg && !mom_prod_valid_reg) begin
                mom_done_reg <= 1'b1;
                mom_state_reg <= MOM_IDLE;
            end
        end
        default: begin end
    endcase

    if (rst) begin
        mom_state_reg <= MOM_IDLE;
        mom_count_reg <= 0;
        mom_done_reg <= 1'b0;
        mom_error_reg <= 1'b0;
        mom_error_code_reg <= 0;
        mom_xy_valid_reg <= 1'b0;
        mom_prod_valid_reg <= 1'b0;
        mom_sum_x_reg <= 0;
        mom_sum_y_reg <= 0;
        mom_sum_x2_reg <= 0;
        mom_sum_y2_reg <= 0;
        mom_sum_xy_reg <= 0;
    end
end

dma_psdpram #(
    .SIZE(16384),
    .SEG_COUNT(RAM_SEG_COUNT),
    .SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .PIPELINE(2)
)
dma_ram_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Write port
     */
    .wr_cmd_be(dma_ram_wr_cmd_be),
    .wr_cmd_addr(dma_ram_wr_cmd_addr),
    .wr_cmd_data(dma_ram_wr_cmd_data),
    .wr_cmd_valid(mom_busy ? {RAM_SEG_COUNT{1'b0}} : dma_ram_wr_cmd_valid),
    .wr_cmd_ready(ram_wr_cmd_ready_int),
    .wr_done(ram_wr_done_int),

    /*
     * Read port
     */
    .rd_cmd_addr(mom_busy ? {RAM_SEG_COUNT{mom_row_addr_reg}} :
                 dma_ram_rd_cmd_addr),
    .rd_cmd_valid(mom_busy ? mom_ram_rd_cmd_valid : dma_ram_rd_cmd_valid),
    .rd_cmd_ready(ram_rd_cmd_ready_int),
    .rd_resp_data(ram_rd_resp_data_int),
    .rd_resp_valid(ram_rd_resp_valid_int),
    .rd_resp_ready(mom_busy ? mom_ram_rd_resp_ready :
                   dma_ram_rd_resp_ready)
);

endmodule

`resetall
