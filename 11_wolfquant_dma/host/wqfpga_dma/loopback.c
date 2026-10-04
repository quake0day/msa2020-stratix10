// SPDX-License-Identifier: BSD-2-Clause
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define CHUNK 4096
#define CARD_BYTES 8192

struct test_shape {
	off_t offset;
	size_t length;
};

static const struct test_shape shapes[] = {
	{0, 1},       /* single byte */
	{1, 257},     /* unaligned offset and length */
	{4093, 17},   /* cross the 4 KiB boundary */
	{4096, 4096}, /* whole upper half */
	{8191, 1},    /* last byte of the exposed window */
	{2047, 4096}, /* large crossing transfer */
	{0, 4095},
};

static void die(const char *where)
{
	perror(where);
	exit(EXIT_FAILURE);
}

static void transfer_exact(int fd, void *buffer, size_t len, off_t offset,
			   int to_card)
{
	size_t done = 0;
	while (done < len) {
		ssize_t n;
		if (to_card)
			n = pwrite(fd, (char *)buffer + done, len - done,
				   offset + (off_t)done);
		else
			n = pread(fd, (char *)buffer + done, len - done,
				  offset + (off_t)done);
		if (n < 0)
			die(to_card ? "pwrite" : "pread");
		if (!n) {
			fprintf(stderr, "%s returned zero before completion\n",
				to_card ? "pwrite" : "pread");
			exit(EXIT_FAILURE);
		}
		done += (size_t)n;
	}
}

static uint32_t random_word(uint32_t *state)
{
	uint32_t x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	return *state = x;
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/wqfpga0";
	unsigned long long total = 1024 * 1024;
	unsigned long long completed = 0;
	char *end = NULL;
	uint8_t src[CHUNK], dst[CHUNK];
	uint32_t rng = 0x51a7d00d;
	size_t shape_index = 0;
	int fd;

	if (argc > 1 && !strcmp(argv[1], "--help")) {
		printf("usage: %s [device] [bytes, default 1048576]\n", argv[0]);
		return 0;
	}
	if (argc > 3) {
		fprintf(stderr, "too many arguments\n");
		return 2;
	}
	if (argc == 3) {
		errno = 0;
		total = strtoull(argv[2], &end, 0);
		if (argv[2][0] == '-' || errno || !end || *end || !total) {
			fprintf(stderr, "invalid byte count\n");
			return 2;
		}
	}
	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		die("open");

	while (completed < total) {
		const struct test_shape *shape = &shapes[shape_index++ %
			(sizeof(shapes) / sizeof(shapes[0]))];
		size_t n = total - completed < shape->length ?
			(size_t)(total - completed) : shape->length;
		off_t card_offset = shape->offset;
		size_t i;

		if (card_offset + (off_t)n > CARD_BYTES) {
			fprintf(stderr, "card test window exceeded\n");
			return 2;
		}
		for (i = 0; i < n; i++)
			src[i] = (uint8_t)random_word(&rng);
		memset(dst, 0xa5, n);
		transfer_exact(fd, src, n, card_offset, 1);
		transfer_exact(fd, dst, n, card_offset, 0);
		if (memcmp(src, dst, n)) {
			for (i = 0; i < n && src[i] == dst[i]; i++) {}
			fprintf(stderr, "mismatch at byte %llu (card offset %lld): expected %02x, got %02x\n",
				completed + i, (long long)card_offset + (long long)i,
				src[i], dst[i]);
			close(fd);
			return 1;
		}
		completed += n;
	}
	if (close(fd))
		die("close");
	printf("PASS: %llu bytes read/write loopback on %s\n",
	       completed, path);
	return 0;
}
