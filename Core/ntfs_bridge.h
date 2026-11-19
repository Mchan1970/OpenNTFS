/*
 * ntfs_bridge.h - A small, self-contained C API over libntfs-3g.
 *
 * The FSKit extension (Swift) and the command line test tool both talk to
 * NTFS exclusively through this header, so none of the libntfs-3g types
 * leak into Swift.
 *
 * Conventions
 *   - Functions returning int return 0 on success or a negative errno.
 *   - Functions returning int64_t return a byte count or a negative errno.
 *   - Names are UTF-8, NUL terminated.
 *   - libntfs-3g is not thread safe: the caller must serialise every call
 *     made on the same volume.
 *
 * This file is part of a GPL-2.0-or-later licensed project because it links
 * against libntfs-3g.
 */
#ifndef NTFS_BRIDGE_H
#define NTFS_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- device */

/* Block device callbacks. Offsets and counts handed to these callbacks are
 * always multiples of sector_size. */
typedef struct ntfsb_device {
	void *ctx;
	/* Return bytes transferred or a negative errno. */
	int64_t (*pread)(void *ctx, void *buf, int64_t count, int64_t offset);
	int64_t (*pwrite)(void *ctx, const void *buf, int64_t count, int64_t offset);
	/* Flush to stable storage. Return 0 or a negative errno. */
	int (*sync)(void *ctx);
	uint64_t size_bytes;
	uint32_t sector_size;
	int read_only;
} ntfsb_device;

/* ------------------------------------------------------------------ types */

typedef struct ntfsb_volume ntfsb_volume;

#define NTFSB_ROOT_INO 5ULL

/* Mount flags */
#define NTFSB_MOUNT_RDONLY          0x1  /* never write to the device */
#define NTFSB_MOUNT_NO_RECOVER      0x2  /* refuse volumes with a dirty journal */
#define NTFSB_MOUNT_SHOW_SYSTEM     0x4  /* expose $MFT & friends */
#define NTFSB_MOUNT_CASE_SENSITIVE  0x8  /* POSIX semantics instead of Windows */

/* Why a read-write mount was downgraded to read-only (ntfsb_info.ro_reason) */
#define NTFSB_RO_NONE        0
#define NTFSB_RO_REQUESTED   1
#define NTFSB_RO_DEVICE      2  /* the device itself is write protected */
#define NTFSB_RO_HIBERNATED  3  /* Windows is hibernated / fast startup */
#define NTFSB_RO_UNCLEAN     4  /* journal is dirty and could not be replayed */

typedef struct ntfsb_stat {
	uint64_t ino;
	uint64_t parent_ino;      /* 0 if unknown */
	uint32_t mode;            /* S_IFxxx | permission bits */
	uint32_t nlink;
	uint64_t size;
	uint64_t alloc_size;
	struct timespec atime;
	struct timespec mtime;
	struct timespec ctime;
	struct timespec btime;
	uint32_t ntfs_attrs;      /* raw FILE_ATTR_* flags */
	uint32_t bsd_flags;       /* UF_HIDDEN etc. */
	uint32_t rdev;
	/* Non-zero when the unnamed data stream cannot be handed to the kernel
	 * as plain extents (resident, compressed, encrypted, sparse ...). */
	int special_data;
} ntfsb_stat;

typedef struct ntfsb_info {
	char label[512];
	uint8_t serial[8];        /* volume serial number, little endian */
	uint32_t cluster_size;
	uint32_t sector_size;
	uint64_t total_clusters;
	uint64_t free_clusters;
	uint64_t total_files;
	uint64_t free_files;
	int read_only;
	int ro_reason;
	uint8_t major_ver, minor_ver;
} ntfsb_info;

/* Directory entry types reported by ntfsb_readdir. */
enum {
	NTFSB_DT_UNKNOWN = 0,   /* caller must stat (reparse points) */
	NTFSB_DT_REG,
	NTFSB_DT_DIR,
	NTFSB_DT_LNK,
	NTFSB_DT_FIFO,
	NTFSB_DT_SOCK,
	NTFSB_DT_CHR,
	NTFSB_DT_BLK,
};

/* Return non-zero to stop the enumeration. */
typedef int (*ntfsb_dirent_cb)(void *ctx, const char *name, size_t name_len,
		uint64_t ino, int dtype);

/* Return non-zero to stop. */
typedef int (*ntfsb_xattr_cb)(void *ctx, const char *name, uint64_t size);

/* One contiguous run of a file. physical < 0 means a hole (reads as zero). */
typedef struct ntfsb_extent {
	int64_t logical;    /* byte offset in the file */
	int64_t physical;   /* byte offset on the device, or -1 for a hole */
	int64_t length;     /* bytes */
} ntfsb_extent;

/* ---------------------------------------------------------------- logging */

enum { NTFSB_LOG_DEBUG = 0, NTFSB_LOG_INFO, NTFSB_LOG_WARNING, NTFSB_LOG_ERROR };
typedef void (*ntfsb_log_cb)(int level, const char *message);
void ntfsb_set_log_callback(ntfsb_log_cb cb, int min_level);

/* ----------------------------------------------------------------- volume */

/* Cheap check of the boot sector only. Returns 0 if it looks like NTFS and
 * fills label-less info (serial, sizes); -EINVAL if not NTFS. */
int ntfsb_probe(const ntfsb_device *dev, ntfsb_info *info);

/* Mount. On failure returns NULL and stores a negative errno in *err. */
ntfsb_volume *ntfsb_mount(const ntfsb_device *dev, unsigned flags,
		uid_t uid, gid_t gid, int *err);
int ntfsb_unmount(ntfsb_volume *v);
int ntfsb_sync(ntfsb_volume *v);
int ntfsb_get_info(ntfsb_volume *v, ntfsb_info *info);
int ntfsb_set_label(ntfsb_volume *v, const char *label);

/* ------------------------------------------------------------- namespace */

int ntfsb_getattr(ntfsb_volume *v, uint64_t ino, ntfsb_stat *st);

/* actual_name (optional) receives a malloc()ed copy of the on-disk spelling
 * of the name; the caller frees it. */
int ntfsb_lookup(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		ntfsb_stat *st, char **actual_name);

/* Enumerates every entry except "." and "..". */
int ntfsb_readdir(ntfsb_volume *v, uint64_t dir_ino, ntfsb_dirent_cb cb,
		void *ctx);

/* type is S_IFREG or S_IFDIR. */
int ntfsb_create(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		mode_t type, ntfsb_stat *st);
int ntfsb_symlink(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		const char *target, ntfsb_stat *st);
/* *target is malloc()ed; the caller frees it. */
int ntfsb_readlink(ntfsb_volume *v, uint64_t ino, char **target);
int ntfsb_link(ntfsb_volume *v, uint64_t ino, uint64_t dir_ino,
		const char *name);
int ntfsb_remove(ntfsb_volume *v, uint64_t dir_ino, const char *name);
int ntfsb_rename(ntfsb_volume *v, uint64_t src_dir, const char *src_name,
		uint64_t dst_dir, const char *dst_name);

/* ------------------------------------------------------------------ files */

int64_t ntfsb_read(ntfsb_volume *v, uint64_t ino, void *buf, size_t size,
		int64_t offset);
int64_t ntfsb_write(ntfsb_volume *v, uint64_t ino, const void *buf,
		size_t size, int64_t offset);
int ntfsb_truncate(ntfsb_volume *v, uint64_t ino, uint64_t size);
/* Finish a write session (flushes a pending compression block). */
int ntfsb_release(ntfsb_volume *v, uint64_t ino);

/* Any of the timespec pointers may be NULL to leave that time unchanged. */
int ntfsb_set_times(ntfsb_volume *v, uint64_t ino,
		const struct timespec *atime, const struct timespec *mtime,
		const struct timespec *ctime, const struct timespec *btime);
/* Only UF_HIDDEN is stored (as FILE_ATTR_HIDDEN). */
int ntfsb_set_bsd_flags(ntfsb_volume *v, uint64_t ino, uint32_t flags);

/* --------------------------------------------------- kernel offloaded I/O */

/* Reserved for FSKit kernel-offloaded I/O, which is NOT implemented: both
 * functions always return -ENOTSUP and never touch the volume. The FSKit
 * extension does not call them; all file data goes through ntfsb_read /
 * ntfsb_write. Intended semantics if this is ever implemented:
 *   ntfsb_map_extents: map [offset, offset+length) of the unnamed data
 *     stream to device extents (number stored, <= max, or -errno).
 *   ntfsb_commit_size: after the kernel wrote to such extents, publish the
 *     new data size / initialized size (never shrinks). */
int ntfsb_map_extents(ntfsb_volume *v, uint64_t ino, int64_t offset,
		int64_t length, int allocate, ntfsb_extent *out, int max);
int ntfsb_commit_size(ntfsb_volume *v, uint64_t ino, uint64_t new_size);

/* ----------------------------------------------- xattrs (named streams) */

int ntfsb_listxattr(ntfsb_volume *v, uint64_t ino, ntfsb_xattr_cb cb,
		void *ctx);
/* Returns the attribute size, copying up to size bytes when buf != NULL.
 * -ENOATTR when missing. */
int64_t ntfsb_getxattr(ntfsb_volume *v, uint64_t ino, const char *name,
		void *buf, size_t size);
/* flags: XATTR_CREATE / XATTR_REPLACE from <sys/xattr.h>, or 0. */
int ntfsb_setxattr(ntfsb_volume *v, uint64_t ino, const char *name,
		const void *buf, size_t size, int flags);
int ntfsb_removexattr(ntfsb_volume *v, uint64_t ino, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* NTFS_BRIDGE_H */
