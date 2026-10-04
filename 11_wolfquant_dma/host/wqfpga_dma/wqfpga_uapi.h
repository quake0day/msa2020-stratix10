/* SPDX-License-Identifier: BSD-2-Clause */
#ifndef WQFPGA_UAPI_H
#define WQFPGA_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define WQFPGA_ABI_VERSION             1U
#define WQFPGA_APP_ID                  0x12348001U
#define WQFPGA_FEAT_MOMENTS_V1         (1U << 0)
#define WQFPGA_OP_MOMENTS              1U
#define WQFPGA_MOMENTS_FORMAT_VERSION  1U
#define WQFPGA_MOMENTS_MAX_PAIRS       1024U
#define WQFPGA_MOMENTS_Q_FRAC_BITS     20U
#define WQFPGA_MOMENTS_INPUT_MIN       (-8388608)
#define WQFPGA_MOMENTS_INPUT_MAX       8388607

/* Each input record is two little-endian signed 32-bit Q20 values (x, y).
 * The five output values are little-endian signed 64-bit raw accumulators:
 * sum_x, sum_y, sum_x2, sum_y2, sum_xy.  The squared/cross terms are Q40.
 */
#define WQFPGA_MOMENTS_INPUT_STRIDE    8U
#define WQFPGA_MOMENTS_OUTPUT_BYTES    40U

struct wqfpga_caps {
	__u32 struct_size;
	__u32 abi_version;
	__u32 features;
	__u32 app_id;
	__u32 moments_kernel_version;
	__u32 moments_max_pairs;
	__u32 moments_q_frac_bits;
	__s32 moments_input_min;
	__s32 moments_input_max;
	__u32 reserved[7];
};

/* v1 is synchronous.  The driver copies input into its own buffer before
 * posting DMA and copies the result to output_ptr only after completion.
 * Neither pointer is a DMA address.  user_cookie is returned unchanged and
 * lets a future SUBMIT/REAP API retain the same job identity convention.
 */
struct wqfpga_exec {
	__u32 struct_size;
	__u32 abi_version;
	__u32 opcode;
	__u32 format_version;
	__u32 flags;
	__u32 pair_count;
	__u32 input_bytes;
	__u32 output_capacity;
	__aligned_u64 input_ptr;
	__aligned_u64 output_ptr;
	__aligned_u64 user_cookie;
	__u32 result_bytes;
	__u32 reserved0;
	__aligned_u64 reserved[4];
};

#define WQFPGA_IOC_MAGIC       'W'
#define WQFPGA_IOC_GET_CAPS    _IOWR(WQFPGA_IOC_MAGIC, 0x00, struct wqfpga_caps)
#define WQFPGA_IOC_EXEC        _IOWR(WQFPGA_IOC_MAGIC, 0x01, struct wqfpga_exec)

#endif /* WQFPGA_UAPI_H */
