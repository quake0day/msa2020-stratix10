// SPDX-License-Identifier: BSD-2-Clause
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "wqfpga_uapi.h"

_Static_assert(sizeof(struct wqfpga_caps) == 64, "caps ABI size changed");
_Static_assert(sizeof(struct wqfpga_exec) == 96, "exec ABI size changed");
_Static_assert(offsetof(struct wqfpga_exec, input_ptr) == 32,
	       "input pointer ABI offset changed");
_Static_assert(offsetof(struct wqfpga_exec, output_ptr) == 40,
	       "output pointer ABI offset changed");

#define BENCH_SAMPLES 200U
#define BENCH_WARMUPS 5U

static volatile int64_t cpu_benchmark_sink;

static void put_le32(uint8_t *dst, uint32_t value)
{
	unsigned int i;

	for (i = 0; i < 4; i++)
		dst[i] = (uint8_t)(value >> (i * 8));
}

static uint32_t get_le32(const uint8_t *src)
{
	return (uint32_t)src[0] | (uint32_t)src[1] << 8 |
		(uint32_t)src[2] << 16 | (uint32_t)src[3] << 24;
}

static int64_t get_le64(const uint8_t *src)
{
	uint64_t bits = 0;
	unsigned int i;

	for (i = 0; i < 8; i++)
		bits |= (uint64_t)src[i] << (i * 8);
	return (int64_t)bits;
}

static uint32_t random_word(uint32_t *state)
{
	uint32_t x = *state;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	return *state = x;
}

static void fill_case(uint8_t *input, uint32_t count, uint32_t seed,
		      int64_t expected[5])
{
	uint32_t rng = seed;
	uint32_t i;

	memset(expected, 0, 5 * sizeof(*expected));
	for (i = 0; i < count; i++) {
		int32_t x, y;

		if (i == 0) {
			x = WQFPGA_MOMENTS_INPUT_MIN;
			y = WQFPGA_MOMENTS_INPUT_MAX;
		} else if (i == 1) {
			x = WQFPGA_MOMENTS_INPUT_MAX;
			y = WQFPGA_MOMENTS_INPUT_MIN;
		} else {
			x = (int32_t)(random_word(&rng) % 16777216U) - 8388608;
			y = (int32_t)(random_word(&rng) % 16777216U) - 8388608;
		}
		put_le32(input + i * 8, (uint32_t)x);
		put_le32(input + i * 8 + 4, (uint32_t)y);
		expected[0] += x;
		expected[1] += y;
		expected[2] += (int64_t)x * x;
		expected[3] += (int64_t)y * y;
		expected[4] += (int64_t)x * y;
	}
}

static void cpu_moments(const uint8_t *input, uint32_t count,
			int64_t sums[5])
{
	uint32_t i;

	memset(sums, 0, 5 * sizeof(*sums));
	for (i = 0; i < count; i++) {
		int32_t x = (int32_t)get_le32(input + i * 8);
		int32_t y = (int32_t)get_le32(input + i * 8 + 4);

		sums[0] += x;
		sums[1] += y;
		sums[2] += (int64_t)x * x;
		sums[3] += (int64_t)y * y;
		sums[4] += (int64_t)x * y;
	}
}

static double elapsed_us(const struct timespec *begin,
			 const struct timespec *end)
{
	return (double)(end->tv_sec - begin->tv_sec) * 1000000.0 +
		(double)(end->tv_nsec - begin->tv_nsec) / 1000.0;
}

static int compare_double(const void *a, const void *b)
{
	const double x = *(const double *)a;
	const double y = *(const double *)b;

	return (x > y) - (x < y);
}

static int benchmark_case(int fd, uint32_t count)
{
	uint8_t input[WQFPGA_MOMENTS_MAX_PAIRS *
		WQFPGA_MOMENTS_INPUT_STRIDE];
	uint8_t output[WQFPGA_MOMENTS_OUTPUT_BYTES];
	int64_t expected[5], cpu_result[5];
	double fpga_us[BENCH_SAMPLES], cpu_us[BENCH_SAMPLES];
	const unsigned int cpu_repeats = count == 20 ? 1000 : 100;
	struct wqfpga_exec job = {
		.struct_size = sizeof(job),
		.abi_version = WQFPGA_ABI_VERSION,
		.opcode = WQFPGA_OP_MOMENTS,
		.format_version = WQFPGA_MOMENTS_FORMAT_VERSION,
		.pair_count = count,
		.input_bytes = count * WQFPGA_MOMENTS_INPUT_STRIDE,
		.output_capacity = sizeof(output),
		.input_ptr = (uintptr_t)input,
		.output_ptr = (uintptr_t)output,
	};
	unsigned int i, j;

	fill_case(input, count, 0x5c39a117U + count, expected);
	for (i = 0; i < BENCH_WARMUPS + BENCH_SAMPLES; i++) {
		struct timespec start, end;

		job.result_bytes = 0;
		memset(output, 0xa5, sizeof(output));
		if (clock_gettime(CLOCK_MONOTONIC_RAW, &start) < 0) {
			perror("clock_gettime");
			return 1;
		}
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) < 0) {
			perror("benchmark EXEC");
			return 1;
		}
		if (clock_gettime(CLOCK_MONOTONIC_RAW, &end) < 0) {
			perror("clock_gettime");
			return 1;
		}
		if (job.result_bytes != sizeof(output)) {
			fprintf(stderr, "benchmark result length mismatch\n");
			return 1;
		}
		for (j = 0; j < 5; j++) {
			if (get_le64(output + j * 8) != expected[j]) {
				fprintf(stderr, "benchmark mismatch for %u pairs, field %u\n",
					count, j);
				return 1;
			}
		}
		if (i >= BENCH_WARMUPS)
			fpga_us[i - BENCH_WARMUPS] = elapsed_us(&start, &end);
	}
	for (i = 0; i < BENCH_SAMPLES; i++) {
		struct timespec start, end;

		if (clock_gettime(CLOCK_MONOTONIC_RAW, &start) < 0) {
			perror("clock_gettime");
			return 1;
		}
		for (j = 0; j < cpu_repeats; j++) {
			/* Prevent hoisting an invariant reference computation. */
			__asm__ __volatile__("" ::: "memory");
			cpu_moments(input, count, cpu_result);
			cpu_benchmark_sink ^= cpu_result[j % 5];
		}
		if (clock_gettime(CLOCK_MONOTONIC_RAW, &end) < 0) {
			perror("clock_gettime");
			return 1;
		}
		if (memcmp(cpu_result, expected, sizeof(expected))) {
			fprintf(stderr, "CPU benchmark reference mismatch\n");
			return 1;
		}
		cpu_us[i] = elapsed_us(&start, &end) / cpu_repeats;
	}
	qsort(fpga_us, BENCH_SAMPLES, sizeof(fpga_us[0]), compare_double);
	qsort(cpu_us, BENCH_SAMPLES, sizeof(cpu_us[0]), compare_double);
	printf("%u pairs (%u input bytes, %u host-to-card DMA descriptor%s), %u samples:\n",
	       count, job.input_bytes,
	       (job.input_bytes + 4095U) / 4096U,
	       job.input_bytes > 4096U ? "s" : "", BENCH_SAMPLES);
	printf("  FPGA EXEC end-to-end: p50 %.3f us, p99 %.3f us\n",
	       fpga_us[99], fpga_us[197]);
	printf("  CPU integer reference: p50 %.3f us, p99 %.3f us (%u repeats/sample)\n",
	       cpu_us[99], cpu_us[197], cpu_repeats);
	return 0;
}

static int benchmark_test(int fd)
{
	struct wqfpga_caps caps = {
		.struct_size = sizeof(caps),
		.abi_version = WQFPGA_ABI_VERSION,
	};
	int ret;

	if (ioctl(fd, WQFPGA_IOC_GET_CAPS, &caps) < 0) {
		perror("GET_CAPS");
		return 1;
	}
	if (caps.abi_version != WQFPGA_ABI_VERSION ||
	    caps.app_id != WQFPGA_APP_ID) {
		fprintf(stderr, "unexpected ABI or FPGA application ID\n");
		return 1;
	}
	if (!(caps.features & WQFPGA_FEAT_MOMENTS_V1)) {
		fprintf(stderr, "SKIP: moments v1 kernel absent\n");
		return 77;
	}
	ret = benchmark_case(fd, 20);
	if (ret)
		return ret;
	return benchmark_case(fd, 1024);
}

static int self_test(void)
{
	uint8_t sample[24];
	int64_t sums[5];
	static const int64_t expected[5] = {3, 0, 35, 56, -40};
	unsigned int i;

	put_le32(sample, 1);
	put_le32(sample + 4, 2);
	put_le32(sample + 8, (uint32_t)-3);
	put_le32(sample + 12, 4);
	put_le32(sample + 16, 5);
	put_le32(sample + 20, (uint32_t)-6);
	memset(sums, 0, sizeof(sums));
	for (i = 0; i < 3; i++) {
		int32_t x = (int32_t)get_le32(sample + i * 8);
		int32_t y = (int32_t)get_le32(sample + i * 8 + 4);

		sums[0] += x;
		sums[1] += y;
		sums[2] += (int64_t)x * x;
		sums[3] += (int64_t)y * y;
		sums[4] += (int64_t)x * y;
	}
	if (memcmp(sums, expected, sizeof(sums))) {
		fprintf(stderr, "moments CPU reference self-test failed\n");
		return 1;
	}
	printf("PASS: moments v1 CPU reference and little-endian input\n");
	return 0;
}

static int hardware_test(int fd)
{
	struct wqfpga_caps caps = {
		.struct_size = sizeof(caps),
		.abi_version = WQFPGA_ABI_VERSION,
	};
	static const uint32_t counts[] = {
		1, 2, 3, 8, 9, 63, 64, 65, 257, 511, 512, 1024
	};
	uint8_t input[WQFPGA_MOMENTS_MAX_PAIRS *
		WQFPGA_MOMENTS_INPUT_STRIDE];
	uint8_t output[WQFPGA_MOMENTS_OUTPUT_BYTES];
	int64_t expected[5];
	unsigned int i, j;

	if (ioctl(fd, WQFPGA_IOC_GET_CAPS, &caps) < 0) {
		perror("GET_CAPS");
		return 1;
	}
	if (caps.abi_version != WQFPGA_ABI_VERSION ||
	    caps.app_id != WQFPGA_APP_ID) {
		fprintf(stderr, "unexpected ABI or FPGA application ID\n");
		return 1;
	}
	if (!(caps.features & WQFPGA_FEAT_MOMENTS_V1)) {
		struct wqfpga_exec job = {
			.struct_size = sizeof(job),
			.abi_version = WQFPGA_ABI_VERSION,
			.opcode = WQFPGA_OP_MOMENTS,
			.format_version = WQFPGA_MOMENTS_FORMAT_VERSION,
			.pair_count = 1,
			.input_bytes = WQFPGA_MOMENTS_INPUT_STRIDE,
			.output_capacity = sizeof(output),
			.input_ptr = (uintptr_t)input,
			.output_ptr = (uintptr_t)output,
		};

		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 ||
		    errno != EOPNOTSUPP) {
			fprintf(stderr, "absent moments kernel did not return EOPNOTSUPP\n");
			return 1;
		}
		fprintf(stderr, "SKIP: moments v1 kernel absent (DMA scratch API remains available)\n");
		return 77;
	}
	if (caps.moments_kernel_version != 0x00010000U ||
	    caps.moments_max_pairs != WQFPGA_MOMENTS_MAX_PAIRS ||
	    caps.moments_q_frac_bits != WQFPGA_MOMENTS_Q_FRAC_BITS ||
	    caps.moments_input_min != WQFPGA_MOMENTS_INPUT_MIN ||
	    caps.moments_input_max != WQFPGA_MOMENTS_INPUT_MAX) {
		fprintf(stderr, "unexpected moments v1 capabilities\n");
		return 1;
	}
	for (i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
		struct wqfpga_exec job = {
			.struct_size = sizeof(job),
			.abi_version = WQFPGA_ABI_VERSION,
			.opcode = WQFPGA_OP_MOMENTS,
			.format_version = WQFPGA_MOMENTS_FORMAT_VERSION,
			.pair_count = counts[i],
			.input_bytes = counts[i] * WQFPGA_MOMENTS_INPUT_STRIDE,
			.output_capacity = sizeof(output),
			.input_ptr = (uintptr_t)input,
			.output_ptr = (uintptr_t)output,
			.user_cookie = 0x12340000U + i,
		};

		fill_case(input, counts[i], 0xa17c0000U + i, expected);
		memset(output, 0xa5, sizeof(output));
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) < 0) {
			perror("EXEC moments");
			return 1;
		}
		if (job.result_bytes != sizeof(output) ||
		    job.user_cookie != 0x12340000U + i) {
			fprintf(stderr, "bad result length or cookie for %u pairs\n",
				counts[i]);
			return 1;
		}
		for (j = 0; j < 5; j++) {
			int64_t actual = get_le64(output + j * 8);

			if (actual != expected[j]) {
				fprintf(stderr,
					"mismatch %u pairs, field %u: expected %" PRId64
					", got %" PRId64 "\n",
					counts[i], j, expected[j], actual);
				return 1;
			}
		}
	}
	{
		struct wqfpga_exec job = {
			.struct_size = sizeof(job),
			.abi_version = WQFPGA_ABI_VERSION,
			.opcode = WQFPGA_OP_MOMENTS,
			.format_version = WQFPGA_MOMENTS_FORMAT_VERSION,
			.pair_count = 1,
			.input_bytes = WQFPGA_MOMENTS_INPUT_STRIDE,
			.output_capacity = sizeof(output),
			.input_ptr = (uintptr_t)input,
			.output_ptr = (uintptr_t)output,
		};

		job.pair_count = 0;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != EINVAL) {
			fprintf(stderr, "zero count was not rejected\n");
			return 1;
		}
		job.pair_count = WQFPGA_MOMENTS_MAX_PAIRS + 1;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != EINVAL) {
			fprintf(stderr, "oversize pair count was not rejected\n");
			return 1;
		}
		job.pair_count = 1;
		job.input_bytes = WQFPGA_MOMENTS_INPUT_STRIDE + 1;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != EINVAL) {
			fprintf(stderr, "bad input length was not rejected\n");
			return 1;
		}
		job.input_bytes = WQFPGA_MOMENTS_INPUT_STRIDE;
		job.output_capacity = sizeof(output) - 1;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != EINVAL) {
			fprintf(stderr, "undersize output capacity was not rejected\n");
			return 1;
		}
		job.output_capacity = sizeof(output);
		put_le32(input, (uint32_t)WQFPGA_MOMENTS_INPUT_MAX + 1);
		put_le32(input + 4, 0);
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != ERANGE) {
			fprintf(stderr, "out-of-range Q20 value was not rejected\n");
			return 1;
		}
		put_le32(input, (uint32_t)(WQFPGA_MOMENTS_INPUT_MIN - 1));
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != ERANGE) {
			fprintf(stderr, "low out-of-range Q20 value was not rejected\n");
			return 1;
		}
		put_le32(input, 0);
		job.opcode++;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 ||
		    errno != EOPNOTSUPP) {
			fprintf(stderr, "unsupported opcode was not rejected\n");
			return 1;
		}
		job.opcode = WQFPGA_OP_MOMENTS;
		job.format_version++;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 ||
		    errno != EOPNOTSUPP) {
			fprintf(stderr, "unsupported format version was not rejected\n");
			return 1;
		}
		job.format_version = WQFPGA_MOMENTS_FORMAT_VERSION;
		job.abi_version++;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 ||
		    errno != EOPNOTSUPP) {
			fprintf(stderr, "unsupported ABI version was not rejected\n");
			return 1;
		}
		job.abi_version = WQFPGA_ABI_VERSION;
		job.reserved[0] = 1;
		if (ioctl(fd, WQFPGA_IOC_EXEC, &job) != -1 || errno != EINVAL) {
			fprintf(stderr, "nonzero reserved field was not rejected\n");
			return 1;
		}
	}
	printf("PASS: moments v1 exact FPGA/CPU parity for 12 sizes up to 1024 pairs and invalid-input checks\n");
	return 0;
}

int main(int argc, char **argv)
{
	const char *path = "/dev/wqfpga0";
	int benchmark = 0;
	int fd, ret;

	if (argc == 2 && !strcmp(argv[1], "--self-test"))
		return self_test();
	if (argc >= 2 && !strcmp(argv[1], "--benchmark")) {
		benchmark = 1;
		if (argc == 3)
			path = argv[2];
	} else if (argc == 2) {
		path = argv[1];
	}
	if (argc > (benchmark ? 3 : 2)) {
		fprintf(stderr, "usage: %s [device|--self-test|--benchmark [device]]\n",
			argv[0]);
		return 2;
	}
	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	ret = benchmark ? benchmark_test(fd) : hardware_test(fd);
	if (close(fd) < 0) {
		perror("close");
		return 1;
	}
	return ret;
}
