/*
 * ntfs_maint.c - run mkntfs / ntfsfix in-process on a bridge device.
 *
 * The two programs are compiled unmodified from Vendor/ntfs-3g/ntfsprogs
 * with a few -D redirections (see the Makefile / project.yml):
 *
 *   main                     -> mkntfs_main / ntfsfix_main
 *   exit                     -> ntfsm_exit        (longjmp back to us)
 *   ntfs_device_unix_io_ops  -> ntfsb_maint_io_ops (our block device)
 *   ntfs_mount               -> ntfsb_maint_mount
 *   ntfs_log_handler_outerr  -> ntfsm_log_handler  (capture output)
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "config.h"

#include <errno.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "types.h"
#include "logging.h"

#include "ntfs_maint.h"

int mkntfs_main(int argc, char *argv[]);
int ntfsfix_main(int argc, char *argv[]);
void ntfsm_exit(int status) __attribute__((noreturn));
ntfs_log_handler ntfsm_log_handler __attribute__((format(printf, 6, 0)));

/* implemented in ntfs_bridge.c */
void ntfsb_maint_set_device(const ntfsb_device *dev);
void ntfsb_restore_logging(void);

static jmp_buf g_jmp;
static int g_jmp_armed;
static int g_exit_status;
static ntfsm_output_cb g_out;
static void *g_out_ctx;
static char g_line[2048];
static size_t g_line_len;

static void flush_line(void)
{
	if (g_line_len && g_out) {
		g_line[g_line_len] = 0;
		g_out(g_out_ctx, g_line);
	}
	g_line_len = 0;
}

static void emit(const char *text)
{
	for (; *text; text++) {
		if (*text == '\n' || *text == '\r') {
			flush_line();
			continue;
		}
		if (g_line_len < sizeof(g_line) - 1)
			g_line[g_line_len++] = *text;
	}
}

int ntfsm_log_handler(const char *function, const char *file, int line,
		u32 level, void *data, const char *format, va_list args)
{
	char buf[2048];
	int saved = errno;

	(void)function; (void)file; (void)line; (void)data;
	/* function tracing is noise for whoever reads the tool's report */
	if (level & (NTFS_LOG_LEVEL_TRACE | NTFS_LOG_LEVEL_DEBUG
			| NTFS_LOG_LEVEL_ENTER | NTFS_LOG_LEVEL_LEAVE))
		return 0;
	vsnprintf(buf, sizeof(buf), format, args);
	emit(buf);
	if (level & NTFS_LOG_LEVEL_PERROR) {
		emit(": ");
		emit(strerror(saved));
		emit("\n");
	}
	errno = saved;
	return 0;
}

void ntfsm_exit(int status)
{
	if (g_jmp_armed) {
		g_exit_status = status;
		longjmp(g_jmp, 1);
	}
	_exit(status);
}

static int run(int (*tool)(int, char **), const ntfsb_device *dev, int argc,
		char **argv, ntfsm_output_cb out, void *ctx)
{
	volatile int rc;

	g_out = out;
	g_out_ctx = ctx;
	g_line_len = 0;
	g_exit_status = 0;
	ntfsb_maint_set_device(dev);
	optind = 1;
	optreset = 1;
	opterr = 0;
	g_jmp_armed = 1;
	if (!setjmp(g_jmp))
		rc = tool(argc, argv);
	else
		rc = g_exit_status;
	g_jmp_armed = 0;
	flush_line();
	ntfsb_maint_set_device(NULL);
	ntfsb_restore_logging();
	g_out = NULL;
	g_out_ctx = NULL;
	return rc;
}

int ntfsm_format(const ntfsb_device *dev, const char *label,
		uint32_t cluster_size, int quick, ntfsm_output_cb out, void *ctx)
{
	char cs[32], ss[32];
	char *argv[20];
	int argc = 0;

	if (!dev || !dev->pwrite || dev->read_only)
		return -EROFS;
	snprintf(ss, sizeof(ss), "%u", dev->sector_size);
	argv[argc++] = "mkntfs";
	argv[argc++] = "-F";                 /* the "device" is not a block special file */
	if (quick)
		argv[argc++] = "-Q";
	argv[argc++] = "-s";
	argv[argc++] = ss;
	/* geometry only matters for booting Windows from the volume */
	argv[argc++] = "-p"; argv[argc++] = "0";
	argv[argc++] = "-H"; argv[argc++] = "0";
	argv[argc++] = "-S"; argv[argc++] = "0";
	if (cluster_size) {
		snprintf(cs, sizeof(cs), "%u", cluster_size);
		argv[argc++] = "-c";
		argv[argc++] = cs;
	}
	if (label && *label) {
		argv[argc++] = "-L";
		argv[argc++] = (char *)label;
	}
	argv[argc++] = "ntfs-device";
	argv[argc] = NULL;
	return run(mkntfs_main, dev, argc, argv, out, ctx);
}

int ntfsm_check(const ntfsb_device *dev, int repair, ntfsm_output_cb out,
		void *ctx)
{
	char *argv[8];
	int argc = 0;

	if (!dev)
		return -EINVAL;
	if (repair && (!dev->pwrite || dev->read_only))
		return -EROFS;
	argv[argc++] = "ntfsfix";
	if (!repair)
		argv[argc++] = "-n";
	argv[argc++] = "ntfs-device";
	argv[argc] = NULL;
	return run(ntfsfix_main, dev, argc, argv, out, ctx);
}
