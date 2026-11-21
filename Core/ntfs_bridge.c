/*
 * ntfs_bridge.c - libntfs-3g wrapped into a small inode-number based API.
 *
 * The structure of every operation follows the reference low level FUSE
 * driver shipped with ntfs-3g (src/lowntfs-3g.c): an inode is opened, used
 * and closed again within a single call, and a given inode is never opened
 * twice at the same time. libntfs-3g relies on that discipline.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "config.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/disk.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#include "types.h"
#include "attrib.h"
#include "bitmap.h"
#include "bootsect.h"
#include "cache.h"
#include "device.h"
#include "dir.h"
#include "inode.h"
#include "layout.h"
#include "lcnalloc.h"
#include "logging.h"
#include "misc.h"
#include "mft.h"
#include "mst.h"
#include "ntfstime.h"
#include "reparse.h"
#include "runlist.h"
#include "security.h"
#include "unistr.h"
#include "volume.h"

#include "ntfs_bridge.h"

struct ntfsb_volume {
	ntfs_volume *vol;
	uid_t uid;
	gid_t gid;
	int ro_reason;
	unsigned rename_seq;
	uint8_t serial[8];
	/*
	 * Write cache: the file currently being written stays open, so its
	 * MFT record and directory entry are not rewritten after every
	 * single write call (four scattered metadata writes per call, which
	 * is what makes flash drives crawl). Every operation other than
	 * read / write / getattr closes it first, see wcache_flush().
	 */
	ntfs_inode *w_ni;
	ntfs_attr *w_na;
	/*
	 * While a file is being appended to, clusters are allocated ahead
	 * in large steps instead of once per write call (each allocation
	 * rewrites part of $Bitmap and the file's MFT record). w_size is the
	 * real size of the file; the attribute may temporarily be larger and
	 * is trimmed back in wcache_flush(). The surplus lies beyond the
	 * attribute's initialized size, so it reads as zeroes and never
	 * exposes stale disk content.
	 */
	s64 w_size;
	/*
	 * Error ledger: the earliest flush error that has not
	 * been handed to a caller able to report it. 0 means none. Only
	 * ntfsb_sync() and ntfsb_unmount() consume it: a boundary reports
	 * the stored error when one is pending and otherwise its own
	 * attempt's result. Every later failure is only logged.
	 */
	int pending_err;
	/*
	 * Fail-closed marker: a trim failed half way, so bitmap,
	 * runlist and attribute sizes are already partially updated on disk
	 * and in memory. Retrying could skip the mapping pair update and
	 * leave clusters free in $Bitmap while an MFT record still references
	 * them. While set (positive errno) every modifying operation, write
	 * and sync fails; read-only access keeps working.
	 */
	int fatal_err;
};

#define PREALLOC_MIN	(16LL << 20)
#define PREALLOC_MAX	(256LL << 20)

/* ====================================================================== */
/* Logging                                                                */
/* ====================================================================== */

static ntfsb_log_cb g_log_cb;
static int g_log_min = NTFSB_LOG_WARNING;

static int bridge_log_handler(const char *function, const char *file, int line,
		u32 level, void *data, const char *format, va_list args)
{
	char buf[1024];
	int lvl, n, saved = errno;

	(void)file; (void)line; (void)data;
	if (!g_log_cb)
		return 0;
	if (level & (NTFS_LOG_LEVEL_ERROR | NTFS_LOG_LEVEL_PERROR
			| NTFS_LOG_LEVEL_CRITICAL))
		lvl = NTFSB_LOG_ERROR;
	else if (level & NTFS_LOG_LEVEL_WARNING)
		lvl = NTFSB_LOG_WARNING;
	else if (level & (NTFS_LOG_LEVEL_INFO | NTFS_LOG_LEVEL_VERBOSE
			| NTFS_LOG_LEVEL_PROGRESS | NTFS_LOG_LEVEL_QUIET))
		lvl = NTFSB_LOG_INFO;
	else
		lvl = NTFSB_LOG_DEBUG;
	if (lvl < g_log_min)
		return 0;
	n = snprintf(buf, sizeof(buf), "%s: ", function ? function : "ntfs");
	if (n < 0 || n >= (int)sizeof(buf))
		n = 0;
	vsnprintf(buf + n, sizeof(buf) - n, format, args);
	if (level & NTFS_LOG_LEVEL_PERROR) {
		size_t l = strlen(buf);
		while (l && (buf[l - 1] == '\n'))
			buf[--l] = 0;
		snprintf(buf + l, sizeof(buf) - l, ": %s", strerror(saved));
	} else {
		size_t l = strlen(buf);
		while (l && (buf[l - 1] == '\n'))
			buf[--l] = 0;
	}
	g_log_cb(lvl, buf);
	errno = saved;
	return 0;
}

void ntfsb_set_log_callback(ntfsb_log_cb cb, int min_level)
{
	g_log_cb = cb;
	g_log_min = min_level;
	ntfs_log_set_handler(bridge_log_handler);
	ntfs_log_set_levels(NTFS_LOG_LEVEL_ERROR | NTFS_LOG_LEVEL_PERROR
			| NTFS_LOG_LEVEL_CRITICAL | NTFS_LOG_LEVEL_WARNING
			| NTFS_LOG_LEVEL_INFO);
}

/* ====================================================================== */
/* Block device glue                                                      */
/* ====================================================================== */

struct bdev {
	ntfsb_device io;
	s64 pos;
	/*
	 * Errno of the last failed device write (including a failed
	 * prefetch of the read-modify-write in bdev_pwrite), recorded
	 * because ntfs_inode_sync_in_dir() collapses every non-EIO write
	 * error into EBUSY and the real reason would be lost otherwise.
	 */
	int last_werr;
};

#define BDEV(dev) ((struct bdev *)(dev)->d_private)

/* Raw transfer of a sector aligned range, looping over short transfers. */
static s64 bdev_xfer(struct bdev *b, void *buf, s64 count, s64 offset,
		int writing)
{
	s64 done = 0;

	while (done < count) {
		int64_t r;

		if (writing)
			r = b->io.pwrite(b->io.ctx, (const char *)buf + done,
					count - done, offset + done);
		else
			r = b->io.pread(b->io.ctx, (char *)buf + done,
					count - done, offset + done);
		if (r < 0) {
			errno = (int)-r;
			if (writing)
				b->last_werr = errno;
			return -1;
		}
		if (r == 0) {
			/* a write that makes no progress must not look like
			 * success. */
			if (writing)
				b->last_werr = EIO;
			break;
		}
		done += r;
	}
	return done;
}

static s64 bdev_pread(struct ntfs_device *dev, void *buf, s64 count,
		s64 offset)
{
	struct bdev *b = BDEV(dev);
	const s64 ss = b->io.sector_size;
	s64 start, end, got;
	char *bounce;

	if (count <= 0)
		return 0;
	if (offset < 0) {
		errno = EINVAL;
		return -1;
	}
	if (!(offset % ss) && !(count % ss))
		return bdev_xfer(b, buf, count, offset, 0);

	start = offset - (offset % ss);
	end = ((offset + count + ss - 1) / ss) * ss;
	bounce = malloc(end - start);
	if (!bounce) {
		errno = ENOMEM;
		return -1;
	}
	got = bdev_xfer(b, bounce, end - start, start, 0);
	if (got < 0) {
		free(bounce);
		return -1;
	}
	got -= (offset - start);
	if (got < 0)
		got = 0;
	if (got > count)
		got = count;
	memcpy(buf, bounce + (offset - start), got);
	free(bounce);
	return got;
}

static s64 bdev_pwrite(struct ntfs_device *dev, const void *buf, s64 count,
		s64 offset)
{
	struct bdev *b = BDEV(dev);
	const s64 ss = b->io.sector_size;
	s64 start, end, put, got;
	char *bounce;

	if (NDevReadOnly(dev)) {
		b->last_werr = EROFS;
		errno = EROFS;
		return -1;
	}
	if (count <= 0)
		return 0;
	if (offset < 0) {
		b->last_werr = EINVAL;
		errno = EINVAL;
		return -1;
	}
	NDevSetDirty(dev);
	if (!(offset % ss) && !(count % ss))
		return bdev_xfer(b, (void *)buf, count, offset, 1);

	/* Unaligned: read-modify-write the surrounding sectors. */
	start = offset - (offset % ss);
	end = ((offset + count + ss - 1) / ss) * ss;
	bounce = malloc(end - start);
	if (!bounce) {
		b->last_werr = ENOMEM;
		errno = ENOMEM;
		return -1;
	}
	got = bdev_xfer(b, bounce, ss, start, 0);
	if (got == ss && end - start > ss)
		got = bdev_xfer(b, bounce + (end - start) - ss, ss,
				end - ss, 0);
	if (got != ss) {
		free(bounce);
		/* A negative return is a real device error and errno is
		 * the one to report. A short prefetch read (0 bytes or
		 * less than a unit) has no errno of its own; a residual
		 * value from an earlier call must not leak into callers.
		 * Either way the write never reached the device, and
		 * upstream may discard the error (ntfs_index_ctx_put
		 * drops failed index block writes), so last_werr has to
		 * carry it for the error ledger. */
		if (got >= 0)
			errno = EIO;
		b->last_werr = errno;
		return -1;
	}
	memcpy(bounce + (offset - start), buf, count);
	put = bdev_xfer(b, bounce, end - start, start, 1);
	free(bounce);
	if (put < 0)
		return -1;
	if (put < end - start) {
		errno = EIO;
		return -1;
	}
	return count;
}

static int bdev_open(struct ntfs_device *dev, int flags)
{
	struct bdev *b = BDEV(dev);

	if (NDevOpen(dev)) {
		errno = EBUSY;
		return -1;
	}
	if (((flags & O_ACCMODE) != O_RDONLY) && b->io.read_only) {
		errno = EROFS;
		return -1;
	}
	if ((flags & O_ACCMODE) == O_RDONLY)
		NDevSetReadOnly(dev);
	else
		NDevClearReadOnly(dev);
	NDevSetBlock(dev);
	NDevSetOpen(dev);
	b->pos = 0;
	return 0;
}

static int bdev_sync(struct ntfs_device *dev)
{
	struct bdev *b = BDEV(dev);
	int r;

	if (NDevReadOnly(dev) || !NDevDirty(dev))
		return 0;
	r = b->io.sync ? b->io.sync(b->io.ctx) : 0;
	if (r < 0) {
		errno = -r;
		return -1;
	}
	NDevClearDirty(dev);
	return 0;
}

static int bdev_close(struct ntfs_device *dev)
{
	if (!NDevOpen(dev)) {
		errno = EBADF;
		return -1;
	}
	if (NDevDirty(dev))
		bdev_sync(dev);
	NDevClearOpen(dev);
	return 0;
}

static s64 bdev_seek(struct ntfs_device *dev, s64 offset, int whence)
{
	struct bdev *b = BDEV(dev);
	s64 n;

	switch (whence) {
	case SEEK_SET: n = offset; break;
	case SEEK_CUR: n = b->pos + offset; break;
	case SEEK_END: n = (s64)b->io.size_bytes + offset; break;
	default:
		errno = EINVAL;
		return -1;
	}
	if (n < 0) {
		errno = EINVAL;
		return -1;
	}
	b->pos = n;
	return n;
}

static s64 bdev_read(struct ntfs_device *dev, void *buf, s64 count)
{
	s64 r = bdev_pread(dev, buf, count, BDEV(dev)->pos);

	if (r > 0)
		BDEV(dev)->pos += r;
	return r;
}

static s64 bdev_write(struct ntfs_device *dev, const void *buf, s64 count)
{
	s64 r = bdev_pwrite(dev, buf, count, BDEV(dev)->pos);

	if (r > 0)
		BDEV(dev)->pos += r;
	return r;
}

static int bdev_stat(struct ntfs_device *dev, struct stat *st)
{
	struct bdev *b = BDEV(dev);

	memset(st, 0, sizeof(*st));
	st->st_mode = S_IFBLK | 0600;
	st->st_size = (off_t)b->io.size_bytes;
	st->st_blksize = (blksize_t)b->io.sector_size;
	st->st_blocks = (blkcnt_t)(b->io.size_bytes >> 9);
	return 0;
}

static int bdev_ioctl(struct ntfs_device *dev, unsigned long request,
		void *argp)
{
	struct bdev *b = BDEV(dev);

	switch (request) {
	case DKIOCGETBLOCKCOUNT:
		*(uint64_t *)argp = b->io.size_bytes / b->io.sector_size;
		return 0;
	case DKIOCGETBLOCKSIZE:
		*(uint32_t *)argp = b->io.sector_size;
		return 0;
	default:
		errno = ENOTTY;
		return -1;
	}
}

static struct ntfs_device_operations bdev_ops = {
	.open = bdev_open,
	.close = bdev_close,
	.seek = bdev_seek,
	.read = bdev_read,
	.write = bdev_write,
	.pread = bdev_pread,
	.pwrite = bdev_pwrite,
	.sync = bdev_sync,
	.stat = bdev_stat,
	.ioctl = bdev_ioctl,
};

struct ntfs_device *ntfsb_device_alloc(const ntfsb_device *io);

struct ntfs_device *ntfsb_device_alloc(const ntfsb_device *io)
{
	struct bdev *b;
	struct ntfs_device *dev;

	if (!io || !io->pread || !io->sector_size
	    || (io->sector_size & (io->sector_size - 1))) {
		errno = EINVAL;
		return NULL;
	}
	b = calloc(1, sizeof(*b));
	if (!b) {
		errno = ENOMEM;
		return NULL;
	}
	b->io = *io;
	if (!b->io.pwrite)
		b->io.read_only = 1;
	dev = ntfs_device_alloc("ntfsb", 0, &bdev_ops, b);
	if (!dev) {
		int e = errno;
		free(b);
		errno = e;
	}
	return dev;
}

/*
 * Device operations for the in-process mkntfs / ntfsfix (ntfs_maint.c).
 * Those programs allocate their device themselves, by name, so the block
 * device callbacks are bound when the device is opened.
 */
static const ntfsb_device *g_maint_io;

void ntfsb_maint_set_device(const ntfsb_device *io);
void ntfsb_restore_logging(void);
ntfs_volume *ntfsb_maint_mount(const char *name, ntfs_mount_flags flags);

void ntfsb_maint_set_device(const ntfsb_device *io)
{
	g_maint_io = io;
}

void ntfsb_restore_logging(void)
{
	ntfsb_set_log_callback(g_log_cb, g_log_min);
}

static int maint_open(struct ntfs_device *dev, int flags)
{
	if (!dev->d_private) {
		struct bdev *b;

		if (!g_maint_io) {
			errno = ENXIO;
			return -1;
		}
		b = calloc(1, sizeof(*b));
		if (!b) {
			errno = ENOMEM;
			return -1;
		}
		b->io = *g_maint_io;
		if (!b->io.pwrite)
			b->io.read_only = 1;
		dev->d_private = b;
	}
	if (bdev_open(dev, flags)) {
		if (!NDevOpen(dev)) {
			free(dev->d_private);
			dev->d_private = NULL;
		}
		return -1;
	}
	return 0;
}

static int maint_close(struct ntfs_device *dev)
{
	int r;

	if (!dev->d_private) {
		errno = EBADF;
		return -1;
	}
	r = bdev_close(dev);
	if (!r) {
		free(dev->d_private);
		dev->d_private = NULL;
	}
	return r;
}

#define MAINT_GUARD(dev) do { if (!(dev)->d_private) { \
	errno = EBADF; return -1; } } while (0)

static s64 maint_seek(struct ntfs_device *dev, s64 o, int w)
{ MAINT_GUARD(dev); return bdev_seek(dev, o, w); }
static s64 maint_read(struct ntfs_device *dev, void *b, s64 c)
{ MAINT_GUARD(dev); return bdev_read(dev, b, c); }
static s64 maint_write(struct ntfs_device *dev, const void *b, s64 c)
{ MAINT_GUARD(dev); return bdev_write(dev, b, c); }
static s64 maint_pread(struct ntfs_device *dev, void *b, s64 c, s64 o)
{ MAINT_GUARD(dev); return bdev_pread(dev, b, c, o); }
static s64 maint_pwrite(struct ntfs_device *dev, const void *b, s64 c, s64 o)
{ MAINT_GUARD(dev); return bdev_pwrite(dev, b, c, o); }
static int maint_sync(struct ntfs_device *dev)
{ MAINT_GUARD(dev); return bdev_sync(dev); }
static int maint_stat(struct ntfs_device *dev, struct stat *st)
{
	/* may be called before open(): answer from the pending device */
	if (!dev->d_private) {
		if (!g_maint_io) {
			errno = EBADF;
			return -1;
		}
		memset(st, 0, sizeof(*st));
		st->st_mode = S_IFBLK | 0600;
		st->st_size = (off_t)g_maint_io->size_bytes;
		st->st_blksize = (blksize_t)g_maint_io->sector_size;
		return 0;
	}
	return bdev_stat(dev, st);
}
static int maint_ioctl(struct ntfs_device *dev, unsigned long r, void *a)
{ MAINT_GUARD(dev); return bdev_ioctl(dev, r, a); }

struct ntfs_device_operations ntfsb_maint_io_ops = {
	.open = maint_open,
	.close = maint_close,
	.seek = maint_seek,
	.read = maint_read,
	.write = maint_write,
	.pread = maint_pread,
	.pwrite = maint_pwrite,
	.sync = maint_sync,
	.stat = maint_stat,
	.ioctl = maint_ioctl,
};

ntfs_volume *ntfsb_maint_mount(const char *name, ntfs_mount_flags flags)
{
	struct ntfs_device *dev;
	ntfs_volume *vol;

	dev = ntfs_device_alloc(name, 0, &ntfsb_maint_io_ops, NULL);
	if (!dev)
		return NULL;
	vol = ntfs_device_mount(dev, flags);
	if (!vol) {
		int eo = errno;

		ntfs_device_free(dev);
		errno = eo;
	} else
		ntfs_create_lru_caches(vol);
	return vol;
}

static void bdev_free(struct ntfs_device *dev)
{
	void *priv = dev->d_private;

	ntfs_device_free(dev);
	free(priv);
}

/* ====================================================================== */
/* Names                                                                  */
/* ====================================================================== */

/*
 * Windows refuses a handful of characters that are perfectly legal on a
 * Mac. Like Apple's SMB client we store them in the Unicode private use
 * area ("Services for Macintosh" mapping), so Windows can still open,
 * copy and delete the file, and the Mac sees the original name.
 */
static ntfschar sfm_to_disk(unsigned c, int last)
{
	if (c >= 0x01 && c <= 0x1f)
		return cpu_to_le16(0xf000 + c);
	switch (c) {
	case '"':  return const_cpu_to_le16(0xf020);
	case '*':  return const_cpu_to_le16(0xf021);
	case ':':  return const_cpu_to_le16(0xf022);
	case '<':  return const_cpu_to_le16(0xf023);
	case '>':  return const_cpu_to_le16(0xf024);
	case '?':  return const_cpu_to_le16(0xf025);
	case '\\': return const_cpu_to_le16(0xf026);
	case '|':  return const_cpu_to_le16(0xf027);
	case ' ':  if (last) return const_cpu_to_le16(0xf028); break;
	case '.':  if (last) return const_cpu_to_le16(0xf029); break;
	default: break;
	}
	return cpu_to_le16(c);
}

static ntfschar sfm_from_disk(unsigned c)
{
	static const char map[] = "\"*:<>?\\| .";

	if (c >= 0xf001 && c <= 0xf01f)
		return cpu_to_le16(c - 0xf000);
	if (c >= 0xf020 && c <= 0xf029)
		return cpu_to_le16((unsigned char)map[c - 0xf020]);
	return cpu_to_le16(c);
}

/*
 * UTF-8 -> on-disk UTF-16. With @mapped the SFM mapping is applied.
 * Returns the length in UTF-16 units or -1 with errno set.
 */
static int name_to_disk(const char *name, ntfschar **out, int mapped)
{
	ntfschar *u = NULL;
	int len, i;

	if (!name || !*name) {
		errno = EINVAL;
		return -1;
	}
	len = ntfs_mbstoucs(name, &u);
	if (len < 0)
		return -1;
	if (len > NTFS_MAX_NAME_LEN) {
		free(u);
		errno = ENAMETOOLONG;
		return -1;
	}
	if (mapped) {
		/* "." and ".." never reach us, so a trailing dot is a real one */
		for (i = 0; i < len; i++)
			u[i] = sfm_to_disk(le16_to_cpu(u[i]), i == len - 1);
	}
	*out = u;
	return len;
}

/* On-disk UTF-16 -> malloc()ed UTF-8 with the SFM mapping reverted. */
static char *name_from_disk(const ntfschar *uname, int len)
{
	ntfschar stackbuf[NTFS_MAX_NAME_LEN + 1];
	ntfschar *tmp = stackbuf;
	char *out = NULL;
	int i;

	if (len > NTFS_MAX_NAME_LEN) {
		tmp = malloc(sizeof(ntfschar) * (len + 1));
		if (!tmp)
			return NULL;
	}
	for (i = 0; i < len; i++) {
		ntfschar c;

		memcpy(&c, (const char *)uname + i * sizeof(ntfschar), sizeof(c));
		tmp[i] = sfm_from_disk(le16_to_cpu(c));
	}
	if (ntfs_ucstombs(tmp, len, &out, 0) < 0)
		out = NULL;
	if (tmp != stackbuf)
		free(tmp);
	return out;
}

/*
 * Look a name up in an open directory. Tries the SFM mapped spelling
 * first and then the literal one (files written by other drivers).
 * Returns the MFT reference or (u64)-1 with errno set; *uname / *ulen
 * receive the spelling that matched (or the mapped one when not found).
 */
static u64 dir_lookup(ntfs_inode *dir_ni, const char *name, ntfschar **uname,
		int *ulen)
{
	ntfschar *mapped = NULL, *raw = NULL;
	int mlen, rlen;
	u64 ref;

	*uname = NULL;
	mlen = name_to_disk(name, &mapped, 1);
	if (mlen < 0)
		return (u64)-1;
	ref = ntfs_inode_lookup_by_name(dir_ni, mapped, mlen);
	if (ref == (u64)-1 && errno == ENOENT) {
		rlen = name_to_disk(name, &raw, 0);
		if (rlen >= 0 && (rlen != mlen
				|| memcmp(raw, mapped, rlen * sizeof(ntfschar)))) {
			ref = ntfs_inode_lookup_by_name(dir_ni, raw, rlen);
			if (ref != (u64)-1) {
				free(mapped);
				*uname = raw;
				*ulen = rlen;
				return ref;
			}
		}
		free(raw);
		errno = ENOENT;
	}
	*uname = mapped;
	*ulen = mlen;
	return ref;
}

static BOOL ino_is_hidden_system(const ntfsb_volume *v, u64 ino)
{
	(void)v;
	return (ino < FILE_first_user) && (ino != FILE_root);
}

/* ====================================================================== */
/* Attributes                                                             */
/* ====================================================================== */

static const struct timespec ts_zero;

static BOOL ni_is_dir(const ntfs_inode *ni)
{
	return (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
}

/* Walk the FILE_NAME attributes: POSIX link count and first parent. */
static void ni_names_info(ntfs_inode *ni, u32 *nlink, u64 *parent)
{
	ntfs_attr_search_ctx *ctx;
	u32 n = 0;
	u64 p = 0;

	ctx = ntfs_attr_get_search_ctx(ni, NULL);
	if (ctx) {
		while (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0,
				CASE_SENSITIVE, 0, NULL, 0, ctx)) {
			FILE_NAME_ATTR *fn = (FILE_NAME_ATTR *)((u8 *)ctx->attr
				+ le16_to_cpu(ctx->attr->value_offset));

			if (fn->file_name_type == FILE_NAME_DOS)
				continue;
			if (!n)
				p = MREF_LE(fn->parent_directory);
			n++;
		}
		ntfs_attr_put_search_ctx(ctx);
	}
	errno = 0;
	*nlink = n ? n : 1;
	*parent = p;
}

/* Can the unnamed data stream be described as plain device extents ? */
static int ni_data_is_special(ntfs_inode *ni)
{
	ntfs_attr_search_ctx *ctx;
	int special = 1;

	if (ni->flags & (FILE_ATTR_COMPRESSED | FILE_ATTR_ENCRYPTED
			| FILE_ATTR_SPARSE_FILE | FILE_ATTR_REPARSE_POINT))
		return 1;
	ctx = ntfs_attr_get_search_ctx(ni, NULL);
	if (!ctx)
		return 1;
	if (!ntfs_attr_lookup(AT_DATA, AT_UNNAMED, 0, CASE_SENSITIVE, 0,
			NULL, 0, ctx)) {
		ATTR_RECORD *a = ctx->attr;

		special = !a->non_resident
			|| (a->flags & (ATTR_COMPRESSION_MASK
				| ATTR_IS_ENCRYPTED | ATTR_IS_SPARSE));
	}
	ntfs_attr_put_search_ctx(ctx);
	errno = 0;
	return special;
}

/* Fill @st from an open inode. Returns 0 or a negative errno. */
static int ni_stat(ntfsb_volume *v, ntfs_inode *ni, ntfsb_stat *st)
{
	ntfs_attr *na;
	u32 nlink;
	u64 parent;

	memset(st, 0, sizeof(*st));
	st->ino = ni->mft_no;
	st->ntfs_attrs = le32_to_cpu(ni->flags);
	st->special_data = 1;
	ni_names_info(ni, &nlink, &parent);
	st->parent_ino = (ni->mft_no == FILE_root) ? FILE_root : parent;
	st->nlink = nlink;

	if ((ni->flags & FILE_ATTR_REPARSE_POINT) && ntfs_possible_symlink(ni)) {
		char *target;

		errno = 0;
		target = ntfs_make_symlink(ni, v->vol->abs_mnt_point);
		st->mode = S_IFLNK | 0777;
		st->size = target ? strlen(target) : 0;
		st->alloc_size = ni->allocated_size;
		free(target);
	} else if (ni_is_dir(ni)) {
		st->mode = S_IFDIR | 0777;
		if (!test_nino_flag(ni, KnownSize)) {
			na = ntfs_attr_open(ni, AT_INDEX_ALLOCATION,
					NTFS_INDEX_I30, 4);
			if (na) {
				ni->data_size = na->data_size;
				ni->allocated_size = na->allocated_size;
				set_nino_flag(ni, KnownSize);
				ntfs_attr_close(na);
			}
		}
		st->size = ni->data_size;
		st->alloc_size = ni->allocated_size;
		st->nlink = 1;
	} else {
		st->mode = S_IFREG | 0777;
		st->size = (ni == v->w_ni && v->w_na) ? v->w_size
						       : ni->data_size;
		st->alloc_size = ni->allocated_size;
		st->special_data = ni_data_is_special(ni);
		if ((ni->flags & FILE_ATTR_SYSTEM)
		    && !(ni->flags & FILE_ATTR_REPARSE_POINT)) {
			/* Interix special files (symlinks, fifos, devices) */
			na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
			if (na) {
				if (!(ni->flags & FILE_ATTR_HIDDEN)) {
					if (na->data_size == 0)
						st->mode = S_IFIFO | 0777;
					if (na->data_size == 1)
						st->mode = S_IFSOCK | 0777;
				}
				if ((u64)na->data_size <= sizeof(INTX_FILE_TYPES)
						+ sizeof(ntfschar) * PATH_MAX
				    && (u64)na->data_size
						> sizeof(INTX_FILE_TYPES)) {
					INTX_FILE *intx;

					intx = ntfs_malloc(na->data_size);
					if (intx && ntfs_attr_pread(na, 0,
							na->data_size, intx)
							== na->data_size) {
						if (intx->magic == INTX_SYMBOLIC_LINK) {
							char *t = NULL;
							int l = ntfs_ucstombs(
								intx->target,
								(na->data_size - offsetof(INTX_FILE, target))
									/ sizeof(ntfschar),
								&t, 0);
							if (l >= 0) {
								st->mode = S_IFLNK | 0777;
								st->size = l;
							}
							free(t);
						} else if (na->data_size == (s64)offsetof(
								INTX_FILE, device_end)) {
							if (intx->magic == INTX_BLOCK_DEVICE)
								st->mode = S_IFBLK | 0777;
							if (intx->magic == INTX_CHARACTER_DEVICE)
								st->mode = S_IFCHR | 0777;
							st->rdev = makedev(
								le64_to_cpu(intx->major),
								le64_to_cpu(intx->minor));
						}
					}
					free(intx);
				}
				ntfs_attr_close(na);
			}
		}
	}

	st->atime = ntfs2timespec(ni->last_access_time);
	st->mtime = ntfs2timespec(ni->last_data_change_time);
	st->ctime = ntfs2timespec(ni->last_mft_change_time);
	st->btime = ntfs2timespec(ni->creation_time);
	if ((ni->flags & FILE_ATTR_HIDDEN) && (ni->mft_no != FILE_root))
		st->bsd_flags |= UF_HIDDEN;
	errno = 0;
	return 0;
}

static void ni_set_archive(ntfs_inode *ni)
{
	if (!ni_is_dir(ni))
		ni->flags |= FILE_ATTR_ARCHIVE;
}

static int neg_errno(void)
{
	return errno ? -errno : -EIO;
}

/* ====================================================================== */
/* Write cache                                                            */
/* ====================================================================== */

/*
 * Record a failure in the error ledger: only the earliest
 * unreported error is kept, later ones just go to the log.
 * @nerr is a negative errno, as everywhere in the bridge.
 */
static void ledger_record(ntfsb_volume *v, int nerr)
{
	if (!v->pending_err) {
		v->pending_err = -nerr;
		ntfs_log_error("volume error ledger: remembering %s, it will "
			"be reported at the next boundary\n", strerror(-nerr));
	}
}

/*
 * Consume the ledger at a reporting boundary (ntfsb_sync /
 * ntfsb_unmount). @pre is the ledger content from BEFORE
 * this attempt ran (wcache_flush() itself records its failure when the
 * ledger was empty), @cur is this attempt's own negative errno or 0.
 * Returns the negative errno to report:
 *   ledger empty before, attempt ok    -> 0
 *   ledger empty before, failed E2     -> E2, reported and consumed
 *   ledger E1 before,    attempt ok    -> E1, ledger emptied
 *   ledger E1 before,    failed E2     -> E1, E2 kept unreported
 */
static int ledger_report(ntfsb_volume *v, int pre, int cur)
{
	if (pre) {
		v->pending_err = cur ? -cur : 0;
		return -pre;
	}
	v->pending_err = 0;
	return cur;
}

/*
 * Close the cached file: first give back the space that was
 * allocated ahead, then write the metadata out, and only after both
 * succeeded release the attribute and the inode. On failure the cache
 * is left exactly as it was - w_ni, w_na (still open) and w_size - and
 * the error is recorded in the ledger, so the next flush retries from
 * the trim and the file never exists twice in memory. Only retryable
 * failures come back here: after a failed trim the volume is
 * fail-closed and the flush returns without writing anything.
 */
static int wcache_flush_why(ntfsb_volume *v, const char *why)
{
	struct bdev *bdev;
	int ret;

	/* fail closed after a half-finished trim: nothing is
	 * written any more, the error behaves like a failing attempt at
	 * every boundary */
	if (v->fatal_err)
		return -v->fatal_err;
	if (!v->w_ni)
		return 0;
	bdev = BDEV(v->vol->dev);
	ntfs_log_info("wcache flush by %s: inode %lld size %lld prealloc %lld\n",
		why, (long long)v->w_ni->mft_no, (long long)v->w_size,
		(long long)(v->w_na ? v->w_na->data_size - v->w_size : 0));

	/* step 1: give back what was allocated ahead but never written.
	 * A failure here is NOT retryable: the truncate frees
	 * $Bitmap clusters and rewrites sizes before it updates the mapping
	 * pairs, so a retry could skip that update and leave the freed
	 * clusters cross-allocated. The volume fails closed instead. */
	if (v->w_na && v->w_na->data_size > v->w_size
	    && ntfs_attr_truncate(v->w_na, v->w_size)) {
		ret = neg_errno();
		ntfs_log_perror("Failed to trim preallocated space of "
			"inode %lld", (long long)v->w_ni->mft_no);
		if (!v->fatal_err)
			v->fatal_err = -ret;
		ledger_record(v, ret);
		return ret;
	}

	/* step 2: write the metadata out; nothing is released yet. A failed
	 * sync puts the dirty marks back (inode.c), so a retry commits
	 * again. */
	bdev->last_werr = 0;
	if (ntfs_inode_sync(v->w_ni)) {
		ret = neg_errno();
		/* ntfs_inode_sync_in_dir() maps every non-EIO write error
		 * to EBUSY. The write itself went through this bridge's
		 * device ops, which remembered the real errno; report that
		 * one, the error ledger needs to tell errors apart. */
		if (ret == -EBUSY && bdev->last_werr)
			ret = -bdev->last_werr;
		ntfs_log_perror("Failed to sync inode %lld to disk",
			(long long)v->w_ni->mft_no);
		/* the sync may already have cleared the FILE_NAME mark
		 * after a swallowed index write: re-file it, so the
		 * retry updates the directory entry as well. Writing an
		 * entry that may already be on disk is safe. */
		NInoFileNameSetDirty(v->w_ni);
		ledger_record(v, ret);
		return ret;
	}

	/* The sync reported success, but a write inside it may have failed
	 * silently: the vendored index code discards failed writes of
	 * non-resident $I30 blocks (index.c ntfs_index_ctx_put), losing the
	 * directory entry update. Any failed device write during the sync
	 * fails the sync; the file name mark was already
	 * cleared by the sync, so it is set again for the retry. */
	if (bdev->last_werr) {
		ret = -bdev->last_werr;
		ntfs_log_error("a write during the sync of inode %lld failed "
			"silently (%s); keeping the cache for a retry\n",
			(long long)v->w_ni->mft_no, strerror(-ret));
		NInoFileNameSetDirty(v->w_ni);
		ledger_record(v, ret);
		return ret;
	}

	/* step 3: the inode is clean now, so releasing it cannot fail (the
	 * inode cache branch only fails when a sync is needed). If the
	 * invariant is broken anyway, clear the pointers: the worst case
	 * is a leak, keeping them could leave a dangling inode behind. */
	if (v->w_na) {
		ntfs_attr_close(v->w_na);
		v->w_na = NULL;
	}
	ret = 0;
	if (ntfs_inode_close(v->w_ni)) {
		ret = neg_errno();
		ntfs_log_error("Failed to close synced inode %lld: leaking it, "
			"cache cleared\n", (long long)v->w_ni->mft_no);
		ledger_record(v, ret);
	}
	v->w_ni = NULL;
	return ret;
}

#define wcache_flush(v) wcache_flush_why(v, __func__)

/*
 * Abandon path, unmount only: the flush still fails, so the
 * memory lifecycle of the write cache ends without any further writes.
 * Only the inode the write cache owns is reclaimed: its dirty marks
 * (and those of its extents) are dropped, then it is really closed,
 * which frees it. The last metadata update of the file
 * is lost and the on-disk state may be partially committed; only the
 * memory is reclaimed.
 */
static void wcache_abandon(ntfsb_volume *v)
{
	ntfs_inode *ni = v->w_ni;
	int i;

	if (!ni)
		return;
	ntfs_log_error("abandoning the write cache of inode %lld at unmount: "
		"its pending metadata update is lost\n",
		(long long)ni->mft_no);
	if (v->w_na) {
		ntfs_attr_close(v->w_na);
		v->w_na = NULL;
	}
	NInoClearDirty(ni);
	NInoAttrListClearDirty(ni);
	NInoFileNameClearDirty(ni);
	for (i = 0; i < ni->nr_extents; i++) {
		NInoClearDirty(ni->extent_nis[i]);
		NInoAttrListClearDirty(ni->extent_nis[i]);
		NInoFileNameClearDirty(ni->extent_nis[i]);
	}
	/* cannot fail anymore: nothing is dirty, so nothing is written */
	ntfs_inode_real_close(ni);
	v->w_ni = NULL;
}

/* Open an inode, borrowing the cached one when it is the same file. */
static ntfs_inode *ni_open(ntfsb_volume *v, u64 ino)
{
	if (v->w_ni && v->w_ni->mft_no == ino)
		return v->w_ni;
	return ntfs_inode_open(v->vol, ino);
}

static int ni_close(ntfsb_volume *v, ntfs_inode *ni)
{
	if (ni && ni == v->w_ni)
		return 0;
	return ntfs_inode_close(ni);
}

/* ====================================================================== */
/* Volume                                                                 */
/* ====================================================================== */

/*
 * Read the volume label without mounting: it lives in a resident
 * $VOLUME_NAME attribute of MFT record 3 ($Volume). Best effort.
 */
static void probe_label(const ntfsb_device *io, const NTFS_BOOT_SECTOR *bs,
		u32 cs, ntfsb_info *info)
{
	s8 c = bs->clusters_per_mft_record;
	u32 mrs, alen;
	s64 off, aoff;
	u8 *raw = NULL;
	MFT_RECORD *m;
	ATTR_RECORD *a;
	u32 pos;

	if (!cs)
		return;
	mrs = (c > 0) ? (u32)c * cs : (1U << -c);
	if (mrs < 512 || mrs > 65536 || (mrs & (mrs - 1)))
		return;
	off = sle64_to_cpu(bs->mft_lcn) * (s64)cs + (s64)FILE_Volume * mrs;
	if (off <= 0 || (u64)off + mrs > io->size_bytes)
		return;
	aoff = off - (off % io->sector_size);
	alen = (u32)(((off + mrs + io->sector_size - 1) / io->sector_size)
			* io->sector_size - aoff);
	raw = malloc(alen);
	if (!raw)
		return;
	if (io->pread(io->ctx, raw, alen, aoff) != (int64_t)alen)
		goto out;
	m = (MFT_RECORD *)(raw + (off - aoff));
	if (ntfs_mst_post_read_fixup((NTFS_RECORD *)m, mrs)
	    || !ntfs_is_file_record(m->magic))
		goto out;
	pos = le16_to_cpu(m->attrs_offset);
	while (pos + offsetof(ATTR_RECORD, compression_unit) <= mrs) {
		u32 len;

		a = (ATTR_RECORD *)((u8 *)m + pos);
		if (a->type == AT_END)
			break;
		len = le32_to_cpu(a->length);
		if (len < 16 || pos + len > mrs)
			break;
		if (a->type == AT_VOLUME_NAME && !a->non_resident) {
			u32 vlen = le32_to_cpu(a->value_length);
			u32 voff = le16_to_cpu(a->value_offset);
			char *label = NULL;

			if (voff + vlen <= len && vlen >= 2) {
				ntfschar *tmp = malloc(vlen);

				if (tmp) {
					memcpy(tmp, (u8 *)a + voff, vlen);
					if (ntfs_ucstombs(tmp, vlen / 2, &label,
							0) >= 0 && label)
						snprintf(info->label,
							sizeof(info->label),
							"%s", label);
					free(label);
					free(tmp);
				}
			}
			break;
		}
		pos += len;
	}
out:
	free(raw);
	errno = 0;
}

int ntfsb_probe(const ntfsb_device *io, ntfsb_info *info)
{
	NTFS_BOOT_SECTOR *bs;
	size_t len;
	int64_t r;
	u32 ss;
	int ret = -EINVAL;

	if (!io || !io->pread || !io->sector_size)
		return -EINVAL;
	len = io->sector_size > 512 ? io->sector_size : 512;
	len = ((len + io->sector_size - 1) / io->sector_size) * io->sector_size;
	bs = calloc(1, len);
	if (!bs)
		return -ENOMEM;
	r = io->pread(io->ctx, bs, (int64_t)len, 0);
	if (r < 0) {
		ret = (int)r;
		goto out;
	}
	if ((size_t)r < sizeof(NTFS_BOOT_SECTOR))
		goto out;
	/* check the OEM id ourselves first: the library logs an error for
	 * every non-NTFS device, and probing those is perfectly normal */
	if (memcmp((const u8 *)bs + 3, "NTFS    ", 8)
	    || !ntfs_boot_sector_is_ntfs(bs))
		goto out;
	ss = le16_to_cpu(bs->bpb.bytes_per_sector);
	if (info) {
		u8 spc = bs->bpb.sectors_per_cluster;
		u32 cs;
		u64 sectors = sle64_to_cpu(bs->number_of_sectors);

		memset(info, 0, sizeof(*info));
		/* > 0x80 encodes the cluster size as a negative power of two */
		cs = (spc > 0x80) ? (ss << (256 - spc)) : (ss * spc);
		memcpy(info->serial, &bs->volume_serial_number, 8);
		info->sector_size = ss;
		info->cluster_size = cs;
		info->total_clusters = cs ? (sectors * ss) / cs : 0;
		probe_label(io, bs, cs, info);
	}
	ret = 0;
out:
	free(bs);
	return ret;
}

static s64 nr_free_mft_records(ntfs_volume *vol)
{
	ntfs_attr *na = vol->mftbmp_na;
	s64 nr_free = ntfs_attr_get_free_bits(na);

	if (nr_free >= 0)
		nr_free += (na->allocated_size - na->data_size) << 3;
	return nr_free;
}

ntfsb_volume *ntfsb_mount(const ntfsb_device *io, unsigned flags,
		uid_t uid, gid_t gid, int *err)
{
	struct ntfs_device *dev;
	ntfs_volume *vol;
	ntfsb_volume *v;
	unsigned long mflags = 0;
	int e = 0;

	if (!g_log_cb)
		ntfsb_set_log_callback(NULL, NTFSB_LOG_ERROR);

	v = calloc(1, sizeof(*v));
	if (!v) {
		e = ENOMEM;
		goto fail;
	}
	dev = ntfsb_device_alloc(io);
	if (!dev) {
		e = errno;
		goto fail;
	}
	if ((flags & NTFSB_MOUNT_RDONLY) || io->read_only || !io->pwrite)
		mflags |= NTFS_MNT_RDONLY;
	else
		mflags |= NTFS_MNT_MAY_RDONLY;
	if (!(flags & NTFSB_MOUNT_NO_RECOVER))
		mflags |= NTFS_MNT_RECOVER;

	errno = 0;
	vol = ntfs_device_mount(dev, mflags);
	if (!vol) {
		e = errno ? errno : EIO;
		/* ntfs_device_mount() closed the device but did not free it */
		bdev_free(dev);
		goto fail;
	}
	ntfs_create_lru_caches(vol);
	{
		ntfsb_info bi;

		if (!ntfsb_probe(io, &bi))
			memcpy(v->serial, bi.serial, 8);
	}
	v->vol = vol;
	v->uid = uid;
	v->gid = gid;

	if (flags & NTFSB_MOUNT_RDONLY)
		v->ro_reason = NTFSB_RO_REQUESTED;
	else if (io->read_only || !io->pwrite)
		v->ro_reason = NTFSB_RO_DEVICE;
	else if (NVolReadOnly(vol)) {
		/* libntfs-3g fell back to read-only: find out why */
		errno = 0;
		if (ntfs_volume_check_hiberfile(vol, 0) < 0)
			v->ro_reason = NTFSB_RO_HIBERNATED;
		else
			v->ro_reason = NTFSB_RO_UNCLEAN;
	}

	NVolSetCompression(vol);
	vol->special_files = NTFS_FILES_WSL;
	vol->secure_flags = 0;
	vol->abs_mnt_point = strdup("/");
	if (ntfs_set_shown_files(vol, (flags & NTFSB_MOUNT_SHOW_SYSTEM) != 0,
			TRUE, FALSE)) {
		e = errno ? errno : EIO;
		goto fail_umount;
	}
	if (!(flags & NTFSB_MOUNT_CASE_SENSITIVE) && ntfs_set_ignore_case(vol)) {
		e = errno ? errno : EIO;
		goto fail_umount;
	}
	if (ntfs_volume_get_free_space(vol)) {
		e = errno ? errno : EIO;
		goto fail_umount;
	}
	vol->free_mft_records = nr_free_mft_records(vol);
	if (vol->free_mft_records < 0) {
		e = errno ? errno : EIO;
		goto fail_umount;
	}
	if (err)
		*err = 0;
	return v;

fail_umount:
	ntfsb_unmount(v);
	v = NULL;
fail:
	free(v);
	if (err)
		*err = -e;
	return NULL;
}

int ntfsb_unmount(ntfsb_volume *v)
{
	struct ntfs_device *dev;
	void *priv;
	char *mnt;
	int ret = 0, fl;

	if (!v)
		return 0;
	if (v->vol) {
		/* one normal flush; if it still fails, take the abandon path
		 * so that w_ni / w_na are NULL before ntfs_umount() and no
		 * memory is leaked */
		fl = wcache_flush(v);
		if (fl)
			wcache_abandon(v);
		if (v->fatal_err) {
			/* The volume is not trustworthy any more;
			 * leave it dirty so Windows runs chkdsk on it. Best
			 * effort - a failure here only goes to the log. */
			if (ntfs_volume_write_flags(v->vol,
					v->vol->flags | VOLUME_IS_DIRTY))
				ntfs_log_error("could not mark the volume "
					"dirty: run chkdsk on Windows "
					"before using it\n");
		}
		/* return value priority: the stored error first, then
		 * this flush's or the abandon path's error, then the error
		 * of ntfs_umount() itself. Unmount is terminal, the ledger
		 * dies with the volume. */
		if (v->pending_err)
			ret = -v->pending_err;
		else if (fl)
			ret = fl;
		dev = v->vol->dev;
		priv = dev ? dev->d_private : NULL;
		mnt = (char *)v->vol->abs_mnt_point;
		v->vol->abs_mnt_point = NULL;
		/* ntfs_umount() syncs, closes and frees the device */
		if (ntfs_umount(v->vol, FALSE) && !ret)
			ret = neg_errno();
		free(priv);
		free(mnt);
	}
	free(v);
	return ret;
}

int ntfsb_sync(ntfsb_volume *v)
{
	int pre, cur;

	if (NVolReadOnly(v->vol))
		return 0;
	pre = v->pending_err;
	cur = wcache_flush(v);
	if (ntfs_device_sync(v->vol->dev) && !cur)
		cur = neg_errno();
	/* reporting boundary: a stored error outranks this
	 * attempt's own result; whatever is not reported stays in the
	 * ledger */
	return ledger_report(v, pre, cur);
}

int ntfsb_get_info(ntfsb_volume *v, ntfsb_info *info)
{
	ntfs_volume *vol = v->vol;
	s64 mft_total;

	memset(info, 0, sizeof(*info));
	if (vol->vol_name)
		snprintf(info->label, sizeof(info->label), "%s", vol->vol_name);
	memcpy(info->serial, v->serial, 8);
	info->cluster_size = vol->cluster_size;
	info->sector_size = vol->sector_size;
	info->total_clusters = vol->nr_clusters;
	info->free_clusters = vol->free_clusters > 0 ? vol->free_clusters : 0;
	mft_total = vol->mftbmp_na ? (vol->mftbmp_na->allocated_size << 3) : 0;
	info->free_files = vol->free_mft_records > 0 ? vol->free_mft_records : 0;
	info->total_files = mft_total > 0 ? mft_total : 0;
	info->read_only = NVolReadOnly(vol) ? 1 : 0;
	info->ro_reason = v->ro_reason;
	info->major_ver = vol->major_ver;
	info->minor_ver = vol->minor_ver;
	return 0;
}

int ntfsb_set_label(ntfsb_volume *v, const char *label)
{
	ntfschar *u = NULL;
	int len, ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	len = ntfs_mbstoucs(label ? label : "", &u);
	if (len < 0)
		return neg_errno();
	if (len > 32) {  /* NTFS volume labels hold at most 32 UTF-16 units */
		free(u);
		return -ENAMETOOLONG;
	}
	if (ntfs_volume_rename(v->vol, u, len))
		ret = neg_errno();
	free(u);
	return ret;
}

/* ====================================================================== */
/* Namespace                                                              */
/* ====================================================================== */

int ntfsb_getattr(ntfsb_volume *v, uint64_t ino, ntfsb_stat *st)
{
	ntfs_inode *ni;
	int ret;

	ni = ni_open(v, ino);
	if (!ni)
		return neg_errno();
	ret = ni_stat(v, ni, st);
	if (ni_close(v, ni) && !ret)
		ret = neg_errno();
	return ret;
}

/* Find the on-disk spelling of the link to @ni that lives in @dir_ino. */
static char *ni_actual_name(ntfs_inode *ni, u64 dir_ino,
		const ntfschar *uname, int ulen)
{
	ntfs_attr_search_ctx *ctx;
	ntfs_volume *vol = ni->vol;
	char *out = NULL;

	ctx = ntfs_attr_get_search_ctx(ni, NULL);
	if (!ctx)
		return NULL;
	while (!out && !ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0,
			CASE_SENSITIVE, 0, NULL, 0, ctx)) {
		FILE_NAME_ATTR *fn = (FILE_NAME_ATTR *)((u8 *)ctx->attr
			+ le16_to_cpu(ctx->attr->value_offset));
		ntfschar tmp[NTFS_MAX_NAME_LEN + 1];

		if (fn->file_name_type == FILE_NAME_DOS)
			continue;
		if (MREF_LE(fn->parent_directory) != dir_ino)
			continue;
		memcpy(tmp, fn->file_name,
			fn->file_name_length * sizeof(ntfschar));
		if (ntfs_names_are_equal(tmp, fn->file_name_length, uname, ulen,
				IGNORE_CASE, vol->upcase, vol->upcase_len))
			out = name_from_disk(tmp, fn->file_name_length);
	}
	ntfs_attr_put_search_ctx(ctx);
	errno = 0;
	return out;
}

int ntfsb_lookup(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		ntfsb_stat *st, char **actual_name)
{
	ntfs_inode *dir_ni, *ni;
	ntfschar *uname = NULL;
	int ulen = 0, ret = 0;
	u64 ref;


	if (actual_name)
		*actual_name = NULL;
	dir_ni = ntfs_inode_open(v->vol, dir_ino);
	if (!dir_ni)
		return neg_errno();
	ref = dir_lookup(dir_ni, name, &uname, &ulen);
	if (ref == (u64)-1)
		ret = neg_errno();
	if (ntfs_inode_close(dir_ni) && !ret)
		ret = neg_errno();
	if (ret)
		goto out;
	if (ino_is_hidden_system(v, MREF(ref))
	    && !NVolShowSysFiles(v->vol)) {
		ret = -ENOENT;
		goto out;
	}
	ni = ni_open(v, MREF(ref));
	if (!ni) {
		ret = neg_errno();
		goto out;
	}
	ret = ni_stat(v, ni, st);
	if (!ret && actual_name)
		*actual_name = ni_actual_name(ni, dir_ino, uname, ulen);
	if (ni_close(v, ni) && !ret)
		ret = neg_errno();
out:
	free(uname);
	return ret;
}

struct readdir_ctx {
	ntfsb_volume *v;
	ntfsb_dirent_cb cb;
	void *ctx;
	int stopped;
};

static int readdir_filler(void *dirent, const ntfschar *name,
		const int name_len, const int name_type, const s64 pos,
		const MFT_REF mref, const unsigned dt_type)
{
	struct readdir_ctx *rc = dirent;
	char *mbs;
	int dtype, r;

	(void)pos;
	if (name_type == FILE_NAME_DOS)
		return 0;
	/* "." and ".." are synthesised by the caller */
	if (name_len == 1 && name[0] == const_cpu_to_le16('.'))
		return 0;
	if (name_len == 2 && name[0] == const_cpu_to_le16('.')
	    && name[1] == const_cpu_to_le16('.'))
		return 0;
	if (MREF(mref) < FILE_first_user && !NVolShowSysFiles(rc->v->vol))
		return 0;
	if (MREF(mref) <= 1)
		return 0;

	switch (dt_type) {
	case NTFS_DT_DIR:  dtype = NTFSB_DT_DIR; break;
	case NTFS_DT_LNK:  dtype = NTFSB_DT_LNK; break;
	case NTFS_DT_FIFO: dtype = NTFSB_DT_FIFO; break;
	case NTFS_DT_SOCK: dtype = NTFSB_DT_SOCK; break;
	case NTFS_DT_BLK:  dtype = NTFSB_DT_BLK; break;
	case NTFS_DT_CHR:  dtype = NTFSB_DT_CHR; break;
	case NTFS_DT_REG:  dtype = NTFSB_DT_REG; break;
	default:           dtype = NTFSB_DT_UNKNOWN; break;
	}
	mbs = name_from_disk(name, name_len);
	if (!mbs) {
		/* undecodable name: skip it rather than fail the listing */
		errno = 0;
		return 0;
	}
	r = rc->cb(rc->ctx, mbs, strlen(mbs), MREF(mref), dtype);
	free(mbs);
	if (r) {
		rc->stopped = 1;
		return -1;
	}
	return 0;
}

int ntfsb_readdir(ntfsb_volume *v, uint64_t dir_ino, ntfsb_dirent_cb cb,
		void *ctx)
{
	struct readdir_ctx rc = { v, cb, ctx, 0 };
	ntfs_inode *ni;
	s64 pos = 0;
	int ret = 0, insensitive;


	ni = ntfs_inode_open(v->vol, dir_ino);
	if (!ni)
		return neg_errno();
	if (!ni_is_dir(ni)) {
		ni_close(v, ni);
		return -ENOTDIR;
	}
	/*
	 * In ignore-case mode ntfs_readdir() lower-cases every name it
	 * reports. We are case preserving, so enumerate in case sensitive
	 * mode (the flag only affects how names are reported here).
	 */
	insensitive = !NVolCaseSensitive(v->vol);
	if (insensitive)
		NVolSetCaseSensitive(v->vol);
	errno = 0;
	if (ntfs_readdir(ni, &pos, &rc, readdir_filler) && !rc.stopped)
		ret = neg_errno();
	if (insensitive)
		NVolClearCaseSensitive(v->vol);
	if (ni_close(v, ni) && !ret)
		ret = neg_errno();
	return ret;
}

static int do_create(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		mode_t type, const char *target, ntfsb_stat *st)
{
	ntfs_inode *dir_ni = NULL, *ni;
	ntfschar *uname = NULL, *utarget = NULL;
	int ulen, tlen, ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (dir_ino == FILE_Extend)
		return -EPERM;
	ulen = name_to_disk(name, &uname, 1);
	if (ulen < 0)
		return neg_errno();
	dir_ni = ntfs_inode_open(v->vol, dir_ino);
	if (!dir_ni) {
		ret = neg_errno();
		goto out;
	}
	if (dir_ni->flags & FILE_ATTR_REPARSE_POINT) {
		ret = -EOPNOTSUPP;
		goto out;
	}
	if (S_ISLNK(type)) {
		tlen = ntfs_mbstoucs(target, &utarget);
		if (tlen < 0) {
			ret = neg_errno();
			goto out;
		}
		ni = ntfs_create_symlink(dir_ni, const_cpu_to_le32(0), uname,
				ulen, utarget, tlen);
	} else {
		ni = ntfs_create(dir_ni, const_cpu_to_le32(0), uname, ulen,
				type);
	}
	if (!ni) {
		ret = neg_errno();
		goto out;
	}
	ni_set_archive(ni);
	NInoSetDirty(ni);
	if (st)
		ret = ni_stat(v, ni, st);
	/* closing ni needs dir_ni to update the index: avoid a double open */
	if (ntfs_inode_close_in_dir(ni, dir_ni) && !ret)
		ret = neg_errno();
	ntfs_inode_update_times(dir_ni, NTFS_UPDATE_MCTIME);
out:
	free(uname);
	free(utarget);
	if (ntfs_inode_close(dir_ni) && !ret)
		ret = neg_errno();
	return ret;
}

int ntfsb_create(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		mode_t type, ntfsb_stat *st)
{
	type &= S_IFMT;
	if (type != S_IFREG && type != S_IFDIR)
		return -EOPNOTSUPP;
	return do_create(v, dir_ino, name, type, NULL, st);
}

int ntfsb_symlink(ntfsb_volume *v, uint64_t dir_ino, const char *name,
		const char *target, ntfsb_stat *st)
{
	if (!target)
		return -EINVAL;
	return do_create(v, dir_ino, name, S_IFLNK, target, st);
}

int ntfsb_readlink(ntfsb_volume *v, uint64_t ino, char **target)
{
	ntfs_inode *ni;
	ntfs_attr *na = NULL;
	INTX_FILE *intx = NULL;
	char *buf = NULL;
	int ret = 0;


	*target = NULL;
	ni = ni_open(v, ino);
	if (!ni)
		return neg_errno();
	if (ni->flags & FILE_ATTR_REPARSE_POINT) {
		errno = 0;
		buf = ntfs_make_symlink(ni, v->vol->abs_mnt_point);
		if (!buf)
			ret = errno ? -errno : -EINVAL;
		goto out;
	}
	if (!(ni->flags & FILE_ATTR_SYSTEM)) {
		ret = -EINVAL;
		goto out;
	}
	na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
	if (!na) {
		ret = neg_errno();
		goto out;
	}
	if ((size_t)na->data_size <= sizeof(INTX_FILE_TYPES)) {
		ret = -EINVAL;
		goto out;
	}
	if ((size_t)na->data_size > sizeof(INTX_FILE_TYPES)
			+ sizeof(ntfschar) * PATH_MAX) {
		ret = -ENAMETOOLONG;
		goto out;
	}
	intx = ntfs_malloc(na->data_size);
	if (!intx) {
		ret = neg_errno();
		goto out;
	}
	if (ntfs_attr_pread(na, 0, na->data_size, intx) != na->data_size) {
		ret = neg_errno();
		goto out;
	}
	if (intx->magic != INTX_SYMBOLIC_LINK) {
		ret = -EINVAL;
		goto out;
	}
	if (ntfs_ucstombs(intx->target, (na->data_size
			- offsetof(INTX_FILE, target)) / sizeof(ntfschar),
			&buf, 0) < 0) {
		ret = neg_errno();
		buf = NULL;
	}
out:
	free(intx);
	if (na)
		ntfs_attr_close(na);
	if (ni_close(v, ni) && !ret)
		ret = neg_errno();
	if (ret) {
		free(buf);
		buf = NULL;
	}
	*target = buf;
	return ret;
}

/* Add the name @uname in @dir_ino to inode @ino. */
static int do_link(ntfsb_volume *v, u64 ino, u64 dir_ino,
		const ntfschar *uname, int ulen, int allow_dir)
{
	ntfs_inode *ni, *dir_ni = NULL;
	int ret = 0;

	ni = ntfs_inode_open(v->vol, ino);
	if (!ni)
		return neg_errno();
	if (!allow_dir && ni_is_dir(ni)) {
		ret = -EPERM;
		goto out;
	}
	dir_ni = ntfs_inode_open(v->vol, dir_ino);
	if (!dir_ni) {
		ret = neg_errno();
		goto out;
	}
	if (dir_ni->flags & FILE_ATTR_REPARSE_POINT) {
		ret = -EOPNOTSUPP;
		goto out;
	}
	if (ntfs_link(ni, dir_ni, uname, ulen)) {
		ret = neg_errno();
		goto out;
	}
	ni_set_archive(ni);
	ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	ntfs_inode_update_times(dir_ni, NTFS_UPDATE_MCTIME);
out:
	/* dir_ni first: syncing ni's file names needs the index on disk */
	if (ntfs_inode_close(dir_ni) && !ret)
		ret = neg_errno();
	if (ntfs_inode_close(ni) && !ret)
		ret = neg_errno();
	return ret;
}

/* Remove the exact on-disk name @uname of inode @ino from @dir_ino. */
static int do_unlink(ntfsb_volume *v, u64 dir_ino, u64 ino,
		const ntfschar *uname, int ulen)
{
	ntfs_inode *dir_ni, *ni;

	if (dir_ino == FILE_Extend || ino < FILE_first_user)
		return -EPERM;
	dir_ni = ntfs_inode_open(v->vol, dir_ino);
	if (!dir_ni)
		return neg_errno();
	if (dir_ni->flags & FILE_ATTR_REPARSE_POINT) {
		ntfs_inode_close(dir_ni);
		return -EOPNOTSUPP;
	}
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni) {
		int ret = neg_errno();

		ntfs_inode_close(dir_ni);
		return ret;
	}
	/* ntfs_delete() always closes both inodes */
	if (ntfs_delete(v->vol, NULL, ni, dir_ni, uname, ulen))
		return neg_errno();
	return 0;
}

/*
 * Replace *uname (the spelling used for the lookup) by the spelling that
 * is really stored in the link from @dir_ino to @ni. ntfs_delete() matches
 * POSIX namespace names exactly, so removals need the real thing.
 */
static void ni_exact_name(ntfs_inode *ni, u64 dir_ino, ntfschar **uname,
		int *ulen)
{
	ntfs_attr_search_ctx *ctx;
	ntfs_volume *vol = ni->vol;
	int found = 0;

	ctx = ntfs_attr_get_search_ctx(ni, NULL);
	if (!ctx)
		return;
	while (!found && !ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0,
			CASE_SENSITIVE, 0, NULL, 0, ctx)) {
		FILE_NAME_ATTR *fn = (FILE_NAME_ATTR *)((u8 *)ctx->attr
			+ le16_to_cpu(ctx->attr->value_offset));
		ntfschar tmp[NTFS_MAX_NAME_LEN + 1];

		if (fn->file_name_type == FILE_NAME_DOS)
			continue;
		if (MREF_LE(fn->parent_directory) != dir_ino)
			continue;
		memcpy(tmp, fn->file_name,
			fn->file_name_length * sizeof(ntfschar));
		if (!ntfs_names_are_equal(tmp, fn->file_name_length, *uname,
				*ulen, IGNORE_CASE, vol->upcase,
				vol->upcase_len))
			continue;
		if (fn->file_name_length <= *ulen
		    || (*uname = realloc(*uname, sizeof(ntfschar)
				* (fn->file_name_length + 1)))) {
			memcpy(*uname, tmp,
				fn->file_name_length * sizeof(ntfschar));
			*ulen = fn->file_name_length;
		}
		found = 1;
	}
	ntfs_attr_put_search_ctx(ctx);
	errno = 0;
}

/* Resolve @name in @dir_ino to (inode, exact on-disk spelling). */
static int resolve(ntfsb_volume *v, u64 dir_ino, const char *name, u64 *ino,
		ntfschar **uname, int *ulen)
{
	ntfs_inode *dir_ni, *ni;
	u64 ref;
	int ret = 0;

	*uname = NULL;
	dir_ni = ntfs_inode_open(v->vol, dir_ino);
	if (!dir_ni)
		return neg_errno();
	ref = dir_lookup(dir_ni, name, uname, ulen);
	if (ref == (u64)-1)
		ret = neg_errno();
	else
		*ino = MREF(ref);
	if (ntfs_inode_close(dir_ni) && !ret)
		ret = neg_errno();
	if (ret || NVolCaseSensitive(v->vol))
		return ret;
	ni = ntfs_inode_open(v->vol, *ino);
	if (!ni)
		return neg_errno();
	ni_exact_name(ni, dir_ino, uname, ulen);
	if (ntfs_inode_close(ni))
		ret = neg_errno();
	return ret;
}

int ntfsb_link(ntfsb_volume *v, uint64_t ino, uint64_t dir_ino,
		const char *name)
{
	ntfschar *uname = NULL;
	int ulen, ret;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	ulen = name_to_disk(name, &uname, 1);
	if (ulen < 0)
		return neg_errno();
	ret = do_link(v, ino, dir_ino, uname, ulen, 0);
	free(uname);
	return ret;
}

int ntfsb_remove(ntfsb_volume *v, uint64_t dir_ino, const char *name)
{
	ntfschar *uname = NULL;
	int ulen = 0, ret;
	u64 ino = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	ret = resolve(v, dir_ino, name, &ino, &uname, &ulen);
	if (!ret)
		ret = do_unlink(v, dir_ino, ino, uname, ulen);
	free(uname);
	return ret;
}

/* Build a unique temporary name in on-disk form. */
static int tmp_name(ntfsb_volume *v, ntfschar **out)
{
	char buf[64];

	snprintf(buf, sizeof(buf), ".ntfs-rename-%08x-%06u",
		(unsigned)getpid(), ++v->rename_seq);
	return name_to_disk(buf, out, 0);
}

int ntfsb_rename(ntfsb_volume *v, uint64_t src_dir, const char *src_name,
		uint64_t dst_dir, const char *dst_name)
{
	ntfschar *usrc = NULL, *udst_found = NULL, *udst = NULL, *utmp = NULL;
	int slen = 0, dflen = 0, dlen, tlen, ret;
	u64 ino = 0, xino = 0;
	int have_dst;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	ret = resolve(v, src_dir, src_name, &ino, &usrc, &slen);
	if (ret)
		goto out;
	if (ino < FILE_first_user) {
		ret = -EPERM;
		goto out;
	}
	/* The new name is always written in mapped (Windows friendly) form */
	dlen = name_to_disk(dst_name, &udst, 1);
	if (dlen < 0) {
		ret = neg_errno();
		goto out;
	}
	ret = resolve(v, dst_dir, dst_name, &xino, &udst_found, &dflen);
	if (ret && ret != -ENOENT)
		goto out;
	have_dst = !ret;
	ret = 0;

	if (have_dst && xino == ino) {
		/*
		 * Source and destination are the same file. Either nothing
		 * changes, or only the case of the name does. The index
		 * cannot hold two spellings reliably while one of them is
		 * in the Win32 namespace, so go through a temporary name.
		 */
		if (src_dir == dst_dir && slen == dlen
		    && !memcmp(usrc, udst, slen * sizeof(ntfschar)))
			goto out;
		if (src_dir != dst_dir || slen != dflen
		    || memcmp(usrc, udst_found, slen * sizeof(ntfschar))
		    || !ntfs_names_are_equal(usrc, slen, udst, dlen,
				IGNORE_CASE, v->vol->upcase,
				v->vol->upcase_len)) {
			/* two different hard links to one file: POSIX says
			 * rename() does nothing */
			goto out;
		}
		tlen = tmp_name(v, &utmp);
		if (tlen < 0) {
			ret = neg_errno();
			goto out;
		}
		ret = do_link(v, ino, src_dir, utmp, tlen, 1);
		if (ret)
			goto out;
		ret = do_unlink(v, src_dir, ino, usrc, slen);
		if (ret) {
			do_unlink(v, src_dir, ino, utmp, tlen);
			goto out;
		}
		ret = do_link(v, ino, dst_dir, udst, dlen, 1);
		if (ret) {
			/* put the old spelling back */
			if (!do_link(v, ino, src_dir, usrc, slen, 1))
				do_unlink(v, src_dir, ino, utmp, tlen);
			goto out;
		}
		ret = do_unlink(v, src_dir, ino, utmp, tlen);
		goto out;
	}

	if (have_dst) {
		ntfs_inode *xni;

		if (xino < FILE_first_user) {
			ret = -EPERM;
			goto out;
		}
		/* an existing directory can only be replaced when empty */
		xni = ntfs_inode_open(v->vol, xino);
		if (!xni) {
			ret = neg_errno();
			goto out;
		}
		if (ntfs_check_empty_dir(xni) < 0)
			ret = neg_errno();
		if (ntfs_inode_close(xni) && !ret)
			ret = neg_errno();
		if (ret)
			goto out;

		/*
		 * Keep the victim reachable under a temporary name until the
		 * new link is in place, so a failure never loses a file.
		 */
		tlen = tmp_name(v, &utmp);
		if (tlen < 0) {
			ret = neg_errno();
			goto out;
		}
		ret = do_link(v, xino, dst_dir, utmp, tlen, 1);
		if (ret)
			goto out;
		ret = do_unlink(v, dst_dir, xino, udst_found, dflen);
		if (ret) {
			do_unlink(v, dst_dir, xino, utmp, tlen);
			goto out;
		}
		ret = do_link(v, ino, dst_dir, udst, dlen, 1);
		if (!ret) {
			ret = do_unlink(v, src_dir, ino, usrc, slen);
			if (ret)
				do_unlink(v, dst_dir, ino, udst, dlen);
		}
		if (ret) {
			/* restore the victim under its original name */
			if (!do_link(v, xino, dst_dir, udst_found, dflen, 1))
				do_unlink(v, dst_dir, xino, utmp, tlen);
			else
				ntfs_log_error("rename failed, the replaced "
					"file was kept under a temporary "
					"name\n");
			goto out;
		}
		/* finally drop the replaced file */
		if (do_unlink(v, dst_dir, xino, utmp, tlen))
			ntfs_log_error("rename: could not remove the "
				"replaced file's temporary name\n");
		goto out;
	}

	/* Plain rename: add the new name, then drop the old one. */
	ret = do_link(v, ino, dst_dir, udst, dlen, 1);
	if (ret)
		goto out;
	ret = do_unlink(v, src_dir, ino, usrc, slen);
	if (ret)
		do_unlink(v, dst_dir, ino, udst, dlen);
out:
	free(usrc);
	free(udst);
	free(udst_found);
	free(utmp);
	return ret;
}

/* ====================================================================== */
/* File data                                                              */
/* ====================================================================== */

/* Unsupported reparse data (deduplicated, cloud placeholders, WOF ...)
 * must not be read as if it were the file content. */
static int ni_data_unreadable(ntfs_inode *ni)
{
	return (ni->flags & FILE_ATTR_REPARSE_POINT) != 0;
}

int64_t ntfsb_read(ntfsb_volume *v, uint64_t ino, void *buf, size_t size,
		int64_t offset)
{
	ntfs_inode *ni;
	ntfs_attr *na = NULL;
	s64 total = 0, limit;
	int64_t ret;

	if (!size)
		return 0;
	if (offset < 0)
		return -EINVAL;
	ni = ni_open(v, ino);
	if (!ni)
		return neg_errno();
	if (ni_is_dir(ni)) {
		ret = -EISDIR;
		goto out;
	}
	if (ni_data_unreadable(ni)) {
		ret = -EOPNOTSUPP;
		goto out;
	}
	na = (ni == v->w_ni) ? v->w_na
			     : ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
	if (!na) {
		ret = neg_errno();
		goto out;
	}
	limit = (na == v->w_na) ? v->w_size : na->data_size;
	if (offset >= limit) {
		ret = 0;
		goto out;
	}
	if (offset + (s64)size > limit)
		size = limit - offset;
	while (size > 0) {
		s64 r = ntfs_attr_pread(na, offset, size, (char *)buf + total);

		if (r <= 0 || r > (s64)size) {
			ret = (r < 0) ? neg_errno() : -EIO;
			goto out;
		}
		size -= r;
		offset += r;
		total += r;
	}
	ret = total;
out:
	if (na && na != v->w_na)
		ntfs_attr_close(na);
	if (ni_close(v, ni) && ret >= 0)
		ret = neg_errno();
	return ret;
}

int64_t ntfsb_write(ntfsb_volume *v, uint64_t ino, const void *buf,
		size_t size, int64_t offset)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	s64 total = 0;
	int64_t ret;

	if (v->fatal_err)
		return -v->fatal_err;
	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (offset < 0)
		return -EINVAL;
	if (ino < FILE_first_user)
		return -EPERM;

	/* keep the file being written open across calls (write cache) */
	if (v->w_ni && v->w_ni->mft_no != ino) {
		int r = wcache_flush(v);

		if (r)
			return r;
	}
	if (!v->w_ni) {
		ni = ntfs_inode_open(v->vol, ino);
		if (!ni)
			return neg_errno();
		if (ni_is_dir(ni) || ni_data_unreadable(ni)) {
			ret = ni_is_dir(ni) ? -EISDIR : -EOPNOTSUPP;
			ntfs_inode_close(ni);
			return ret;
		}
		na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
		if (!na) {
			ret = neg_errno();
			ntfs_inode_close(ni);
			return ret;
		}
		v->w_ni = ni;
		v->w_na = na;
		v->w_size = na->data_size;
	}
	ni = v->w_ni;
	na = v->w_na;

	/* growing a plain non-resident file: allocate ahead */
	if (offset + (s64)size > na->data_size && NAttrNonResident(na)
	    && !(na->data_flags & (ATTR_COMPRESSION_MASK | ATTR_IS_ENCRYPTED
				| ATTR_IS_SPARSE))) {
		s64 ahead = v->w_size, want;
		s64 cs = v->vol->cluster_size;
		s64 free_bytes = v->vol->free_clusters * cs;

		if (ahead < PREALLOC_MIN)
			ahead = PREALLOC_MIN;
		if (ahead > PREALLOC_MAX)
			ahead = PREALLOC_MAX;
		want = offset + (s64)size + ahead;
		want = (want + cs - 1) & ~(cs - 1);
		/* only when there is comfortably enough room for it */
		if (free_bytes > 4 * (want - na->data_size)
		    && ntfs_attr_truncate_solid(na, want))
			errno = 0;	/* no luck: plain allocation below */
	}

	while (size) {
		s64 r = ntfs_attr_pwrite(na, offset, size,
				(const char *)buf + total);

		if (r <= 0) {
			ret = total ? total : neg_errno();
			goto out;
		}
		size -= r;
		offset += r;
		total += r;
	}
	ret = total;
out:
	if (offset > v->w_size)
		v->w_size = offset;
	if (ret > 0) {
		ni_set_archive(ni);
		ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
	} else if (ret < 0) {
		/* do not keep a file open that just failed */
		wcache_flush(v);
	}
	return ret;
}

int ntfsb_truncate(ntfsb_volume *v, uint64_t ino, uint64_t size)
{
	ntfs_inode *ni;
	ntfs_attr *na = NULL;
	s64 oldsize;
	int ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (ino < FILE_first_user)
		return -EPERM;
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni)
		return neg_errno();
	if (ni_is_dir(ni)) {
		ret = -EISDIR;
		goto out;
	}
	if (ni_data_unreadable(ni)) {
		ret = -EOPNOTSUPP;
		goto out;
	}
	na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
	if (!na) {
		ret = neg_errno();
		goto out;
	}
	oldsize = na->data_size;
	if ((na->data_flags & ATTR_COMPRESSION_MASK)
	    && ((s64)size > na->initialized_size)) {
		/* growing a compressed file: append a zero, which the
		 * library turns into a hole when it can */
		char zero = 0;

		if (ntfs_attr_pwrite(na, size - 1, 1, &zero) <= 0)
			ret = neg_errno();
	} else if (ntfs_attr_truncate(na, size)) {
		ret = neg_errno();
	}
	if (!ret && oldsize != (s64)size) {
		ni_set_archive(ni);
		ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
	}
out:
	if (na)
		ntfs_attr_close(na);
	if (ntfs_inode_close(ni) && !ret)
		ret = neg_errno();
	return ret;
}

int ntfsb_release(ntfsb_volume *v, uint64_t ino)
{
	ntfs_inode *ni;
	ntfs_attr *na;
	int ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return 0;
	errno = 0;
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni) {
		/* the open failure (e.g. the record cannot be read) is
		 * part of the release and belongs in the ledger, so the
		 * next boundary reports it */
		ret = neg_errno();
		ledger_record(v, ret);
		return ret;
	}
	if (!ni_is_dir(ni) && (ni->flags & FILE_ATTR_COMPRESSED)
	    && !(ni->flags & FILE_ATTR_REPARSE_POINT)) {
		na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
		if (!na) {
			/* a compressed file whose data attribute cannot be
			 * opened is not released either */
			ret = neg_errno();
			ledger_record(v, ret);
		} else {
			if (ntfs_attr_pclose(na)) {
				ret = neg_errno();
				/* the C ledger is the single bookkeeping
				 * source for flush/release errors */
				ledger_record(v, ret);
			}
			ntfs_attr_close(na);
		}
	}
	if (ntfs_inode_close(ni) && !ret) {
		ret = neg_errno();
		ledger_record(v, ret);
	}
	return ret;
}

int ntfsb_set_times(ntfsb_volume *v, uint64_t ino,
		const struct timespec *atime, const struct timespec *mtime,
		const struct timespec *ctime, const struct timespec *btime)
{
	ntfs_inode *ni;
	int ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	(void)ts_zero;
	if (NVolReadOnly(v->vol))
		return -EROFS;
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni)
		return neg_errno();
	if (atime)
		ni->last_access_time = timespec2ntfs(*atime);
	if (mtime)
		ni->last_data_change_time = timespec2ntfs(*mtime);
	if (btime)
		ni->creation_time = timespec2ntfs(*btime);
	if (ctime)
		ni->last_mft_change_time = timespec2ntfs(*ctime);
	else
		ni->last_mft_change_time = ntfs_current_time();
	NInoFileNameSetDirty(ni);
	ntfs_inode_mark_dirty(ni);
	if (ntfs_inode_close(ni))
		ret = neg_errno();
	return ret;
}

int ntfsb_set_bsd_flags(ntfsb_volume *v, uint64_t ino, uint32_t flags)
{
	ntfs_inode *ni;
	le32 old;
	int ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	if (ino == FILE_root)
		return 0;
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni)
		return neg_errno();
	old = ni->flags;
	if (flags & UF_HIDDEN)
		ni->flags |= FILE_ATTR_HIDDEN;
	else
		ni->flags &= ~FILE_ATTR_HIDDEN;
	if (ni->flags != old) {
		ni->last_mft_change_time = ntfs_current_time();
		NInoFileNameSetDirty(ni);
		ntfs_inode_mark_dirty(ni);
	}
	if (ntfs_inode_close(ni))
		ret = neg_errno();
	return ret;
}

/* ====================================================================== */
/* Kernel offloaded I/O                                                   */
/* ====================================================================== */

int ntfsb_map_extents(ntfsb_volume *v, uint64_t ino, int64_t offset,
		int64_t length, int allocate, ntfsb_extent *out, int max)
{
	(void)v; (void)ino; (void)offset; (void)length; (void)allocate;
	(void)out; (void)max;
	return -ENOTSUP;
}

int ntfsb_commit_size(ntfsb_volume *v, uint64_t ino, uint64_t new_size)
{
	(void)v; (void)ino; (void)new_size;
	return -ENOTSUP;
}

/* ====================================================================== */
/* Extended attributes, stored as named data streams                      */
/* ====================================================================== */

int ntfsb_listxattr(ntfsb_volume *v, uint64_t ino, ntfsb_xattr_cb cb,
		void *cbctx)
{
	ntfs_inode *ni;
	ntfs_attr_search_ctx *ctx;
	int ret = 0;


	ni = ni_open(v, ino);
	if (!ni)
		return neg_errno();
	ctx = ntfs_attr_get_search_ctx(ni, NULL);
	if (!ctx) {
		ret = neg_errno();
		goto out;
	}
	while (!ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0,
			ctx)) {
		ATTR_RECORD *a = ctx->attr;
		char *name = NULL;
		u64 size;

		if (!a->name_length)
			continue;
		/* a non-resident attribute may span several extents: only
		 * the first one carries the sizes */
		if (a->non_resident && sle64_to_cpu(a->lowest_vcn))
			continue;
		name = name_from_disk((ntfschar *)((u8 *)a
				+ le16_to_cpu(a->name_offset)), a->name_length);
		if (!name) {
			errno = 0;
			continue;
		}
		size = a->non_resident ? (u64)sle64_to_cpu(a->data_size)
				       : le32_to_cpu(a->value_length);
		if (cb(cbctx, name, size)) {
			free(name);
			break;
		}
		free(name);
	}
	ntfs_attr_put_search_ctx(ctx);
	errno = 0;
out:
	if (ni_close(v, ni) && !ret)
		ret = neg_errno();
	return ret;
}

static int stream_name(const char *name, ntfschar **out)
{
	int len, i;

	if (!name || !*name) {
		errno = EINVAL;
		return -1;
	}
	*out = NULL;
	len = ntfs_mbstoucs(name, out);
	if (len < 0)
		return -1;
	if (len > NTFS_MAX_NAME_LEN) {
		free(*out);
		*out = NULL;
		errno = ENAMETOOLONG;
		return -1;
	}
	/* ':' '\\' and friends are not valid in Windows stream names */
	for (i = 0; i < len; i++)
		(*out)[i] = sfm_to_disk(le16_to_cpu((*out)[i]), 0);
	return len;
}

int64_t ntfsb_getxattr(ntfsb_volume *v, uint64_t ino, const char *name,
		void *buf, size_t size)
{
	ntfs_inode *ni;
	ntfs_attr *na = NULL;
	ntfschar *uname = NULL;
	int ulen;
	int64_t ret;


	ulen = stream_name(name, &uname);
	if (ulen < 0)
		return neg_errno();
	ni = ni_open(v, ino);
	if (!ni) {
		ret = neg_errno();
		free(uname);
		return ret;
	}
	na = ntfs_attr_open(ni, AT_DATA, uname, ulen);
	if (!na) {
		ret = (errno == ENOENT) ? -ENOATTR : neg_errno();
		goto out;
	}
	ret = na->data_size;
	if (buf) {
		s64 want = na->data_size, total = 0;

		if ((s64)size < want)
			want = size;
		while (total < want) {
			s64 r = ntfs_attr_pread(na, total, want - total,
					(char *)buf + total);
			if (r <= 0) {
				ret = (r < 0) ? neg_errno() : -EIO;
				break;
			}
			total += r;
		}
	}
out:
	if (na)
		ntfs_attr_close(na);
	free(uname);
	if (ni_close(v, ni) && ret >= 0)
		ret = neg_errno();
	return ret;
}

int ntfsb_setxattr(ntfsb_volume *v, uint64_t ino, const char *name,
		const void *buf, size_t size, int flags)
{
	ntfs_inode *ni;
	ntfs_attr *na = NULL;
	ntfschar *uname = NULL;
	int ulen, ret = 0;
	s64 total = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	ulen = stream_name(name, &uname);
	if (ulen < 0)
		return neg_errno();
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni) {
		ret = neg_errno();
		free(uname);
		return ret;
	}
	na = ntfs_attr_open(ni, AT_DATA, uname, ulen);
	if (na) {
		if (flags & XATTR_CREATE) {
			ret = -EEXIST;
			goto out;
		}
		if (ntfs_attr_truncate(na, (s64)size)) {
			ret = neg_errno();
			goto out;
		}
	} else {
		if (errno != ENOENT) {
			ret = neg_errno();
			goto out;
		}
		if (flags & XATTR_REPLACE) {
			ret = -ENOATTR;
			goto out;
		}
		if (ntfs_attr_add(ni, AT_DATA, uname, ulen, NULL, 0)) {
			ret = neg_errno();
			goto out;
		}
		na = ntfs_attr_open(ni, AT_DATA, uname, ulen);
		if (!na) {
			ret = neg_errno();
			goto out;
		}
	}
	while (total < (s64)size) {
		s64 r = ntfs_attr_pwrite(na, total, (s64)size - total,
				(const char *)buf + total);
		if (r <= 0) {
			ret = neg_errno();
			break;
		}
		total += r;
	}
	if (!ret) {
		ni_set_archive(ni);
		ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	}
out:
	if (na)
		ntfs_attr_close(na);
	free(uname);
	if (ntfs_inode_close(ni) && !ret)
		ret = neg_errno();
	return ret;
}

int ntfsb_removexattr(ntfsb_volume *v, uint64_t ino, const char *name)
{
	ntfs_inode *ni;
	ntfschar *uname = NULL;
	int ulen, ret = 0;

	/* a failed flush of the cached file stops this modifying
	 * operation before it touches anything */
	ret = wcache_flush(v);
	if (ret)
		return ret;

	if (NVolReadOnly(v->vol))
		return -EROFS;
	ulen = stream_name(name, &uname);
	if (ulen < 0)
		return neg_errno();
	ni = ntfs_inode_open(v->vol, ino);
	if (!ni) {
		ret = neg_errno();
		free(uname);
		return ret;
	}
	if (ntfs_attr_remove(ni, AT_DATA, uname, ulen))
		ret = (errno == ENOENT) ? -ENOATTR : neg_errno();
	else
		ntfs_inode_update_times(ni, NTFS_UPDATE_CTIME);
	free(uname);
	if (ntfs_inode_close(ni) && !ret)
		ret = neg_errno();
	return ret;
}
