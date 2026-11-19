/*
 * ntfs_maint.h - format and check NTFS volumes through the bridge's block
 * device callbacks. Wraps the mkntfs and ntfsfix programs of ntfsprogs.
 *
 * Not thread safe and not reentrant: serialise with every other bridge call.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef NTFS_MAINT_H
#define NTFS_MAINT_H

#include "ntfs_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Receives the tools' progress and diagnostic output, one line at a time. */
typedef void (*ntfsm_output_cb)(void *ctx, const char *line);

/*
 * Create a new NTFS file system. cluster_size 0 picks the default.
 * quick skips zeroing the device and the bad sector scan.
 * Returns 0 on success, a positive tool exit status or a negative errno.
 */
int ntfsm_format(const ntfsb_device *dev, const char *label,
		uint32_t cluster_size, int quick, ntfsm_output_cb out, void *ctx);

/*
 * Check the volume. With repair set, fixes what ntfsfix can fix (MFT mirror,
 * journal reset, dirty flag, boot sector backup). Without, nothing is
 * written. Returns 0 when the volume is fine or was repaired.
 */
int ntfsm_check(const ntfsb_device *dev, int repair, ntfsm_output_cb out,
		void *ctx);

#ifdef __cplusplus
}
#endif

#endif
