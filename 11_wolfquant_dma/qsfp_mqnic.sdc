# ============================================================================
# qsfp_mqnic.sdc  --  阶段4 mqnic A-2020 时序约束 (改自 Corundum 520N_MX, 单 QSFP)
# ============================================================================
set_time_format -unit ns -decimal_places 3

create_clock -name {usr_refclk0} -period 10.000 [get_ports {usr_refclk0}]
create_clock -name {pcie_refclk} -period 10.000 [get_ports {pcie_refclk}]
create_clock -name {qsfp0_refclk} -period 1.551 [get_ports {qsfp0_refclk}]
create_clock -name {altera_reserved_tck} -period 62.500 {altera_reserved_tck}

derive_clock_uncertainty

set_clock_groups -asynchronous -group [get_clocks {usr_refclk0}]
set_clock_groups -asynchronous -group [get_clocks {pcie_refclk}]
set_clock_groups -asynchronous -group [get_clocks {qsfp0_refclk}]
set_clock_groups -asynchronous -group {altera_reserved_tck}

set_false_path -to [get_ports {led_user_grn[*] led_user_red[*] led_qsfp[*]}]
set_false_path -from [get_ports {qsfp_irq_n[*]}]
set_false_path -to   [get_ports {fpga_i2c_sda fpga_i2c_scl fpga_i2c_req_l}]
set_false_path -from [get_ports {fpga_i2c_sda fpga_i2c_scl fpga_i2c_mux_gnt}]

# 收发器恢复时钟互相异步 (QSFP0 quad, 4 通道)
proc constrain_phy { inst } {
    set_clock_groups -asynchronous -group [get_clocks "${inst}|eth_xcvr_inst|tx_clkout|ch0"]
    set_clock_groups -asynchronous -group [get_clocks "${inst}|eth_xcvr_inst|rx_clkout|ch0"]
    set_clock_groups -asynchronous -group [get_clocks "${inst}|eth_xcvr_inst|profile0|tx_clkout|ch0"]
    set_clock_groups -asynchronous -group [get_clocks "${inst}|eth_xcvr_inst|profile0|rx_clkout|ch0"]
    set_clock_groups -asynchronous -group [get_clocks "${inst}|eth_xcvr_inst|profile1|tx_clkout|ch0"]
    set_clock_groups -asynchronous -group [get_clocks "${inst}|eth_xcvr_inst|profile1|rx_clkout|ch0"]
}
proc constrain_phy_quad { inst } {
    constrain_phy "${inst}|eth_xcvr_phy_1"
    constrain_phy "${inst}|eth_xcvr_phy_2"
    constrain_phy "${inst}|eth_xcvr_phy_3"
    constrain_phy "${inst}|eth_xcvr_phy_4"
}
constrain_phy_quad "qsfp0_eth_xcvr_phy_quad"

# ---- mqnic 基础设施时钟约束 (照搬 Corundum 520N_MX fpga.sdc) ----
source sync_reset.sdc
set_clock_groups -asynchronous -group [get_clocks "iopll_100mhz_inst|iopll_0_outclk0"]
set_clock_groups -asynchronous -group [get_clocks "ref_div_inst|stratix10_clkctrl_0|clkdiv_inst|clock_div4"]
constrain_sync_reset_inst "sync_reset_100mhz_inst"
constrain_sync_reset_inst "ptp_rst_reset_sync_inst"
