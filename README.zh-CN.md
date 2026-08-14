# MSA-2020 (Microsoft A-2020) FPGA 板卡实验集

[English](README.md) | **中文**

面向退役数据中心 FPGA 板卡 **MSA-2020**（Microsoft Catapult A-2020，
Stratix 10 `1SG280LN2F43E2VG`）的开源实验工程与上位机工具。

## 项目列表

| # | 项目 | 内容 | 状态 |
|---|------|------|------|
| **1** | [Blink](1_Blink/) | LED 灯效引擎 + ISSP 上位机通道 + 电脑 GUI 点按钮控制/实时回显 | ✅ **烧录即用**，板侧 LED 计数器规律闪烁 |
| **2** | [EMIF](2_EMIF/) | DDR4 内存：EMIF 校准 + 电脑直接读写 8GB RDIMM，**双通道**(DIMM0+DIMM1) | ✅ **硬件验证**：双通道均校准成功、读写各 16/16 字通过 |
| **3** | [PCIE_DMA](3_PCIE_DMA/) | 独立 PCIe 最小实验：主机经 BAR0 直接读写 FPGA 256KB 片内 RAM（hip_ast + Corundum TLP 栈） | ✅ **硬件验证**：主机读写 256KB BAR，全 65536 字唯一值/字节使能/边界均通过 |
| **4** | [100GBase_loop](4_100GBase_loop/) | QSFP0 收发器点亮 + retimer + 100G MAC，环回验证 | ✅ 收发器 4×25.78G 环回 / retimer 均**硬件验证**；⛔ bonded 100G MAC 板级受限 |
| **5** | [Corundum_fork_on_MSA2020](5_Corundum_fork_on_MSA2020/) | Corundum mqnic NIC 移植（PCIe DMA + 100G） | ✅ **硬件验证**：枚举 1234:1001 + 驱动 probe + 双网口 + DMA 队列（Gen2 x8）；光口收发待插 QSFP |
| **7** | [video_accel](7_video_accel/) | **视频计算加速器**：PCIe BAR 后端换成视频计算引擎，9 模式（RGB↔YUV/灰度/反色/AI 归一化/阈值/亮度对比度 + 3×3 卷积：模糊/锐化/Sobel/浮雕） | ✅ **硬件验证**：9 模式逐位对上软件参考，全 PASS |
| **8** | [dct_codec](8_dct_codec/) | **8×8 DCT/IDCT 变换核**（H.264/H.265/JPEG 共用的变换心脏），系数由 `gen_dct.py` 生成、RTL 与主机参考同表 | ✅ **硬件验证**：FDCT/IDCT 逐位对上参考，往返重建成功 |
| **9** | [ddr4_framebuffer](9_ddr4_framebuffer/) | **PCIe→DDR4 帧缓存**：AXI-Lite↔Avalon 跨时钟桥驱动 EMIF（复用项目 2） | 🟡 **整条通路硬件跑通**：枚举 + 双 DIMM 校准 + ~90% 读写正确；剩 ~10% 间歇读错 = 板载 150MHz 参考时钟把 DDR4 锁死 2400MT/s 下的 DQS 选通时序余量不足（非集成 bug，已定位） |
| **10** | [h264_encoder](10_h264_encoder/) | **开源 H.264 编码器集成**：把 [openasic-org/xk264](https://github.com/openasic-org/xk264)（复旦，完整 Baseline 编码器）移植到 S10，PCIe BAR 功能外壳（喂 YUV → 取 H.264 码流） | ✅ **硬件验证闭环**：主机写帧 → 硬件编码（50MHz 独立时钟域，双时钟外壳 `h264_wrap_dc`）→ 读回码流**与仿真 golden 逐字节相同** → 软件打包 SPS/PPS → ffmpeg 解码重建原图（QP27，Y 平均误差 0.702）。见 [H264_INTEGRATION.md](10_h264_encoder/H264_INTEGRATION.md) |

**7~10 = 视频计算加速器**（图像预处理 + 视频滤波 + AI 前处理 + 编解码变换 + 帧缓存，
全部走已验证的 PCIe BAR 框架）。工作流：**先 iverilog 仿真对照 Python 位精确参考，再 Quartus 编译**——
这套流程在编译前抓到了两个同类 BRAM 读延迟 bug（FSM 少插等待态）。烧录测试指南见 [VIDEO_ACCEL_TOMORROW.md](VIDEO_ACCEL_TOMORROW.md)。

> **项目 10 排障实录**（两个叠加 bug，对"仿真对、硅片错"有普适参考价值）：
> ① 编码结果非确定 = 手写 AXI-Lite 异步跨域握手余量不足 → 重构为**双时钟真双口 BRAM +
> 单 bit 同步**（`h264_wrap_dc.v`，时间上分离读写），非确定性即消失；
> ② 修后仍确定性错（541B vs 仿真 168B）= `cur_mb.v` 缺 `` `include "enc_defines.v"``：
> iverilog/Questa 把命令行全部文件当**一个编译单元**（宏泄漏，端口 64 位正确），
> **Quartus Pro 按文件独立编译单元** → `` `BIT_DEPTH`` 未定义 → 像素端口塌成 9 位。
> 修复 = qsf 加 `VERILOG_MACRO "BIT_DEPTH=8"`。线索其实一直在综合警告里
> （`16735: actual bit length 64 differs from formal bit length 9`）——**宽度失配警告务必逐条审**。

> **H.264/H.265 说明**：完整 H.264/H.265 编解码器无法从零手写（运动估计+CABAC+去块滤波是巨型 IP）。
> 项目 8 交付其数学核心 DCT/IDCT；项目 10 集成真实开源核 xk264。**xk264 源码未包含在本仓库**
> （其许可禁止再分发，需自行 `git clone`）；本仓库只含集成文档、工程 qsf 与我原创的 FPGA 存储库
> `mem_fpga/`（替换其 ASIC 三态模型）。H.264 另有 MPEG-LA 专利池，商用出货需授权。
> H.265 开源硬件仅有 HLS（Catapult）流程的 uvgKvazaarHW，无纯 RTL 核。

每个项目目录自成一体（Quartus 工程 + RTL + 上位机脚本 + README）。用
Quartus Prime Pro 23.3 打开各自的 `.qpf` 编译，或直接烧录自带的 `.sof`。
（4 是多个子工程合集，见其目录内 README。）

## 板卡关键知识（各实验共用，踩坑实录）

- **JTAG 限制**：板载 FT232H 用 Catapult 定制驱动
  （`jtag_hw_microsoft_catapult.dll`），只支持烧录和简单移位；
  System Console 的 JTAG-Avalon streaming 会**永久挂死**。
  所有上位机通信因此走 **ISSP**（单次移位），实测稳定 ~150 操作/秒。
- **VID 供电配置**（`PWRMGT_*`、SDM 引脚）**必须**与官方 blink 示例一致，
  配错可能烧毁板卡——各 qsf 均已包含，勿改。
- **DDR4**：**4 个独立通道**，DIMM0/1/2/3 ↔ `ddr4_mem[2]/[3]/[0]/[1]`
  （CK 脚 AP10/L6/AU22/K31）；每通道只布线 9 组 DQS + 1 片选 →
  **只支持 1Rx8**（x8 颗粒、单 rank），上限 2400MT/s。双通道见 2_EMIF README。
- **DDR4 校准根因**（详见 2_EMIF README）：RDIMM 的 PAR/ALERT_n 必须连接；
  时序参数（TCL/WTCL）让 EMIF IP 自动推导、勿手工锁定。
- 板级共享 I2C：`SCL=AC28 / SDA=AB28`（3.0-V LVTTL），挂有 DIMM SPD (0x50)、
  FPC202、DS250DF810 retimer 等。
- **QSFP0 收发器**（25.78G GXT）：refclk `AD34`（644.53125MHz），
  TX/RX 接**非连续物理通道 0,1,3,4**（为 4×25G 独立 lane 设计，非 bonded 100G）；
  正解拓扑 = Corundum 520N_MX（master ATX + atx_blw 缓冲 + iqclk refclk），
  `anlg_link=sr`。详见 4 / 5 内 README。
- 100MHz 用户时钟 `PIN_AD6`（1.8V）；同款板参考
  [SuperSodaSea/Plugcat](https://github.com/SuperSodaSea/Plugcat)。
- **PCIe**：Gen3 x16，`TX BB34..` / `RX AV30..` / refclk `AM34` / perst `AC26`。

## 上位机环境

Windows + Python 3 + Quartus Prime Pro 23.3（syscon 作 JTAG 后端）。
首次使用需按板卡资料包安装 FTDI D2XX 驱动并把定制 dll 复制到 `quartus\bin64`。
（注：5 Corundum mqnic 的**网卡驱动仅 Linux**，Windows 只能验证 PCIe 枚举，
见 `5_Corundum_fork_on_MSA2020/HOST_VALIDATION.md`。）

## 路线图

- [x] 1 LED 控制 + 上位机 GUI
- [x] 2 DDR4 EMIF 单通道 + **双通道**（DIMM0+DIMM1，硬件验证）
- [x] 4 QSFP0 4×25.78G 收发器环回（硬件验证）+ retimer（硬件验证）
- [x] 5 Corundum mqnic 移植编译出 .sof
- [x] 5 mqnic 主机 PCIe 槽 + Linux 驱动**硬件验证**（枚举 + probe + 双网口 + DMA 队列；kernel 7.0 驱动移植补丁见其 HOST_VALIDATION.md）
- [x] 3 独立 PCIe 最小实验**硬件验证** BAR 读写（hip_ast + Corundum TLP 栈，BAR0→256KB 片内 RAM）
- [x] 7 视频计算引擎 9 模式**硬件验证**（颜色空间转换/滤波/AI 前处理，逐位对上参考）
- [x] 8 8×8 DCT/IDCT 变换核**硬件验证**（FDCT/IDCT 往返重建）
- [x] 9 PCIe→DDR4 帧缓存整条通路**硬件跑通**（双 DIMM 校准 + ~90%；余 10% = 2400MT/s 读时序余量，受板载 150MHz 参考时钟约束）
- [x] 10 开源 H.264 编码器 xk264 在 S10**综合通过**
- [x] 10 H.264 编码器 PCIe 功能外壳**硬件验证闭环**（喂 YUV → 编码 → 码流逐字节==仿真 golden → ffmpeg 解码重建原图）
- [ ] 2 DDR4 四通道扩展（DIMM2/DIMM3，同法可扩）
- [ ] 4 bonded 100G MAC（板级受限，探索中）
- [ ] 5 mqnic 光口实际收发包（需插 QSFP28 模块/环回件）
- [ ] 9 DDR4 帧缓存 100%（受限于 150MHz 参考时钟锁死 2400MT/s；改进方向 Read DBI / 片上帧缓存）
- [ ] 10 H.264 大分辨率支持（扩输入/输出 BRAM 或 ext_ 参考帧接 DDR4；当前验证 96×64 intra-only）
