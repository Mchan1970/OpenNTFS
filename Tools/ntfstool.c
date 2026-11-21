/*
 * ntfstool - exercise the NTFS bridge on a disk image or raw device,
 * without FSKit. Used for testing the core.
 *
 *   ntfstool <image> info
 *   ntfstool <image> ls <path>
 *   ntfstool <image> stat <path>
 *   ntfstool <image> cat <path>              (to stdout)
 *   ntfstool <image> put <local> <path>
 *   ntfstool <image> get <path> <local>
 *   ntfstool <image> mkdir <path>
 *   ntfstool <image> rm <path>
 *   ntfstool <image> mv <from> <to>
 *   ntfstool <image> ln <existing> <new>
 *   ntfstool <image> symlink <target> <path>
 *   ntfstool <image> readlink <path>
 *   ntfstool <image> truncate <path> <size>
 *   ntfstool <image> setxattr <path> <name> <value>
 *   ntfstool <image> getxattr <path> <name>
 *   ntfstool <image> listxattr <path>
 *   ntfstool <image> rmxattr <path> <name>
 *   ntfstool <image> label <new label>
 *   ntfstool <image> stress <seed> <iterations>
 *   ntfstool <image> mftoff <path>            (byte range of the file's MFT record,
 *                                              read from the boot sector)
 *   ntfstool <image> flushtest <case>
 *        Write-flush fault-injection regression. Injection is
 *        enabled only by this command, after the
 *        file data has been written; NTFSTOOL_FAIL_ERRNO and
 *        NTFSTOOL_FAIL_MODE override the fault parameters (t5 pins its
 *        errnos because it exercises the priority between two of them).
 *        t6 and t8 need a 256 MiB image (preallocation requires the
 *        free space).
 *
 *        t10a/t10c need NTFSTOOL_IO_ALIGN as well: a mount-time device
 *        I/O granularity larger than the $I30 index block, so the
 *        index writeback of the flush takes bdev_pwrite()'s unaligned
 *        read-modify-write path whose prefetch read failure nothing
 *        records yet. Each case runs a record pass (on a copy of the
 *        image, no injection) and a formal pass (on the original), and
 *        fails exactly the recorded prefetch read. t10r stops after
 *        the record pass: the reachability check of the unaligned
 *        path (mount, unique covering read-modify-write); with
 *        NTFSTOOL_IO_TRACE=1 every device transfer is printed with
 *        its sequence number, type, offset and length.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#include "ntfs_bridge.h"
#include "ntfs_maint.h"
/* libntfs-3g consumer API, used by flushtest only: an independent
 * read-only helper mount that inspects committed metadata (runlists,
 * directory index entries, volume flags). No vendored code is modified. */
#include "attrib.h"
#include "dir.h"
#include "index.h"
#include "inode.h"
#include "layout.h"
#include "runlist.h"
#include "unistr.h"
#include "volume.h"

static int g_fd = -1;
static const char *g_image;
static unsigned long g_nw, g_nw_small, g_nr;

/* ---------------------------------------------------- fault injection
 *
 * Fault injection for the flush-error regression tests: one injector
 * for device writes (with a second slot for a disjoint write range)
 * and one for device reads. Each is dormant unless the flushtest
 * command arms it; every other command keeps bit-for-bit default
 * behaviour.
 *
 * While armed, each io_pwrite()/io_pread() whose byte range intersects
 * the armed [start, end) counts as an attempt against the target
 * range; while failing is set the transfer is rejected wholesale with
 * err (nothing reaches the image or the tool). mode "once" stops
 * failing after the first hit but keeps counting attempts, so a test
 * can tell how many times a single boundary retries. Counters
 * accumulate for the lifetime of the process.
 */
struct ft_fault {
	int monitored, failing;
	int64_t start, end;
	int err, once;
	unsigned long attempts, failures;
};
static struct ft_fault g_fault;     /* writes, primary range */
static struct ft_fault g_fault2;    /* writes, second range (t7b) */
static struct ft_fault g_fault_rd;  /* read faults (t9) */

/* One-shot fault at a specific trace position (t10): the recorded
 * prefetch read of one read-modify-write. When the operation at that
 * position does not match the recorded shape, nothing is injected and
 * the mismatch is remembered: the case is then not established. */
static struct {
	int armed;
	unsigned long k;      /* 1-based position in the current trace */
	int is_read;
	int64_t off, len;
	int short_read;       /* 0: fail with -EIO; 1: return 0 bytes with
	                       * an unrelated residual errno (ENOENT) */
	int hits, mismatch;
} g_fault_k;

static int fault_errno_name(const char *s, int fallback)
{
	if (!s || !*s)
		return fallback;
	if (!strcmp(s, "EIO"))
		return EIO;
	if (!strcmp(s, "ENOSPC"))
		return ENOSPC;
	if (!strcmp(s, "EROFS"))
		return EROFS;
	return atoi(s) > 0 ? atoi(s) : fallback;
}

static int fault_mode_name(const char *s, int once)
{
	if (!s || !*s)
		return once;
	if (!strcmp(s, "once"))
		return 1;
	if (!strcmp(s, "always"))
		return 0;
	fprintf(stderr, "ntfstool: unknown NTFSTOOL_FAIL_MODE %s\n", s);
	return once;
}

static void fault_arm_at(struct ft_fault *f, int64_t start, int64_t end,
		int err, int once)
{
	f->monitored = 1;
	f->failing = 1;
	f->start = start;
	f->end = end;
	f->err = err;
	f->once = once;
}

static void fault_arm(int64_t start, int64_t end, int err, int once)
{
	fault_arm_at(&g_fault, start, end, err, once);
}

static void fault_disarm(void)
{
	g_fault.monitored = 0;
	g_fault.failing = 0;
	g_fault2.monitored = 0;
	g_fault2.failing = 0;
	g_fault_rd.monitored = 0;
	g_fault_rd.failing = 0;
	g_fault_k.armed = 0;
}

/* Called from io_pwrite() for a write that intersects the range.
 * Returns the errno to fail the write with, or 0 to let it through. */
static int fault_hit(struct ft_fault *f)
{
	f->attempts++;
	if (!f->failing)
		return 0;
	f->failures++;
	if (f->once)
		f->failing = 0;
	return f->err;
}

/* ------------------------------------------------------ device I/O trace
 *
 * Every device-level transfer (one io_pread / io_pwrite call) with its
 * return value, optionally echoed to stderr with its sequence number.
 * The unaligned-write cases locate the read-modify-write of a specific
 * index block by its shape in this sequence: a full-granularity read
 * immediately followed by the covering write.
 */
struct io_ev {
	char type;              /* 'R' or 'W' */
	int64_t off, len, ret;
};
#define IO_EV_MAX 262144
static struct io_ev g_ev[IO_EV_MAX];
static unsigned long g_nev;
static int g_ev_overflow;
static int g_io_trace;

static void io_trace_reset(void)
{
	g_nev = 0;
	g_ev_overflow = 0;
}

static void io_trace_add(char type, int64_t off, int64_t len, int64_t ret)
{
	if (g_nev < IO_EV_MAX)
		g_ev[g_nev] = (struct io_ev){ type, off, len, ret };
	else
		g_ev_overflow = 1;
	g_nev++;
	if (g_io_trace)
		fprintf(stderr, "IO %lu %c %lld +%lld => %lld\n", g_nev, type,
			(long long)off, (long long)len, (long long)ret);
}

/* Fail the operation at trace position k when its type, offset and
 * length match the recorded ones. Returns 1 with *ret set to the
 * failure the caller must return instead of transferring. */
static int ft_k_fault_hit(int is_read, int64_t off, int64_t len, int64_t *ret)
{
	if (!g_fault_k.armed || g_nev + 1 != g_fault_k.k)
		return 0;
	if (is_read != g_fault_k.is_read || off != g_fault_k.off
	    || len != g_fault_k.len) {
		g_fault_k.mismatch = 1;
		return 0;
	}
	g_fault_k.hits++;
	if (g_fault_k.short_read) {
		errno = ENOENT;       /* residual errno, unrelated to the
		                       * short read itself */
		*ret = 0;
	} else
		*ret = -EIO;
	return 1;
}

/* -------------------------------------------------- NTFS boot sector
 *
 * Read the layout parameters straight from the boot sector, so tools can
 * compute MFT record offsets without touching the bridge internals. The
 * MFT of a freshly formatted image is one contiguous run starting at
 * mft_lcn (mkntfs does not fragment it that early), which is what the
 * flush-error tests rely on.
 */
static uint16_t rd_le16(const unsigned char *p)
{
	return (uint16_t)(p[0] | (p[1] << 8));
}

static int64_t rd_le64(const unsigned char *p)
{
	uint64_t v = 0;
	int i;

	for (i = 7; i >= 0; i--)
		v = (v << 8) | p[i];
	return (int64_t)v;
}

static int boot_geometry(uint32_t *sector, uint32_t *cluster, uint32_t *mrs,
		int64_t *mft_off)
{
	unsigned char b[512];
	uint32_t ss, cs, m;
	uint8_t spc;
	int8_t cm;
	int64_t lcn;

	if (pread(g_fd, b, sizeof(b), 0) != (ssize_t)sizeof(b))
		return -1;
	if (memcmp(b + 3, "NTFS    ", 8))
		return -1;
	ss = rd_le16(b + 11);
	if (ss < 512 || ss > 4096 || (ss & (ss - 1)))
		return -1;
	spc = b[13];
	cs = spc > 0x80 ? ss << (256 - spc) : ss * spc;
	if (!cs || (cs & (cs - 1)))
		return -1;
	cm = (int8_t)b[64];
	m = cm > 0 ? cs * (uint32_t)cm : (cm < 0 && cm > -16) ? 1U << -cm : 0;
	/* a record must fit one cluster and one sector, so a record write
	 * reaches the device as a single aligned pwrite */
	if (m < ss || m > cs || m > 65536 || (m & (m - 1)))
		return -1;
	lcn = rd_le64(b + 48);
	if (lcn <= 0)
		return -1;
	*sector = ss;
	*cluster = cs;
	*mrs = m;
	*mft_off = lcn * cs;
	return 0;
}

static void ino_record_range(int64_t mft_off, uint32_t mrs, uint64_t ino,
		int64_t *start, int64_t *end)
{
	*start = mft_off + (int64_t)ino * mrs;
	*end = *start + mrs;
}

static int64_t io_pread(void *ctx, void *buf, int64_t count, int64_t off)
{
	ssize_t r;
	int64_t fret;

	if (ft_k_fault_hit(1, off, count, &fret)) {
		io_trace_add('R', off, count, fret);
		return fret;
	}
	if (g_fault_rd.monitored && off < g_fault_rd.end
	    && off + count > g_fault_rd.start) {
		int err = fault_hit(&g_fault_rd);

		if (err) {
			io_trace_add('R', off, count, -err);
			return -err;
		}
	}
	r = pread(g_fd, buf, count, off);
	g_nr++;
	if (getenv("NTFSTOOL_TRACE") && g_nw > 150 && g_nw < 175)
		fprintf(stderr, "R %10lld +%lld\n", (long long)off, (long long)count);
	(void)ctx;
	io_trace_add('R', off, count, r < 0 ? -errno : r);
	return r < 0 ? -errno : r;
}

static void io_stats(void)
{
	if (getenv("NTFSTOOL_STATS"))
		fprintf(stderr, "device writes: %lu (%lu of <= 64K), reads: %lu\n",
			g_nw, g_nw_small, g_nr);
	if (g_fault.monitored || g_fault.attempts || g_fault.failures)
		fprintf(stderr, "write fault 1: attempts %lu, failures %lu "
			"(range [%lld,%lld) errno %d mode %s)\n",
			g_fault.attempts, g_fault.failures,
			(long long)g_fault.start, (long long)g_fault.end,
			g_fault.err, g_fault.once ? "once" : "always");
	if (g_fault2.monitored || g_fault2.attempts || g_fault2.failures)
		fprintf(stderr, "write fault 2: attempts %lu, failures %lu "
			"(range [%lld,%lld) errno %d mode %s)\n",
			g_fault2.attempts, g_fault2.failures,
			(long long)g_fault2.start, (long long)g_fault2.end,
			g_fault2.err, g_fault2.once ? "once" : "always");
	if (g_fault_rd.monitored || g_fault_rd.attempts || g_fault_rd.failures)
		fprintf(stderr, "read fault: attempts %lu, failures %lu "
			"(range [%lld,%lld) errno %d mode %s)\n",
			g_fault_rd.attempts, g_fault_rd.failures,
			(long long)g_fault_rd.start, (long long)g_fault_rd.end,
			g_fault_rd.err, g_fault_rd.once ? "once" : "always");
	if (g_fault_k.armed)
		fprintf(stderr, "k fault: position %lu, hits %d, mismatch %d\n",
			g_fault_k.k, g_fault_k.hits, g_fault_k.mismatch);
}

static int64_t io_pwrite(void *ctx, const void *buf, int64_t count, int64_t off)
{
	ssize_t r;
	int64_t fret;

	if (ft_k_fault_hit(0, off, count, &fret)) {
		io_trace_add('W', off, count, fret);
		return fret;
	}
	if (g_fault.monitored && off < g_fault.end && off + count > g_fault.start) {
		int err = fault_hit(&g_fault);

		if (err) {
			io_trace_add('W', off, count, -err);
			return -err;
		}
	}
	if (g_fault2.monitored && off < g_fault2.end
	    && off + count > g_fault2.start) {
		int err = fault_hit(&g_fault2);

		if (err) {
			io_trace_add('W', off, count, -err);
			return -err;
		}
	}
	r = pwrite(g_fd, buf, count, off);
	g_nw++;
	if (getenv("NTFSTOOL_TRACE") && g_nw > 150 && g_nw < 175)
		fprintf(stderr, "W %10lld +%lld\n", (long long)off, (long long)count);
	if (count <= 65536)
		g_nw_small++;
	(void)ctx;
	io_trace_add('W', off, count, r < 0 ? -errno : r);
	return r < 0 ? -errno : r;
}

static int io_sync(void *ctx)
{
	(void)ctx;
	return fsync(g_fd) ? -errno : 0;
}

static void log_cb(int level, const char *msg)
{
	static const char *names[] = { "debug", "info", "warn", "error" };
	fprintf(stderr, "[ntfs %s] %s\n", names[level & 3], msg);
}

static void maint_out(void *ctx, const char *line)
{
	(void)ctx;
	printf("  | %s\n", line);
}

static void die(const char *what, int err)
{
	fprintf(stderr, "ntfstool: %s: %s\n", what, strerror(-err));
	exit(1);
}

/* Resolve an absolute path to an inode number. */
static int resolve(ntfsb_volume *v, const char *path, uint64_t *ino,
		ntfsb_stat *st)
{
	char *copy = strdup(path), *save = NULL, *tok;
	uint64_t cur = NTFSB_ROOT_INO;
	ntfsb_stat s;
	int r = ntfsb_getattr(v, cur, &s);

	for (tok = strtok_r(copy, "/", &save); tok && !r;
			tok = strtok_r(NULL, "/", &save)) {
		r = ntfsb_lookup(v, cur, tok, &s, NULL);
		cur = s.ino;
	}
	free(copy);
	if (!r) {
		*ino = cur;
		if (st)
			*st = s;
	}
	return r;
}

/* Split into parent inode + leaf name (pointer into @path). */
static int resolve_parent(ntfsb_volume *v, const char *path, uint64_t *dir,
		const char **leaf)
{
	const char *slash = strrchr(path, '/');
	char *parent;
	int r;

	if (!slash) {
		*dir = NTFSB_ROOT_INO;
		*leaf = path;
		return 0;
	}
	parent = strndup(path, slash - path);
	r = resolve(v, parent, dir, NULL);
	free(parent);
	*leaf = slash + 1;
	return r;
}

static int ls_cb(void *ctx, const char *name, size_t len, uint64_t ino, int dt)
{
	static const char types[] = "?-dlpscb";
	(void)ctx; (void)len;
	printf("%c %10llu  %s\n", types[dt & 7], (unsigned long long)ino, name);
	return 0;
}

static int xattr_cb(void *ctx, const char *name, uint64_t size)
{
	(void)ctx;
	printf("%s\t%llu\n", name, (unsigned long long)size);
	return 0;
}

/* ------------------------------------------------------------- stress */

#define NFILES 24
#define MAXSIZE (3 * 1024 * 1024)

struct shadow {
	int exists;
	int is_dir;
	char name[64];
	unsigned char *data;
	size_t size;
};

static uint64_t rng_state;
static uint32_t rnd(void)
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return (uint32_t)(rng_state >> 16);
}

static void fill(unsigned char *p, size_t n)
{
	size_t i;
	uint32_t x = rnd();
	for (i = 0; i < n; i++) {
		x = x * 1664525u + 1013904223u;
		p[i] = (unsigned char)(x >> 24);
	}
}

#define CHECK(cond, ...) do { if (!(cond)) { \
	fprintf(stderr, "STRESS FAILURE (iteration %d): ", iter); \
	fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); exit(2); } } while (0)

static int verify_all(ntfsb_volume *v, uint64_t dir, struct shadow *f, int iter)
{
	int i, checked = 0;
	unsigned char *buf = malloc(MAXSIZE + 1);

	for (i = 0; i < NFILES; i++) {
		ntfsb_stat st;
		int r = ntfsb_lookup(v, dir, f[i].name, &st, NULL);

		if (!f[i].exists) {
			CHECK(r == -ENOENT, "%s should not exist (r=%d)", f[i].name, r);
			continue;
		}
		CHECK(r == 0, "lookup %s: %s", f[i].name, strerror(-r));
		if (f[i].is_dir) {
			CHECK(S_ISDIR(st.mode), "%s should be a directory", f[i].name);
			continue;
		}
		CHECK(S_ISREG(st.mode), "%s should be a file", f[i].name);
		CHECK(st.size == f[i].size, "%s size %llu, expected %zu",
			f[i].name, (unsigned long long)st.size, f[i].size);
		if (f[i].size) {
			int64_t n = ntfsb_read(v, st.ino, buf, f[i].size + 1, 0);
			CHECK(n == (int64_t)f[i].size, "%s read %lld of %zu",
				f[i].name, (long long)n, f[i].size);
			CHECK(!memcmp(buf, f[i].data, f[i].size),
				"%s content mismatch", f[i].name);
		}
		checked++;
	}
	free(buf);
	return checked;
}

static ntfsb_volume *do_mount(const ntfsb_device *dev, unsigned flags);

static int stress(const ntfsb_device *dev, ntfsb_volume *v, uint64_t seed,
		int iterations)
{
	struct shadow f[NFILES];
	ntfsb_stat st;
	uint64_t dir;
	unsigned char *tmp = malloc(MAXSIZE);
	char dirname[64];
	int iter = 0, i, r;
	ntfsb_info before, after;

	memset(f, 0, sizeof(f));
	rng_state = seed * 0x9e3779b97f4a7c15ULL + 1;
	snprintf(dirname, sizeof(dirname), "stress-%llu", (unsigned long long)seed);
	r = ntfsb_create(v, NTFSB_ROOT_INO, dirname, S_IFDIR, &st);
	CHECK(r == 0, "mkdir %s: %s", dirname, strerror(-r));
	dir = st.ino;
	for (i = 0; i < NFILES; i++)
		/* mix in names that need the Windows character mapping,
		 * non-ASCII names and long names */
		snprintf(f[i].name, sizeof(f[i].name),
			(i % 6 == 0) ? "q?:%d*.bin" :
			(i % 6 == 1) ? "\xe6\x96\x87\xe4\xbb\xb6-%d.dat" :
			(i % 6 == 2) ? "trailing dot %d." :
			"file-%d.bin", i);
	ntfsb_get_info(v, &before);

	for (iter = 1; iter <= iterations; iter++) {
		struct shadow *s = &f[rnd() % NFILES];
		unsigned op = rnd() % 100;

		if (!s->exists) {
			int mkdir = (rnd() % 8) == 0;
			r = ntfsb_create(v, dir, s->name, mkdir ? S_IFDIR : S_IFREG, &st);
			CHECK(r == 0, "create %s: %s", s->name, strerror(-r));
			s->exists = 1;
			s->is_dir = mkdir;
			s->size = 0;
			s->data = mkdir ? NULL : calloc(1, MAXSIZE);
			continue;
		}
		r = ntfsb_lookup(v, dir, s->name, &st, NULL);
		CHECK(r == 0, "lookup %s: %s", s->name, strerror(-r));

		if (op < 12) {                              /* delete */
			r = ntfsb_remove(v, dir, s->name);
			CHECK(r == 0, "remove %s: %s", s->name, strerror(-r));
			free(s->data);
			s->data = NULL;
			s->exists = 0;
		} else if (op < 22) {                       /* rename */
			struct shadow *d = &f[rnd() % NFILES];
			if (d == s)
				continue;
			if (d->exists && (d->is_dir != s->is_dir))
				continue;
			r = ntfsb_rename(v, dir, s->name, dir, d->name);
			CHECK(r == 0, "rename %s -> %s: %s", s->name, d->name, strerror(-r));
			free(d->data);
			d->data = s->data;
			d->size = s->size;
			d->is_dir = s->is_dir;
			d->exists = 1;
			s->data = NULL;
			s->exists = 0;
		} else if (s->is_dir) {
			continue;
		} else if (op < 34) {                       /* truncate */
			size_t ns = (rnd() % 3 == 0) ? rnd() % 700 : rnd() % MAXSIZE;
			r = ntfsb_truncate(v, st.ino, ns);
			CHECK(r == 0, "truncate %s to %zu: %s", s->name, ns, strerror(-r));
			if (ns < s->size)
				memset(s->data + ns, 0, s->size - ns);
			s->size = ns;
		} else if (op < 44) {                       /* release (close) */
			r = ntfsb_release(v, st.ino);
			CHECK(r == 0, "release %s: %s", s->name, strerror(-r));
		} else {                                    /* write */
			size_t off, len;
			int64_t n;
			switch (rnd() % 4) {
			case 0: off = s->size; len = rnd() % 200000; break;     /* append */
			case 1: off = rnd() % 900; len = rnd() % 600; break;    /* tiny, resident */
			case 2: off = rnd() % MAXSIZE; len = rnd() % 70000; break; /* sparse-ish */
			default: off = s->size ? rnd() % s->size : 0; len = rnd() % 300000; break;
			}
			if (off >= MAXSIZE)
				off = MAXSIZE - 1;
			if (off + len > MAXSIZE)
				len = MAXSIZE - off;
			if (!len)
				continue;
			fill(tmp, len);
			n = ntfsb_write(v, st.ino, tmp, len, off);
			CHECK(n == (int64_t)len, "write %s off %zu len %zu -> %lld",
				s->name, off, len, (long long)n);
			memcpy(s->data + off, tmp, len);
			if (off + len > s->size)
				s->size = off + len;
		}
		if (iter % 500 == 0)
			verify_all(v, dir, f, iter);
	}
	i = verify_all(v, dir, f, iter);
	printf("stress: %d iterations ok, %d files verified before remount\n",
		iterations, i);

	/* Everything must survive an unmount / mount cycle. */
	r = ntfsb_unmount(v);
	CHECK(r == 0, "unmount: %s", strerror(-r));
	v = do_mount(dev, 0);
	r = ntfsb_lookup(v, NTFSB_ROOT_INO, dirname, &st, NULL);
	CHECK(r == 0, "lookup %s after remount: %s", dirname, strerror(-r));
	dir = st.ino;
	i = verify_all(v, dir, f, iter);
	printf("stress: %d files verified after remount\n", i);

	/* Clean up and make sure the space comes back. */
	for (i = 0; i < NFILES; i++) {
		if (!f[i].exists)
			continue;
		r = ntfsb_remove(v, dir, f[i].name);
		CHECK(r == 0, "cleanup %s: %s", f[i].name, strerror(-r));
		free(f[i].data);
	}
	r = ntfsb_remove(v, NTFSB_ROOT_INO, dirname);
	CHECK(r == 0, "cleanup dir: %s", strerror(-r));
	ntfsb_get_info(v, &after);
	printf("stress: free clusters before %llu, after cleanup %llu\n",
		(unsigned long long)before.free_clusters,
		(unsigned long long)after.free_clusters);
	free(tmp);
	r = ntfsb_unmount(v);
	CHECK(r == 0, "final unmount: %s", strerror(-r));
	return 0;
}

static ntfsb_volume *do_mount(const ntfsb_device *dev, unsigned flags)
{
	int err = 0;
	ntfsb_volume *v = ntfsb_mount(dev, flags, getuid(), getgid(), &err);

	if (!v)
		die("mount", err);
	return v;
}

/* -------------------------------------------------- flush error tests
 *
 * The flush-error regression cases. Every case runs in ONE process
 * on its own freshly formatted image: the write cache that keeps the file
 * being written open belongs to the process, so write -> inject -> sync
 * -> verify cannot be split across invocations.
 *
 * The assertions state the intended behaviour: sticky flush errors,
 * a single owned flush, and call points that stop on the first failure.
 * Every case prints each failed assertion and exits non-zero.
 */

#define FT_T0 1700000000         /* baseline mtime for file B */
#define FT_T1 (FT_T0 + 3600)     /* mtime the failing set_times tries to set */

static int ft_checks, ft_fails;

static void ft_assert(const char *id, const char *what, int ok,
		const char *detail)
{
	char tail[96];

	ft_checks++;
	if (!ok)
		ft_fails++;
	if (detail && *detail)
		snprintf(tail, sizeof(tail), " (%s)", detail);
	else
		tail[0] = 0;
	printf("%s: [%s] %s%s\n", ok ? "ok" : "FAIL", id, what, tail);
}

static const char *ft_rc(int r)
{
	static char buf[8][48];
	static int n;

	n = (n + 1) & 7;
	if (r)
		snprintf(buf[n], sizeof(buf[n]), "got %d (%s)", r, strerror(-r));
	else
		snprintf(buf[n], sizeof(buf[n]), "got 0");
	return buf[n];
}

static const char *ft_growth(unsigned long da, unsigned long df)
{
	static char buf[8][64];
	static int n;

	n = (n + 1) & 7;
	snprintf(buf[n], sizeof(buf[n]), "attempts +%lu, failures +%lu",
		da, df);
	return buf[n];
}

static const char *ft_ll(const char *what, long long v)
{
	static char buf[8][64];
	static int n;

	n = (n + 1) & 7;
	snprintf(buf[n], sizeof(buf[n]), "%s %lld", what, v);
	return buf[n];
}

static int ft_done(const char *id)
{
	printf("[%s] %d/%d assertions passed\n", id, ft_checks - ft_fails,
		ft_checks);
	return ft_fails ? 1 : 0;
}

static void ft_pattern(unsigned char *p, size_t n, uint32_t seed)
{
	uint32_t x = seed;
	size_t i;

	for (i = 0; i < n; i++) {
		x = x * 1664525u + 1013904223u;
		p[i] = (unsigned char)(x >> 24);
	}
}

/* Create <name> with n bytes of a deterministic pattern in @dir
 * (n <= 512, so the data stays resident in the MFT record). The last
 * file created stays in the write cache: it is the file whose flush the
 * case breaks. */
static int ft_make_file_at(ntfsb_volume *v, uint64_t dir, const char *name,
		size_t n, uint32_t seed, uint64_t *ino)
{
	unsigned char buf[512];
	ntfsb_stat st;
	int r;

	if (n > sizeof(buf))
		return -EINVAL;
	ft_pattern(buf, n, seed);
	r = ntfsb_create(v, dir, name, S_IFREG, &st);
	if (r)
		return r;
	*ino = st.ino;
	if (n && ntfsb_write(v, st.ino, buf, n, 0) != (int64_t)n)
		return -EIO;
	return 0;
}

static int ft_make_file(ntfsb_volume *v, const char *name, size_t n,
		uint32_t seed, uint64_t *ino)
{
	return ft_make_file_at(v, NTFSB_ROOT_INO, name, n, seed, ino);
}

/* ------------------------------------------------ read-only helper mount
 *
 * A second, independent read-only mount through libntfs-3g's own unix_io
 * driver (its own file descriptor). The flush-error cases use it to
 * inspect COMMITTED on-disk metadata while the bridge volume is open or
 * after it unmounted: runlists, directory index entries and the volume
 * flags. It never writes.
 */
static ntfs_volume *helper_mount(void)
{
	errno = 0;
	ntfs_volume *h = ntfs_mount(g_image, NTFS_MNT_RDONLY);

	if (!h)
		fprintf(stderr, "flushtest: helper mount of %s failed: %s\n",
			g_image, strerror(errno));
	return h;
}

static void helper_umount(ntfs_volume *h)
{
	if (h)
		ntfs_umount(h, FALSE);
}

/*
 * The byte range covering the mapped part of @na's runlist. Fails when
 * it is fragmented, so the fault injection can cover it with a single
 * [start, end) range. Freshly formatted images allocate these
 * attributes in one piece.
 */
static int attr_data_range(ntfs_attr *na, int64_t *start, int64_t *end)
{
	runlist_element *rl;
	s64 cs = na->ni->vol->cluster_size;
	s64 s = -1, e = -1;

	/* the runlist is loaded lazily */
	if (ntfs_attr_map_whole_runlist(na))
		return -1;
	for (rl = na->rl; rl && rl->length; rl++) {
		s64 rs = rl->lcn * cs;

		if (rl->lcn < 0)
			continue;
		if (s < 0) {
			s = rs;
			e = rs + rl->length * cs;
		} else if (rs != e) {
			return -1;
		} else {
			e += rl->length * cs;
		}
	}
	if (s < 0)
		return -1;
	*start = s;
	*end = e;
	return 0;
}

static ntfsb_volume *ft_remount(ntfsb_device *dev)
{
	int err = 0;

	return ntfsb_mount(dev, 0, getuid(), getgid(), &err);
}

/* Resolve /<path>, assert its size and read the content back. */
static void ft_verify(ntfsb_volume *v, const char *id, const char *path,
		size_t n, uint32_t seed)
{
	unsigned char want[512], got[512];
	ntfsb_stat st;
	uint64_t ino;
	char d[64];
	int r, ok = 1;

	ft_pattern(want, n, seed);
	r = resolve(v, path, &ino, &st);
	if (r) {
		ft_assert(id, "file resolves", 0, ft_rc(r));
		return;
	}
	snprintf(d, sizeof(d), "got %llu", (unsigned long long)st.size);
	ft_assert(id, "file size survived", st.size == n, d);
	if (st.size != n || st.size > sizeof(got))
		return;
	if (ntfsb_read(v, ino, got, st.size, 0) != (int64_t)st.size
	    || memcmp(got, want, st.size))
		ok = 0;
	ft_assert(id, "file content survived", ok,
		ok ? "" : "read back mismatch");
}

static int ft_set_times(ntfsb_volume *v, uint64_t ino, time_t t)
{
	struct timespec ts;

	ts.tv_sec = t;
	ts.tv_nsec = 0;
	return ntfsb_set_times(v, ino, &ts, &ts, &ts, &ts);
}

/* Resolve /<path> and assert that it does NOT exist. */
static void ft_assert_absent(ntfsb_volume *v, const char *id, const char *path)
{
	ntfsb_stat st;
	uint64_t ino;
	char what[80];
	int r = resolve(v, path, &ino, &st);

	snprintf(what, sizeof(what), "%s does not exist", path);
	ft_assert(id, what, r == -ENOENT, ft_rc(r));
}


/* Compute and report the MFT record range of @ino, arming target. */
static int ft_target(const char *id, uint64_t ino, int64_t *start,
		int64_t *end)
{
	uint32_t sector, cluster, mrs;
	int64_t mft_off;

	if (boot_geometry(&sector, &cluster, &mrs, &mft_off)) {
		fprintf(stderr, "flushtest: cannot parse the boot sector\n");
		return -1;
	}
	ino_record_range(mft_off, mrs, ino, start, end);
	printf("[%s] geometry: sector %u cluster %u mft_record %u; target "
		"ino %llu mft_record %lld..%lld\n", id, sector, cluster, mrs,
		(unsigned long long)ino, (long long)*start, (long long)*end);
	return 0;
}

/* Arm the injection. @pinned (t5) keeps the requested errno/mode: the
 * case is exactly about the priority between two different errnos. */
static void ft_arm(const char *id, int64_t start, int64_t end, int err,
		int once, int pinned)
{
	int e = err, o = once;

	if (!pinned) {
		e = fault_errno_name(getenv("NTFSTOOL_FAIL_ERRNO"), err);
		o = fault_mode_name(getenv("NTFSTOOL_FAIL_MODE"), once);
	}
	fault_arm(start, end, e, o);
	printf("[%s] injection armed: range [%lld,%lld) errno %d mode %s\n",
		id, (long long)start, (long long)end, e,
		o ? "once" : "always");
}

static int ft_setup2(ntfsb_volume *v, uint32_t aseed, uint32_t bseed,
		uint64_t *aino, uint64_t *bino)
{
	/* B first with a stable baseline time: writing A afterwards leaves
	 * A, and only A, dirty in the write cache. */
	if (ft_make_file(v, "b.bin", 100, bseed, bino)
	    || ft_set_times(v, *bino, FT_T0)
	    || ft_make_file(v, "a.bin", 256, aseed, aino)) {
		fprintf(stderr, "flushtest: setup failed\n");
		return -1;
	}
	return 0;
}

/* T1: a one-shot EIO on A's MFT record. */
static int ft_t1(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t1";
	int64_t rs, re;
	uint64_t ino;
	int r, r1, r2, ur;
	unsigned long att1, fails;

	r = ft_make_file(v, "a.bin", 256, 0x010101, &ino);
	if (r || ft_target(id, ino, &rs, &re))
		return 1;
	ft_arm(id, rs, re, EIO, 1, 0);
	r1 = ntfsb_sync(v);
	att1 = g_fault.attempts;
	fails = g_fault.failures;
	r2 = ntfsb_sync(v);
	ur = ntfsb_unmount(v);
	ft_assert(id, "first ntfsb_sync returns -EIO", r1 == -EIO, ft_rc(r1));
	ft_assert(id, "exactly one write attempt against the target range "
		"during the first sync", att1 == 1,
		ft_ll("attempts", (long long)att1));
	ft_assert(id, "the target range saw at least one failed write",
		fails > 0, ft_ll("failures", (long long)fails));
	ft_assert(id, "second ntfsb_sync returns 0", r2 == 0, ft_rc(r2));
	ft_assert(id, "unmount after the successful retry returns 0",
		ur == 0, ft_rc(ur));
	fault_disarm();
	v = ft_remount(dev);
	ft_assert(id, "image remounts", v != NULL, v ? "" : "mount failed");
	if (v) {
		ft_verify(v, id, "/a.bin", 256, 0x010101);
		ur = ntfsb_unmount(v);
		ft_assert(id, "final unmount returns 0", ur == 0, ft_rc(ur));
	}
	return ft_done(id);
}

/* T2: persistent failure, every sync and the unmount must report it. */
static int ft_t2(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t2";
	int64_t rs, re;
	uint64_t ino, keep;
	ntfsb_stat st;
	char d[64];
	int r, r1, r2, ur;

	if (ft_make_file(v, "keep.bin", 512, 0x020202, &keep)
	    || ft_make_file(v, "a.bin", 256, 0x030303, &ino)
	    || ft_target(id, ino, &rs, &re))
		return 1;
	unsigned long a0, a1, a2, f0, f1, f2;

	ft_arm(id, rs, re, EIO, 0, 0);
	a0 = g_fault.attempts; f0 = g_fault.failures;
	r1 = ntfsb_sync(v);
	a1 = g_fault.attempts; f1 = g_fault.failures;
	r2 = ntfsb_sync(v);
	a2 = g_fault.attempts; f2 = g_fault.failures;
	ur = ntfsb_unmount(v);
	ft_assert(id, "first ntfsb_sync returns -EIO", r1 == -EIO, ft_rc(r1));
	ft_assert(id, "the first sync retried the target range",
		a1 > a0 && f1 > f0, ft_growth(a1 - a0, f1 - f0));
	ft_assert(id, "second ntfsb_sync still returns -EIO", r2 == -EIO,
		ft_rc(r2));
	ft_assert(id, "the second sync retried the target range again",
		a2 > a1 && f2 > f1, ft_growth(a2 - a1, f2 - f1));
	ft_assert(id, "unmount returns -EIO", ur == -EIO, ft_rc(ur));
	/* The ASan build guards the "no use-after-free" part of this case.
	 * (LeakSanitizer is not available on macOS, so the leaked inode of
	 * the unfixed code shows up through the swallowed errors above
	 * instead of a leak report.) */
	fault_disarm();
	v = ft_remount(dev);
	ft_assert(id, "image remounts once injection is disabled", v != NULL,
		v ? "" : "mount failed");
	if (v) {
		ft_verify(v, id, "/keep.bin", 512, 0x020202);
		r = resolve(v, "/a.bin", &ino, &st);
		if (r) {
			ft_assert(id, "a.bin resolves after remount", 0,
				ft_rc(r));
		} else {
			snprintf(d, sizeof(d), "got %llu",
				(unsigned long long)st.size);
			ft_assert(id, "a.bin size is the pre-write or "
				"post-write size",
				st.size == 0 || st.size == 256, d);
		}
		ur = ntfsb_unmount(v);
		ft_assert(id, "final unmount returns 0", ur == 0, ft_rc(ur));
	}
	return ft_done(id);
}

/* T3: a failure while flushing A must surface through an operation on B. */
static int ft_t3(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t3";
	int64_t rs, re;
	uint64_t aino, bino;
	ntfsb_stat st;
	char d[64];
	int rb, r, r1, r2, ur;

	(void)dev;
	if (ft_setup2(v, 0x050505, 0x040404, &aino, &bino)
	    || ft_target(id, aino, &rs, &re))
		return 1;
	ft_arm(id, rs, re, EIO, 1, 0);
	rb = ft_set_times(v, bino, FT_T1);
	r = resolve(v, "/b.bin", &bino, &st);
	r1 = ntfsb_sync(v);
	r2 = ntfsb_sync(v);
	ft_assert(id, "set_times on B returns -EIO (A's flush error not "
		"swallowed)", rb == -EIO, ft_rc(rb));
	if (r) {
		ft_assert(id, "B resolves", 0, ft_rc(r));
	} else {
		snprintf(d, sizeof(d), "got %lld", (long long)st.mtime.tv_sec);
		ft_assert(id, "B untouched: mtime unchanged",
			st.mtime.tv_sec == FT_T0, d);
		snprintf(d, sizeof(d), "got %llu", (unsigned long long)st.size);
		ft_assert(id, "B untouched: size unchanged", st.size == 100, d);
	}
	ft_assert(id, "first ntfsb_sync still returns A's -EIO", r1 == -EIO,
		ft_rc(r1));
	ft_assert(id, "second ntfsb_sync returns 0", r2 == 0, ft_rc(r2));
	ft_assert(id, "the target range saw at least one failed write",
		g_fault.failures > 0,
		ft_ll("failures", (long long)g_fault.failures));
	ft_verify(v, id, "/a.bin", 256, 0x050505);
	ur = ntfsb_unmount(v);
	ft_assert(id, "final unmount returns 0", ur == 0, ft_rc(ur));
	return ft_done(id);
}

/* T4: with the flush persistently failing, every modifying call point
 * must refuse, and B must not be touched. */
static int ft_t4(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t4";
	struct { const char *what; int rc; } ops[11];
	int64_t rs, re;
	uint64_t aino, bino, ino;
	ntfsb_stat st0, st;
	char d[96];
	int i, r, ur;

	ntfsb_info info;
	int64_t xa;
	char xbuf[8];

	(void)dev;
	/* B with a stable baseline, plus valid targets for every operation,
	 * all created while nothing is armed: the rename/remove sources and
	 * the xattr to remove exist, so the only possible failure of the
	 * operations below is the injected one. */
	if (ft_make_file(v, "b.bin", 100, 0x060606, &bino)
	    || ft_set_times(v, bino, FT_T0)) {
		fprintf(stderr, "flushtest t4: setup failed\n");
		return 1;
	}
	r = ntfsb_link(v, bino, NTFSB_ROOT_INO, "b.link");
	r |= ntfsb_link(v, bino, NTFSB_ROOT_INO, "b.link2");
	r |= ntfsb_setxattr(v, bino, "flushtest.xattr", "orig", 4, 0);
	ft_assert(id, "setup of the valid targets", r == 0, ft_rc(r));
	r = resolve(v, "/b.bin", &bino, &st0);
	ft_assert(id, "baseline stat of B", r == 0, ft_rc(r));
	ntfsb_get_info(v, &info);
	/* A last: it stays dirty in the write cache */
	if (ft_make_file(v, "a.bin", 256, 0x070707, &aino)) {
		fprintf(stderr, "flushtest t4: target setup failed\n");
		return 1;
	}
	if (ft_target(id, aino, &rs, &re))
		return 1;
	ft_arm(id, rs, re, EIO, 0, 0);
	ops[0].what = "ntfsb_create(/c.bin)";
	ops[0].rc = ntfsb_create(v, NTFSB_ROOT_INO, "c.bin", S_IFREG, &st);
	ops[1].what = "ntfsb_set_times(B)";
	ops[1].rc = ft_set_times(v, bino, FT_T1);
	ops[2].what = "ntfsb_set_bsd_flags(B, hidden)";
	ops[2].rc = ntfsb_set_bsd_flags(v, bino, UF_HIDDEN);
	ops[3].what = "ntfsb_setxattr(B, replace)";
	ops[3].rc = ntfsb_setxattr(v, bino, "flushtest.xattr", "new", 3, 0);
	ops[4].what = "ntfsb_removexattr(B)";
	ops[4].rc = ntfsb_removexattr(v, bino, "flushtest.xattr");
	ops[5].what = "ntfsb_truncate(B, 4096)";
	ops[5].rc = ntfsb_truncate(v, bino, 4096);
	ops[6].what = "ntfsb_link(B, /b3.link)";
	ops[6].rc = ntfsb_link(v, bino, NTFSB_ROOT_INO, "b3.link");
	ops[7].what = "ntfsb_rename(/b.link, /b.link4)";
	ops[7].rc = ntfsb_rename(v, NTFSB_ROOT_INO, "b.link",
		NTFSB_ROOT_INO, "b.link4");
	ops[8].what = "ntfsb_release(B)";
	ops[8].rc = ntfsb_release(v, bino);
	ops[9].what = "ntfsb_remove(/b.link2)";
	ops[9].rc = ntfsb_remove(v, NTFSB_ROOT_INO, "b.link2");
	ops[10].what = "ntfsb_set_label";
	ops[10].rc = ntfsb_set_label(v, "FlushFault");
	for (i = 0; i < (int)(sizeof(ops) / sizeof(ops[0])); i++) {
		char what[96];

		/* the injected error exactly: any other errno (ENOENT,
		 * EEXIST ...) would mean the call ran for the wrong
		 * reason */
		snprintf(what, sizeof(what), "%s returns -EIO", ops[i].what);
		ft_assert(id, what, ops[i].rc == -EIO, ft_rc(ops[i].rc));
	}
	fault_disarm();
	r = resolve(v, "/b.bin", &bino, &st);
	if (r) {
		ft_assert(id, "B resolves after the operations", 0, ft_rc(r));
	} else {
		snprintf(d, sizeof(d), "got %llu, want %llu",
			(unsigned long long)st.size,
			(unsigned long long)st0.size);
		ft_assert(id, "B untouched: size", st.size == st0.size, d);
		snprintf(d, sizeof(d), "got %u, want %u", st.nlink, st0.nlink);
		ft_assert(id, "B untouched: link count", st.nlink == st0.nlink, d);
		snprintf(d, sizeof(d), "got %lld", (long long)st.mtime.tv_sec);
		ft_assert(id, "B untouched: mtime",
			st.mtime.tv_sec == FT_T0, d);
		snprintf(d, sizeof(d), "got 0x%x, want 0x%x", st.ntfs_attrs,
			st0.ntfs_attrs);
		ft_assert(id, "B untouched: attributes",
			st.ntfs_attrs == st0.ntfs_attrs, d);
	}
	ft_assert(id, "the target range saw at least one failed write",
		g_fault.failures > 0,
		ft_ll("failures", (long long)g_fault.failures));
	/* every operation was refused, so nothing they would have created
	 * may exist either, and what they would have changed is intact */
	ft_assert_absent(v, id, "/c.bin");
	ft_assert_absent(v, id, "/b3.link");
	ft_assert_absent(v, id, "/b.link4");
	r = resolve(v, "/b.link", &ino, &st);
	snprintf(d, sizeof(d), "lookup /b.link: %s", ft_rc(r));
	ft_assert(id, "the rename source still exists", r == 0, d);
	r = resolve(v, "/b.link2", &ino, &st);
	snprintf(d, sizeof(d), "lookup /b.link2: %s", ft_rc(r));
	ft_assert(id, "the remove target still exists", r == 0, d);
	xa = ntfsb_getxattr(v, bino, "flushtest.xattr", xbuf, sizeof(xbuf) - 1);
	snprintf(d, sizeof(d), "got %lld bytes", (long long)xa);
	ft_assert(id, "B keeps its original xattr",
		xa == 4 && !memcmp(xbuf, "orig", 4), d);
	ntfsb_get_info(v, &info);
	snprintf(d, sizeof(d), "got label '%s'", info.label);
	ft_assert(id, "the volume label is unchanged",
		!strcmp(info.label, "FlushErr"), d);
	/* unmount result is not asserted: with the fix it reports the still
	 * failing flush, the old code drops it. */
	ur = ntfsb_unmount(v);
	(void)ur;
	return ft_done(id);
}

/* T5: a stored EIO outranks the newer ENOSPC of the same sync. */
static int ft_t5(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t5";
	int64_t rs, re;
	uint64_t aino, bino;
	int rb, r1, r2, r3, ur;

	(void)dev;
	if (ft_setup2(v, 0x090909, 0x080808, &aino, &bino)
	    || ft_target(id, aino, &rs, &re))
		return 1;
	/* first failure: EIO while flushing A, recorded by set_times on B */
	ft_arm(id, rs, re, EIO, 1, 1);
	rb = ft_set_times(v, bino, FT_T1);
	/* second failure: ENOSPC when the boundary sync retries the flush */
	ft_arm(id, rs, re, ENOSPC, 1, 1);
	r1 = ntfsb_sync(v);
	r2 = ntfsb_sync(v);
	r3 = ntfsb_sync(v);
	ft_assert(id, "set_times on B returns -EIO and files EIO in the "
		"error ledger", rb == -EIO, ft_rc(rb));
	ft_assert(id, "first ntfsb_sync reports the stored EIO, not the new "
		"ENOSPC", r1 == -EIO, ft_rc(r1));
	ft_assert(id, "second ntfsb_sync reports ENOSPC", r2 == -ENOSPC,
		ft_rc(r2));
	ft_assert(id, "third ntfsb_sync returns 0", r3 == 0, ft_rc(r3));
	ft_assert(id, "the target range saw at least one failed write",
		g_fault.failures > 0,
		ft_ll("failures", (long long)g_fault.failures));
	ft_verify(v, id, "/a.bin", 256, 0x090909);
	ur = ntfsb_unmount(v);
	ft_assert(id, "final unmount returns 0", ur == 0, ft_rc(ur));
	return ft_done(id);
}

/* T6: the preallocated surplus of a non-resident file is given back by
 * the flush. Needs a 256 MiB image:
 * the write cache only preallocates when the volume has more than four
 * times the preallocation free. */
#define FT_T6_CHUNK (64 * 1024)

static int ft_t6(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t6";
	unsigned char *p1, *p2, *buf;
	uint32_t sector, cluster, mrs;
	uint64_t ino, rounded;
	int64_t mft_off, rs, re;
	ntfsb_stat st;
	char d[96];
	int r, r1, r2, ur, ok;

	p1 = malloc(FT_T6_CHUNK);
	p2 = malloc(FT_T6_CHUNK);
	buf = malloc(FT_T6_CHUNK);
	if (!p1 || !p2 || !buf) {
		fprintf(stderr, "flushtest: out of memory\n");
		free(p1); free(p2); free(buf);
		return 1;
	}
	ft_pattern(p1, FT_T6_CHUNK, 0x0a0a0a);
	ft_pattern(p2, FT_T6_CHUNK, 0x0b0b0b);
	/* two writes: the second grows the file past the resident limit and
	 * the bridge allocates ahead of it */
	r = ntfsb_create(v, NTFSB_ROOT_INO, "a.bin", S_IFREG, &st);
	if (!r && ntfsb_write(v, st.ino, p1, FT_T6_CHUNK, 0) != FT_T6_CHUNK)
		r = -EIO;
	if (!r && ntfsb_write(v, st.ino, p2, FT_T6_CHUNK, FT_T6_CHUNK)
			!= FT_T6_CHUNK)
		r = -EIO;
	if (r || boot_geometry(&sector, &cluster, &mrs, &mft_off)) {
		fprintf(stderr, "flushtest t6: setup failed\n");
		free(p1); free(p2); free(buf);
		return 1;
	}
	ino = st.ino;
	ino_record_range(mft_off, mrs, ino, &rs, &re);
	printf("[%s] geometry: sector %u cluster %u mft_record %u; target "
		"ino %llu mft_record %lld..%lld\n", id, sector, cluster, mrs,
		(unsigned long long)ino, (long long)rs, (long long)re);
	r = ntfsb_getattr(v, ino, &st);
	rounded = ((uint64_t)2 * FT_T6_CHUNK + cluster - 1) & ~(uint64_t)(cluster - 1);
	if (r) {
		ft_assert(id, "stat of A after the writes", 0, ft_rc(r));
	} else {
		snprintf(d, sizeof(d), "got %llu",
			(unsigned long long)st.size);
		ft_assert(id, "A has the written size",
			st.size == (uint64_t)2 * FT_T6_CHUNK, d);
		snprintf(d, sizeof(d), "alloc %llu, cluster-rounded size %llu",
			(unsigned long long)st.alloc_size,
			(unsigned long long)rounded);
		/* proves the surplus exists, so the sync really takes the
	 * trim path */
		ft_assert(id, "A is over-allocated before the sync",
			st.alloc_size > rounded, d);
	}
	ft_arm(id, rs, re, EIO, 1, 0);
	r1 = ntfsb_sync(v);
	r2 = ntfsb_sync(v);
	ur = ntfsb_unmount(v);
	ft_assert(id, "first ntfsb_sync returns -EIO", r1 == -EIO, ft_rc(r1));
	ft_assert(id, "the target range saw at least one failed write",
		g_fault.failures > 0,
		ft_ll("failures", (long long)g_fault.failures));
	ft_assert(id, "second ntfsb_sync returns 0", r2 == 0, ft_rc(r2));
	ft_assert(id, "unmount after the successful retry returns 0",
		ur == 0, ft_rc(ur));
	fault_disarm();
	v = ft_remount(dev);
	ft_assert(id, "image remounts", v != NULL, v ? "" : "mount failed");
	if (v) {
		r = resolve(v, "/a.bin", &ino, &st);
		if (r) {
			ft_assert(id, "A resolves after remount", 0, ft_rc(r));
		} else {
			snprintf(d, sizeof(d), "got %llu",
				(unsigned long long)st.size);
			ft_assert(id, "A size survived",
				st.size == (uint64_t)2 * FT_T6_CHUNK, d);
			snprintf(d, sizeof(d), "alloc %llu, want %llu",
				(unsigned long long)st.alloc_size,
				(unsigned long long)rounded);
			ft_assert(id, "surplus trimmed to the cluster-rounded "
				"size", st.alloc_size == rounded, d);
		}
		ok = !r;
		if (!r && ntfsb_read(v, ino, buf, FT_T6_CHUNK, 0)
				!= FT_T6_CHUNK)
			ok = 0;
		if (ok && memcmp(buf, p1, FT_T6_CHUNK))
			ok = 0;
		if (ok && ntfsb_read(v, ino, buf, FT_T6_CHUNK, FT_T6_CHUNK)
				!= FT_T6_CHUNK)
			ok = 0;
		if (ok && memcmp(buf, p2, FT_T6_CHUNK))
			ok = 0;
		ft_assert(id, "A content survived", ok,
			ok ? "" : "read back mismatch");
		ur = ntfsb_unmount(v);
		ft_assert(id, "final unmount returns 0", ur == 0, ft_rc(ur));
	}
	free(p1);
	free(p2);
	free(buf);
	return ft_done(id);
}

/*
 * Shared population of t7/t7b/t10: /d with 60 filler files (its $I30
 * index grows into a non-resident allocation) and /d/a.bin with 4096
 * bytes, whose directory entry must be updated when the write cache is
 * flushed. The last file written stays dirty in the write cache.
 */
static int ft_t7_populate(ntfsb_volume *v, uint64_t *dino, uint64_t *aino)
{
	ntfsb_stat st;
	char name[16];
	int r, i;

	r = ntfsb_create(v, NTFSB_ROOT_INO, "d", S_IFDIR, &st);
	if (r) {
		fprintf(stderr, "flusftest: mkdir /d failed: %s\n", strerror(-r));
		return -1;
	}
	*dino = st.ino;
	for (i = 0; i < 60; i++) {
		snprintf(name, sizeof(name), "f%02d", i);
		if (ft_make_file_at(v, *dino, name, 10, 0x100 + i, aino)) {
			fprintf(stderr, "flusftest: filler setup failed\n");
			return -1;
		}
	}
	r = ntfsb_create(v, *dino, "a.bin", S_IFREG, &st);
	if (r) {
		fprintf(stderr, "flusftest: a.bin setup failed: %s\n",
			strerror(-r));
		return -1;
	}
	*aino = st.ino;
	for (i = 0; i < 8; i++) {
		unsigned char piece[512];

		ft_pattern(piece, sizeof(piece), 0x0d0d0d + i);
		if (ntfsb_write(v, *aino, piece, sizeof(piece),
				(int64_t)i * 512) != 512) {
			fprintf(stderr, "flusftest: a.bin write failed\n");
			return -1;
		}
	}
	return 0;
}

/*
 * t7/t7b setup: the population plus the committed $I30 index allocation
 * range, read through the independent read-only helper mount.
 */
static int ft_t7_setup(ntfsb_volume *v, uint64_t *dino, uint64_t *aino,
		int64_t *rs, int64_t *re)
{
	ntfs_volume *h;
	ntfs_inode *dni;
	ntfs_attr *na;
	int r;

	if (ft_t7_populate(v, dino, aino))
		return -1;

	/* the committed index allocation range, through the independent
	 * read-only helper mount (nothing is hardcoded) */
	h = helper_mount();
	if (!h)
		return -1;
	dni = ntfs_inode_open(h, *dino);
	na = dni ? ntfs_attr_open(dni, AT_INDEX_ALLOCATION, NTFS_INDEX_I30, 4)
		 : NULL;
	if (!na) {
		fprintf(stderr, "flusftest: $I30 has no non-resident "
			"index allocation\n");
		if (dni)
			ntfs_inode_close(dni);
		helper_umount(h);
		return -1;
	}
	r = attr_data_range(na, rs, re);
	ntfs_attr_close(na);
	ntfs_inode_close(dni);
	helper_umount(h);
	if (r) {
		fprintf(stderr, "flusftest: the index allocation range is "
			"fragmented\n");
		return -1;
	}
	return 0;
}

/*
 * Reads the data_size recorded in /d's directory entry for a.bin and
 * whether that entry lives in a non-resident index block.
 */
static int ft_t7_dir_entry(uint64_t dino, int64_t *entry_size,
		int *in_allocation)
{
	ntfs_volume *h;
	ntfs_inode *dni;
	ntfs_index_context *icx = NULL;
	ntfschar *uname = NULL;
	int ulen = 0;

	*entry_size = -1;
	*in_allocation = 0;
	h = helper_mount();
	if (!h)
		return -1;
	dni = ntfs_inode_open(h, dino);
	if (dni) {
		ulen = ntfs_mbstoucs("a.bin", &uname);
		if (ulen >= 0)
			icx = ntfs_index_ctx_get(dni, NTFS_INDEX_I30, 4);
	}
	/* the lookup key for COLLATION_FILE_NAME is a FILE_NAME_ATTR */
	if (icx && uname && ulen > 0 && (size_t)ulen <= NTFS_MAX_NAME_LEN) {
		unsigned char keybuf[128];
		FILE_NAME_ATTR *key = (FILE_NAME_ATTR *)keybuf;

		memset(keybuf, 0, sizeof(keybuf));
		key->file_name_length = ulen;
		memcpy(key->file_name, uname, ulen * sizeof(ntfschar));
		if (ntfs_index_lookup((char *)key, ulen, icx) == 0
		    && icx->data_len >= sizeof(FILE_NAME_ATTR)) {
			FILE_NAME_ATTR *fn = (FILE_NAME_ATTR *)icx->data;

			*entry_size = sle64_to_cpu(fn->data_size);
			*in_allocation = !icx->is_in_root;
		}
	}
	if (icx)
		ntfs_index_ctx_put(icx);
	if (dni)
		ntfs_inode_close(dni);
	free(uname);
	helper_umount(h);
	return 0;
}

/* T7: one write into the non-resident $I30 allocation fails during
 * the first sync; the swallowed failure must still fail the sync and the
 * retry must update the directory entry. The entry is verified after the
 * second sync, before the unmount. */
static int ft_t7(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t7";
	int64_t rs, re, entry_size;
	uint64_t dino, aino;
	char d[96];
	int r1, r2, ur, in_allocation = 0;

	(void)dev;
	if (ft_t7_setup(v, &dino, &aino, &rs, &re))
		return 1;
	printf("[%s] target: /d $I30 index allocation %lld..%lld\n", id,
		(long long)rs, (long long)re);

	ft_arm(id, rs, re, EIO, 1, 0);
	r1 = ntfsb_sync(v);
	r2 = ntfsb_sync(v);
	ft_assert(id, "first ntfsb_sync returns an error (the failed index "
		"write is not swallowed)", r1 == -EIO, ft_rc(r1));
	ft_assert(id, "the index allocation saw a failed write",
		g_fault.failures > 0,
		ft_ll("failures", (long long)g_fault.failures));
	ft_assert(id, "second ntfsb_sync returns 0", r2 == 0, ft_rc(r2));
	/* verify while the bridge volume is still mounted */
	if (ft_t7_dir_entry(dino, &entry_size, &in_allocation))
		return 1;
	snprintf(d, sizeof(d), "dir entry size %lld, want 4096",
		(long long)entry_size);
	ft_assert(id, "the directory entry carries the written size",
		entry_size == 4096, d);
	ft_assert(id, "the entry lives in a non-resident index block",
		in_allocation, in_allocation ? "" : "in the index root");
	ur = ntfsb_unmount(v);
	fault_disarm();
	ft_assert(id, "unmount returns 0", ur == 0, ft_rc(ur));
	return ft_done(id);
}

/* T7b: in one sync BOTH the $I30 index write and the file's MFT
 * record write fail once. The sync reports the error, but its FILE_NAME
 * dirty mark is already cleared; a retry that only rewrites the MFT
 * record would lose the directory entry update. */
static int ft_t7b(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t7b";
	uint32_t sector, cluster, mrs;
	int64_t mft_off, is, ie, ars, are, entry_size;
	uint64_t dino, aino;
	char d[96];
	int r1, r2, ur, in_allocation = 0;

	(void)dev;
	if (ft_t7_setup(v, &dino, &aino, &is, &ie)
	    || boot_geometry(&sector, &cluster, &mrs, &mft_off))
		return 1;
	ino_record_range(mft_off, mrs, aino, &ars, &are);
	printf("[%s] targets: /d $I30 allocation %lld..%lld, a.bin record "
		"%lld..%lld\n", id, (long long)is, (long long)ie,
		(long long)ars, (long long)are);

	ft_arm(id, is, ie, EIO, 1, 0);
	fault_arm_at(&g_fault2, ars, are, EIO, 1);
	printf("[%s] injection armed: range [%lld,%lld) errno %d mode once\n",
		id, (long long)ars, (long long)are, EIO);
	r1 = ntfsb_sync(v);
	r2 = ntfsb_sync(v);
	ft_assert(id, "first ntfsb_sync returns -EIO (both writes failed)",
		r1 == -EIO, ft_rc(r1));
	ft_assert(id, "the index allocation write failed exactly once",
		g_fault.failures == 1,
		ft_ll("failures", (long long)g_fault.failures));
	ft_assert(id, "the MFT record write failed exactly once",
		g_fault2.failures == 1,
		ft_ll("failures", (long long)g_fault2.failures));
	ft_assert(id, "the sync after the faults cleared returns 0",
		r2 == 0, ft_rc(r2));
	if (ft_t7_dir_entry(dino, &entry_size, &in_allocation))
		return 1;
	snprintf(d, sizeof(d), "dir entry size %lld, want 4096",
		(long long)entry_size);
	ft_assert(id, "the retry updated the directory entry too",
		entry_size == 4096, d);
	ft_assert(id, "the entry lives in a non-resident index block",
		in_allocation, in_allocation ? "" : "in the index root");
	ur = ntfsb_unmount(v);
	fault_disarm();
	ft_assert(id, "unmount returns 0", ur == 0, ft_rc(ur));
	return ft_done(id);
}


/* T8: a failure while trimming the preallocation leaves bitmap,
 * runlist and attribute sizes partially updated, so the trim is not
 * retryable. One $Bitmap write is failed during the trim; afterwards
 * the volume must fail closed until it is unmounted (and marked dirty). */
static int ft_t8(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t8";
	unsigned char chunk[FT_T6_CHUNK];
	ntfs_volume *h;
	ntfs_inode *bni;
	ntfs_attr *na;
	int64_t rs, re;
	uint64_t ino;
	ntfsb_stat st;
	char d[96];
	int r, r1, r2, rm, ur, dirty = 0, clean0 = 0;
	int64_t w;
	unsigned long nw1, nw2;

	(void)dev;
	/* two writes like t6: the second triggers the preallocation */
	ft_pattern(chunk, sizeof(chunk), 0x0e0e0e);
	r = ntfsb_create(v, NTFSB_ROOT_INO, "a.bin", S_IFREG, &st);
	if (!r && ntfsb_write(v, st.ino, chunk, sizeof(chunk), 0)
			!= (int64_t)sizeof(chunk))
		r = -EIO;
	if (!r && ntfsb_write(v, st.ino, chunk, sizeof(chunk),
				(int64_t)sizeof(chunk)) != (int64_t)sizeof(chunk))
		r = -EIO;
	if (r) {
		fprintf(stderr, "flushtest t8: setup failed\n");
		return 1;
	}
	ino = st.ino;

	/* the volume must start clean, so the dirty check at the end
	 * proves the unmount marked it */
	h = helper_mount();
	if (!h)
		return 1;
	clean0 = (h->flags & VOLUME_IS_DIRTY) == 0;
	helper_umount(h);
	ft_assert(id, "the volume is not dirty before the injection",
		clean0, clean0 ? "" : "VOLUME_IS_DIRTY already set");

	/* the $Bitmap data range (written first when the trim frees the
	 * preallocated clusters) */
	h = helper_mount();
	if (!h)
		return 1;
	bni = ntfs_inode_open(h, FILE_Bitmap);
	na = bni ? ntfs_attr_open(bni, AT_DATA, AT_UNNAMED, 0) : NULL;
	if (!na) {
		fprintf(stderr, "flushtest t8: cannot open $Bitmap\n");
		if (bni)
			ntfs_inode_close(bni);
		helper_umount(h);
		return 1;
	}
	r = attr_data_range(na, &rs, &re);
	ntfs_attr_close(na);
	ntfs_inode_close(bni);
	helper_umount(h);
	if (r) {
		fprintf(stderr, "flushtest t8: $Bitmap is fragmented\n");
		return 1;
	}
	printf("[%s] target: $Bitmap data %lld..%lld\n", id,
		(long long)rs, (long long)re);

	ft_arm(id, rs, re, EIO, 1, 0);
	r1 = ntfsb_sync(v);
	/* from fail-closed to just before the unmount not a single device
	 * write may happen (the unmount's abandon path and dirty marking
	 * are not counted) */
	nw1 = g_nw;
	r2 = ntfsb_sync(v);
	rm = ntfsb_create(v, NTFSB_ROOT_INO, "m", S_IFDIR, &st);
	w = ntfsb_write(v, ino, chunk, sizeof(chunk),
		(int64_t)2 * sizeof(chunk));
	nw2 = g_nw;
	ur = ntfsb_unmount(v);
	fault_disarm();
	ft_assert(id, "the trim itself reports -EIO", r1 == -EIO, ft_rc(r1));
	ft_assert(id, "the target range saw a failed write",
		g_fault.failures > 0,
		ft_ll("failures", (long long)g_fault.failures));
	ft_assert(id, "the next ntfsb_sync still returns -EIO (fail closed)",
		r2 == -EIO, ft_rc(r2));
	ft_assert(id, "a modifying operation returns -EIO",
		rm == -EIO, ft_rc(rm));
	snprintf(d, sizeof(d), "got %lld", (long long)w);
	ft_assert(id, "ntfsb_write returns -EIO", w == -EIO, d);
	snprintf(d, sizeof(d), "got %lu writes", nw2 - nw1);
	ft_assert(id, "no device write happens while fail-closed",
		nw2 == nw1, d);
	ft_assert(id, "unmount returns -EIO", ur == -EIO, ft_rc(ur));

	/* the volume must be marked dirty for Windows' chkdsk; the helper
	 * mount is read-only, so it cannot change the flag itself */
	h = helper_mount();
	if (h) {
		dirty = (h->flags & VOLUME_IS_DIRTY) != 0;
		helper_umount(h);
	}
	snprintf(d, sizeof(d), "VOLUME_IS_DIRTY is %d", dirty);
	ft_assert(id, "the volume is marked dirty after remount",
		dirty, d);
	return ft_done(id);
}

/* T9: the release of a file whose inode is not cached reads its
 * MFT record. One read failure during that release must reach the C
 * ledger, so the next ntfsb_sync reports it. */
static int ft_t9(ntfsb_device *dev, ntfsb_volume *v)
{
	const char *id = "t9";
	int64_t rs, re;
	uint64_t ino, xino;
	char name[16];
	int i, rr, r1, r2, ur;

	(void)dev;
	if (ft_make_file(v, "a.bin", 256, 0x0f0f0f, &ino)
	    || ft_target(id, ino, &rs, &re))
		return 1;
	/* flush a.bin into the inode cache, then push it out again with
	 * more than CACHE_NIDATA_SIZE (64) other closes */
	if (ntfsb_sync(v)) {
		fprintf(stderr, "flusftest t9: setup sync failed\n");
		return 1;
	}
	for (i = 0; i < 70; i++) {
		snprintf(name, sizeof(name), "r%02d", i);
		if (ft_make_file(v, name, 10, 0x200 + i, &xino)) {
			fprintf(stderr, "flusftest t9: filler setup failed\n");
			return 1;
		}
	}
	if (ntfsb_sync(v)) {
		fprintf(stderr, "flusftest t9: filler sync failed\n");
		return 1;
	}

	/* one read failure when the release opens a.bin's record */
	fault_arm_at(&g_fault_rd, rs, re, EIO, 1);
	printf("[%s] read injection armed: range [%lld,%lld) errno %d "
		"mode once\n", id, (long long)rs, (long long)re, EIO);
	rr = ntfsb_release(v, ino);
	r1 = ntfsb_sync(v);
	r2 = ntfsb_sync(v);
	ur = ntfsb_unmount(v);
	fault_disarm();
	ft_assert(id, "the release itself returns -EIO", rr == -EIO,
		ft_rc(rr));
	ft_assert(id, "the record read failed exactly once",
		g_fault_rd.failures == 1,
		ft_ll("failures", (long long)g_fault_rd.failures));
	ft_assert(id, "the next ntfsb_sync reports the release error",
		r1 == -EIO, ft_rc(r1));
	ft_assert(id, "and only once", r2 == 0, ft_rc(r2));
	ft_assert(id, "unmount returns 0", ur == 0, ft_rc(ur));
	return ft_done(id);
}

/* ------------------------------------------------- t10: unaligned writes
 *
 * With a mount-time device I/O granularity larger than the $I30 index
 * block (NTFSTOOL_IO_ALIGN), the index block writeback of the flush is
 * an unaligned write: bdev_pwrite() read-modify-writes the surrounding
 * units, and a failure of that PREFETCH READ never reaches the device
 * as a write while ntfs_index_ctx_put() discards the write error
 * anyway. Only the bridge's write error ledger can report it.
 *
 * Two passes with identical operation sequences on identical images:
 *
 *   record pass (on a copy of the image, no injection): locate the one
 *   read-modify-write of the first sync that covers the target index
 *   block, by its shape in the device I/O trace, and note the trace
 *   position of its prefetch read;
 *
 *   formal pass (on the original image): the injector fails exactly
 *   that prefetch read. The traces must agree everywhere else, which
 *   also bounds the read-modify-write: none of it may run after the
 *   failed read.
 */
struct ft_rmw {
	unsigned long k;      /* trace position of the prefetch read */
	int nent;             /* device ops of the read-modify-write */
	int64_t start, end;   /* device range it covers */
};

/* Find read-modify-writes in trace range [s0, s1): the unaligned write
 * of [start, end) appears as read(start, ss) -> write(start,
 * end - start), preceded by read(end - ss, ss) when it spans two
 * units. Those covering [rs, re) are counted; *out receives the last
 * one found. A plain lookup read has the same shape as a prefetch
 * read; only the immediately following write tells them apart. */
static void ft_find_rmw(unsigned long s0, unsigned long s1, int64_t ss,
		int64_t rs, int64_t re, struct ft_rmw *out, int *count)
{
	unsigned long i;
	int n = 0;

	for (i = s0; i + 1 < s1; i++) {
		struct io_ev *e = &g_ev[i];
		struct ft_rmw cand;

		if (e->type != 'R' || e->off % ss || e->len != ss)
			continue;
		if (g_ev[i + 1].type == 'W' && g_ev[i + 1].off == e->off
		    && g_ev[i + 1].len == ss) {
			cand.nent = 2;
			cand.start = e->off;
			cand.end = e->off + ss;
		} else if (i + 2 < s1 && g_ev[i + 1].type == 'R'
			   && g_ev[i + 1].off == e->off + ss
			   && g_ev[i + 1].len == ss
			   && g_ev[i + 2].type == 'W'
			   && g_ev[i + 2].off == e->off
			   && g_ev[i + 2].len == 2 * ss) {
			cand.nent = 3;
			cand.start = e->off;
			cand.end = e->off + 2 * ss;
		} else {
			continue;
		}
		cand.k = i + 1;
		if (cand.start <= rs && re <= cand.end) {
			n++;
			*out = cand;
		}
	}
	*count = n;
}

static void ft_print_trace(const char *id, const char *what,
		unsigned long s0, unsigned long s1)
{
	unsigned long i;

	printf("[%s] %s:\n", id, what);
	for (i = s0; i < s1; i++)
		printf("[%s]   IO %lu %c %lld +%lld => %lld\n", id, i + 1,
			g_ev[i].type, (long long)g_ev[i].off,
			(long long)g_ev[i].len, (long long)g_ev[i].ret);
}

static int ft_copy_image(const char *src, const char *dst)
{
	int in = open(src, O_RDONLY), out = -1, r = -1;
	char buf[65536];

	if (in < 0)
		return -1;
	out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0)
		goto out;
	for (;;) {
		ssize_t n = read(in, buf, sizeof(buf)), w = 0;

		if (n < 0)
			goto out;
		if (!n)
			break;
		while (w < n) {
			ssize_t m = write(out, buf + w, n - w);

			if (m < 0)
				goto out;
			w += m;
		}
	}
	r = 0;
out:
	if (in >= 0)
		close(in);
	if (out >= 0)
		close(out);
	return r;
}

/* Point the device callbacks and the helper mount at another image
 * file with the same content (the record pass works on a copy). */
static int ft_image_swap(const char *path)
{
	int nfd = open(path, O_RDWR);

	if (nfd < 0)
		return -1;
	if (g_fd >= 0)
		close(g_fd);
	g_fd = nfd;
	g_image = path;
	return 0;
}

/* Physical device range of the non-resident index block carrying /d's
 * directory entry for a.bin, computed through the read-only helper
 * mount: the flush must rewrite exactly this block. */
static int ft_t10_block_range(uint64_t dino, int64_t *start, int64_t *end)
{
	ntfs_volume *h;
	ntfs_inode *dni;
	ntfs_attr *na = NULL;
	ntfs_index_context *icx = NULL;
	ntfschar *uname = NULL;
	unsigned char keybuf[128];
	FILE_NAME_ATTR *key;
	runlist_element *rl;
	s64 cs, inpos;
	int ulen = 0, r = -1;

	h = helper_mount();
	if (!h)
		return -1;
	dni = ntfs_inode_open(h, dino);
	na = dni ? ntfs_attr_open(dni, AT_INDEX_ALLOCATION, NTFS_INDEX_I30, 4)
		 : NULL;
	if (!na) {
		fprintf(stderr, "flusftest: $I30 has no non-resident "
			"index allocation\n");
		goto out;
	}
	ulen = ntfs_mbstoucs("a.bin", &uname);
	if (ulen < 0)
		goto out;
	icx = ntfs_index_ctx_get(dni, NTFS_INDEX_I30, 4);
	/* the lookup key for COLLATION_FILE_NAME is a FILE_NAME_ATTR */
	if (!icx)
		goto out;
	key = (FILE_NAME_ATTR *)keybuf;
	memset(keybuf, 0, sizeof(keybuf));
	key->file_name_length = ulen;
	memcpy(key->file_name, uname, ulen * sizeof(ntfschar));
	if (ntfs_index_lookup((char *)key, ulen, icx) || icx->is_in_root
	    || !icx->ib) {
		fprintf(stderr, "flusftest: the a.bin directory entry is "
			"not in a non-resident index block\n");
		goto out;
	}
	/* byte position of the block inside the index allocation */
	inpos = (s64)sle64_to_cpu(icx->ib->index_block_vcn)
		<< icx->vcn_size_bits;
	cs = h->cluster_size;
	if (ntfs_attr_map_whole_runlist(na))
		goto out;
	for (rl = na->rl; rl && rl->length; rl++) {
		if (rl->lcn < 0)
			continue;
		if (inpos / cs >= rl->vcn && inpos / cs < rl->vcn + rl->length) {
			*start = (rl->lcn + (inpos / cs - rl->vcn)) * cs
				+ inpos % cs;
			*end = *start + (s64)icx->block_size;
			r = 0;
			break;
		}
	}
out:
	if (icx)
		ntfs_index_ctx_put(icx);
	free(uname);
	if (na)
		ntfs_attr_close(na);
	if (dni)
		ntfs_inode_close(dni);
	helper_umount(h);
	return r;
}

/* Verify /d/a.bin through the bridge: size and the eight written
 * pieces, before the unmount and again after a remount. */
static void ft_t10_content(ntfsb_volume *v, const char *id, const char *when)
{
	unsigned char want[4096], got[4096];
	ntfsb_stat st;
	uint64_t ino;
	char what[96], d[64];
	int i, ok = 1, r;

	for (i = 0; i < 8; i++)
		ft_pattern(want + i * 512, 512, 0x0d0d0d + i);
	r = resolve(v, "/d/a.bin", &ino, &st);
	snprintf(what, sizeof(what), "a.bin resolves (%s)", when);
	ft_assert(id, what, r == 0, ft_rc(r));
	if (r)
		return;
	snprintf(d, sizeof(d), "got %llu", (unsigned long long)st.size);
	snprintf(what, sizeof(what), "a.bin has the written size (%s)", when);
	ft_assert(id, what, st.size == 4096, d);
	if (ntfsb_read(v, ino, got, 4096, 0) != 4096
	    || memcmp(got, want, 4096))
		ok = 0;
	snprintf(what, sizeof(what), "a.bin content survived (%s)", when);
	ft_assert(id, what, ok, ok ? "" : "read back mismatch");
}

/* mode 0 = t10a: the prefetch read fails with -EIO.
 * mode 1 = t10c: the prefetch read returns 0 bytes with a residual
 *                ENOENT (short read).
 * mode 2 = t10r: record pass only (the reachability check). */
static int ft_t10(ntfsb_device *dev, ntfsb_volume *v, const char *id,
		int mode)
{
	const int64_t ss = (int64_t)dev->sector_size;
	struct ft_rmw rmw;
	struct io_ev *recseg, *recpre;
	const char *orig = g_image;
	char recpath[4096], d[96];
	uint64_t dino, aino;
	ntfsb_volume *w;
	int64_t rs, re, entry_size;
	unsigned long s0, s1, f0, f1, rp, j, m;
	int count, ur, in_allocation = 0, ok, r1, r2;

	/* both passes must start from identical bytes: unmount the volume
	 * main() mounted, then run the record pass on a copy */
	ur = ntfsb_unmount(v);
	ft_assert(id, "the initial mount unmounts cleanly", ur == 0,
		ft_rc(ur));
	snprintf(recpath, sizeof(recpath), "%s.rec", orig);
	if (ft_copy_image(orig, recpath)) {
		fprintf(stderr, "flusftest: cannot copy %s to %s\n", orig,
			recpath);
		return 1;
	}
	printf("[%s] device I/O granularity %lld; record pass on the copy "
		"%s\n", id, (long long)ss, recpath);

	/* ---- record pass ---- */
	if (ft_image_swap(recpath))
		return 1;
	io_trace_reset();
	w = ft_remount(dev);
	if (ft_t7_populate(w, &dino, &aino)
	    || ft_t10_block_range(dino, &rs, &re)) {
		ntfsb_unmount(w);
		return 1;
	}
	printf("[%s] target: /d $I30 index block of a.bin %lld..%lld "
		"(%lld bytes)\n", id, (long long)rs, (long long)re,
		(long long)(re - rs));
	s0 = g_nev;
	r1 = ntfsb_sync(w);
	s1 = g_nev;
	if (g_ev_overflow) {
		/* events past the buffer were not stored: no trace to compare */
		fprintf(stderr, "[%s] case not established: I/O trace overflow\n",
			id);
		return 1;
	}
	ft_assert(id, "the record sync returns 0", r1 == 0, ft_rc(r1));
	ok = !g_ev_overflow;
	for (j = 0; j < g_nev; j++)
		if (g_ev[j].ret != g_ev[j].len)
			ok = 0;
	ft_assert(id, "every record-pass transfer completes in one call",
		ok, ok ? "" : (g_ev_overflow ? "trace overflow" :
		"short transfer present"));
	ft_print_trace(id, "record: first sync device I/O", s0, s1);
	count = 0;
	ft_find_rmw(s0, s1, ss, rs, re, &rmw, &count);
	snprintf(d, sizeof(d), "found %d", count);
	ft_assert(id, "exactly one first-sync read-modify-write covers "
		"the target index block", count == 1, d);
	if (count != 1) {
		fprintf(stderr, "flusftest: no unique covering "
			"read-modify-write; is NTFSTOOL_IO_ALIGN larger "
			"than the index block?\n");
		ntfsb_unmount(w);
		return ft_done(id);
	}
	rp = rmw.k - 1 - s0;
	printf("[%s] read-modify-write covering the target: prefetch read "
		"at IO %lu (off %lld, len %lld), %d ops, range %lld..%lld\n",
		id, rmw.k, (long long)g_ev[rmw.k - 1].off,
		(long long)g_ev[rmw.k - 1].len, rmw.nent, (long long)rmw.start,
		(long long)rmw.end);
	/* keep what the formal pass compares against, before its trace
	 * replaces this one */
	recseg = malloc((s1 - s0) * sizeof(*recseg));
	recpre = malloc((rmw.k - 1) * sizeof(*recpre));
	if (!recseg || !recpre) {
		fprintf(stderr, "flusftest: out of memory\n");
		free(recseg);
		free(recpre);
		ntfsb_unmount(w);
		return 1;
	}
	memcpy(recseg, g_ev + s0, (s1 - s0) * sizeof(*recseg));
	memcpy(recpre, g_ev, (rmw.k - 1) * sizeof(*recpre));
	ur = ntfsb_unmount(w);
	ft_assert(id, "the record pass unmounts cleanly", ur == 0,
		ft_rc(ur));
	if (mode == 2) {
		free(recseg);
		free(recpre);
		return ft_done(id);
	}

	/* ---- formal pass ---- */
	if (ft_image_swap(orig)) {
		free(recseg);
		free(recpre);
		return 1;
	}
	io_trace_reset();
	w = ft_remount(dev);
	if (ft_t7_populate(w, &dino, &aino)) {
		ntfsb_unmount(w);
		free(recseg);
		free(recpre);
		return 1;
	}
	g_fault_k.armed = 1;
	g_fault_k.k = rmw.k;
	g_fault_k.is_read = 1;
	g_fault_k.off = recseg[rp].off;
	g_fault_k.len = recseg[rp].len;
	g_fault_k.short_read = (mode == 1);
	g_fault_k.hits = 0;
	g_fault_k.mismatch = 0;
	printf("[%s] injection armed: IO %lu R %lld +%lld -> %s\n", id,
		rmw.k, (long long)recseg[rp].off, (long long)recseg[rp].len,
		mode ? "0 bytes (short read, residual ENOENT)" : "-EIO");
	f0 = g_nev;
	r1 = ntfsb_sync(w);
	f1 = g_nev;
	if (g_ev_overflow) {
		fprintf(stderr, "[%s] case not established: I/O trace overflow\n",
			id);
		return 1;
	}

	/* the formal pass must repeat the recorded I/O up to the read */
	ok = 1;
	for (j = 0; j + 1 < rmw.k; j++)
		if (g_ev[j].type != recpre[j].type
		    || g_ev[j].off != recpre[j].off
		    || g_ev[j].len != recpre[j].len)
			ok = 0;
	ft_assert(id, "the formal pass repeats the recorded I/O up to the "
		"failed read", ok, ok ? "" : "trace prefix differs");
	snprintf(d, sizeof(d), "hits %d, mismatch %d", g_fault_k.hits,
		g_fault_k.mismatch);
	ft_assert(id, "the recorded prefetch read failed exactly once",
		g_fault_k.hits == 1 && !g_fault_k.mismatch, d);
	/* expected first-sync trace: the record trace minus the part of
	 * the read-modify-write after the failed read */
	ok = (f1 - f0 == (s1 - s0) - (rmw.nent - 1));
	m = 0;
	for (j = 0; j < s1 - s0 && ok; j++) {
		if (j > rp && j < rp + rmw.nent)
			continue;
		if (m >= f1 - f0
		    || g_ev[f0 + m].type != recseg[j].type
		    || g_ev[f0 + m].off != recseg[j].off
		    || g_ev[f0 + m].len != recseg[j].len)
			ok = 0;
		else
			m++;
	}
	if (m != f1 - f0)
		ok = 0;
	snprintf(d, sizeof(d), "formal %lu ops, record %lu ops",
		f1 - f0, s1 - s0);
	ft_assert(id, "the first-sync trace equals the record trace minus "
		"the tail of the failed read-modify-write", ok, d);
	snprintf(d, sizeof(d), "got %lld", (long long)g_ev[rmw.k - 1].ret);
	ft_assert(id, mode ? "the failed read returned 0 bytes"
			 : "the failed read returned -EIO",
		g_ev[rmw.k - 1].ret == (mode ? 0 : -EIO), d);
	ok = 1;
	for (j = f0; j < f1; j++)
		if (j != rmw.k - 1 && g_ev[j].ret != g_ev[j].len)
			ok = 0;
	ft_assert(id, "every other formal transfer completes in one call",
		ok, ok ? "" : "short transfer present");

	r2 = ntfsb_sync(w);
	ft_assert(id, mode ? "the first ntfsb_sync returns -EIO (not the "
		"residual ENOENT)" : "the first ntfsb_sync returns -EIO",
		r1 == -EIO, ft_rc(r1));
	ft_assert(id, "the second ntfsb_sync returns 0", r2 == 0,
		ft_rc(r2));
	if (ft_t7_dir_entry(dino, &entry_size, &in_allocation)) {
		ntfsb_unmount(w);
		free(recseg);
		free(recpre);
		return 1;
	}
	snprintf(d, sizeof(d), "dir entry size %lld, want 4096",
		(long long)entry_size);
	ft_assert(id, "after the second sync the directory entry carries "
		"the written size", entry_size == 4096, d);
	ft_assert(id, "the entry lives in a non-resident index block",
		in_allocation, in_allocation ? "" : "in the index root");
	ft_t10_content(w, id, "before unmount");
	ur = ntfsb_unmount(w);
	ft_assert(id, "unmount returns 0", ur == 0, ft_rc(ur));
	w = ft_remount(dev);
	if (ft_t7_dir_entry(dino, &entry_size, &in_allocation)) {
		ntfsb_unmount(w);
		free(recseg);
		free(recpre);
		return 1;
	}
	snprintf(d, sizeof(d), "dir entry size %lld, want 4096",
		(long long)entry_size);
	ft_assert(id, "after the remount the directory entry still carries "
		"the written size", entry_size == 4096, d);
	ft_t10_content(w, id, "after remount");
	ur = ntfsb_unmount(w);
	ft_assert(id, "final unmount returns 0", ur == 0, ft_rc(ur));
	free(recseg);
	free(recpre);
	return ft_done(id);
}

static int flushtest(ntfsb_device *dev, ntfsb_volume *v, const char *name)
{
	if (!strcmp(name, "t1"))
		return ft_t1(dev, v);
	if (!strcmp(name, "t2"))
		return ft_t2(dev, v);
	if (!strcmp(name, "t3"))
		return ft_t3(dev, v);
	if (!strcmp(name, "t4"))
		return ft_t4(dev, v);
	if (!strcmp(name, "t5"))
		return ft_t5(dev, v);
	if (!strcmp(name, "t6"))
		return ft_t6(dev, v);
	if (!strcmp(name, "t7"))
		return ft_t7(dev, v);
	if (!strcmp(name, "t8"))
		return ft_t8(dev, v);
	if (!strcmp(name, "t7b"))
		return ft_t7b(dev, v);
	if (!strcmp(name, "t9"))
		return ft_t9(dev, v);
	if (!strcmp(name, "t10a"))
		return ft_t10(dev, v, "t10a", 0);
	if (!strcmp(name, "t10c"))
		return ft_t10(dev, v, "t10c", 1);
	if (!strcmp(name, "t10r"))
		return ft_t10(dev, v, "t10r", 2);
	fprintf(stderr, "ntfstool: unknown flushtest case %s (t1-t10)\n", name);
	return 64;
}

/* Every command main() dispatches, and whether it opens the image
 * read-only. Returns 1 (read-only), 0 (read-write) or -1 (unknown). */
static int command_mode(const char *cmd)
{
	static const struct { const char *name; int ro; } commands[] = {
		{ "probe", 1 }, { "check", 1 }, { "info", 1 }, { "ls", 1 },
		{ "stat", 1 }, { "cat", 1 }, { "get", 1 }, { "readlink", 1 },
		{ "getxattr", 1 }, { "listxattr", 1 }, { "mftoff", 1 },
		{ "format", 0 }, { "repair", 0 }, { "put", 0 }, { "mkdir", 0 },
		{ "rm", 0 }, { "mv", 0 }, { "ln", 0 }, { "symlink", 0 },
		{ "truncate", 0 }, { "setxattr", 0 }, { "rmxattr", 0 },
		{ "label", 0 }, { "stress", 0 }, { "flushtest", 0 },
	};
	size_t i;

	for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
		if (!strcmp(cmd, commands[i].name))
			return commands[i].ro;
	return -1;
}

int main(int argc, char **argv)
{
	ntfsb_device dev;
	ntfsb_volume *v;
	ntfsb_info info;
	ntfsb_stat st;
	struct stat hst;
	const char *cmd, *leaf;
	uint64_t ino, dir;
	uint32_t bsize = 512;
	uint64_t bcount = 0;
	int r = 0, ro;

	if (argc < 3) {
		fprintf(stderr, "usage: ntfstool <image> <command> [args]\n");
		return 64;
	}
	cmd = argv[2];
	/* Reject unknown commands before the image is opened: an unknown
	 * command must never cause a read-write open or mount. */
	ro = command_mode(cmd);
	if (ro < 0) {
		fprintf(stderr, "ntfstool: unknown command %s\n", cmd);
		return 64;
	}
	atexit(io_stats);
	g_image = argv[1];
	g_fd = open(argv[1], ro ? O_RDONLY : O_RDWR);
	if (g_fd < 0 || fstat(g_fd, &hst)) {
		perror(argv[1]);
		return 1;
	}
	memset(&dev, 0, sizeof(dev));
	dev.pread = io_pread;
	dev.pwrite = ro ? NULL : io_pwrite;
	dev.sync = io_sync;
	dev.read_only = ro;
	g_io_trace = getenv("NTFSTOOL_IO_TRACE") != NULL;
	if (S_ISBLK(hst.st_mode) || S_ISCHR(hst.st_mode)) {
		ioctl(g_fd, DKIOCGETBLOCKSIZE, &bsize);
		ioctl(g_fd, DKIOCGETBLOCKCOUNT, &bcount);
		dev.size_bytes = bcount * bsize;
	} else {
		dev.size_bytes = hst.st_size;
		if (getenv("NTFSTOOL_SECTOR"))
			bsize = atoi(getenv("NTFSTOOL_SECTOR"));
	}
	dev.sector_size = bsize;
	ntfsb_set_log_callback(log_cb, getenv("NTFSTOOL_VERBOSE")
			? NTFSB_LOG_INFO : NTFSB_LOG_WARNING);

	if (!strcmp(cmd, "probe")) {
		r = ntfsb_probe(&dev, &info);
		if (r)
			printf("not NTFS\n");
		else
			printf("NTFS label=\"%s\" cluster=%u clusters=%llu\n",
				info.label, info.cluster_size,
				(unsigned long long)info.total_clusters);
		return r ? 1 : 0;
	}

	if (!strcmp(cmd, "format")) {
		r = ntfsm_format(&dev, argc > 3 ? argv[3] : "Untitled", 0, 1,
				maint_out, NULL);
		printf("format: %d\n", r);
		return r ? 1 : 0;
	}
	if (!strcmp(cmd, "check") || !strcmp(cmd, "repair")) {
		r = ntfsm_check(&dev, !strcmp(cmd, "repair"), maint_out, NULL);
		printf("%s: %d\n", cmd, r);
		return r ? 1 : 0;
	}

	/* Mount-time device I/O granularity for the unaligned write-path
	 * cases: the mounted bridge reports a larger block size, while the
	 * format and check invocations above keep the natural sector size
	 * of the image (the NTFS sector size inside the image comes from
	 * its boot sector and is unaffected either way). */
	{
		const char *s = getenv("NTFSTOOL_IO_ALIGN");

		if (s && *s) {
			long a = strtol(s, NULL, 0);

			if (a < 512 || a > (1L << 20) || (a & (a - 1))) {
				fprintf(stderr,
					"ntfstool: invalid NTFSTOOL_IO_ALIGN %s\n",
					s);
				return 64;
			}
			dev.sector_size = (uint32_t)a;
		}
	}

	v = do_mount(&dev, ro ? NTFSB_MOUNT_RDONLY : 0);

#define NEED(n) do { if (argc < 3 + (n)) { \
	fprintf(stderr, "ntfstool: %s needs %d argument(s)\n", cmd, n); \
	ntfsb_unmount(v); return 64; } } while (0)

	if (!strcmp(cmd, "info")) {
		ntfsb_get_info(v, &info);
		printf("label: %s\nversion: %d.%d\ncluster: %u\nsector: %u\n"
			"clusters: %llu\nfree clusters: %llu\nread-only: %d (reason %d)\n",
			info.label, info.major_ver, info.minor_ver,
			info.cluster_size, info.sector_size,
			(unsigned long long)info.total_clusters,
			(unsigned long long)info.free_clusters,
			info.read_only, info.ro_reason);
	} else if (!strcmp(cmd, "ls")) {
		NEED(1);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = ntfsb_readdir(v, ino, ls_cb, NULL);
	} else if (!strcmp(cmd, "stat")) {
		NEED(1);
		r = resolve(v, argv[3], &ino, &st);
		if (!r)
			printf("ino %llu parent %llu mode %o nlink %u size %llu alloc %llu "
				"attrs 0x%x flags 0x%x special %d mtime %lld\n",
				(unsigned long long)st.ino,
				(unsigned long long)st.parent_ino, st.mode,
				st.nlink, (unsigned long long)st.size,
				(unsigned long long)st.alloc_size, st.ntfs_attrs,
				st.bsd_flags, st.special_data,
				(long long)st.mtime.tv_sec);
	} else if (!strcmp(cmd, "cat") || !strcmp(cmd, "get")) {
		int out = 1;
		int64_t off = 0, n;
		char *buf = malloc(1 << 20);

		NEED(!strcmp(cmd, "get") ? 2 : 1);
		r = resolve(v, argv[3], &ino, &st);
		if (!r && !strcmp(cmd, "get"))
			out = open(argv[4], O_WRONLY | O_CREAT | O_TRUNC, 0644);
		while (!r && (n = ntfsb_read(v, ino, buf, 1 << 20, off)) != 0) {
			if (n < 0) {
				r = (int)n;
				break;
			}
			if (write(out, buf, n) != n) {
				r = -errno;
				break;
			}
			off += n;
		}
		free(buf);
	} else if (!strcmp(cmd, "put")) {
		int in;
		int64_t off = 0;
		ssize_t n;
		char *buf = malloc(1 << 20);

		NEED(2);
		in = open(argv[3], O_RDONLY);
		if (in < 0)
			die(argv[3], -errno);
		r = resolve_parent(v, argv[4], &dir, &leaf);
		if (!r) {
			r = ntfsb_lookup(v, dir, leaf, &st, NULL);
			if (r == -ENOENT)
				r = ntfsb_create(v, dir, leaf, S_IFREG, &st);
			else if (!r)
				r = ntfsb_truncate(v, st.ino, 0);
		}
		while (!r && (n = read(in, buf, 1 << 20)) > 0) {
			int64_t w = ntfsb_write(v, st.ino, buf, n, off);
			if (w != n)
				r = w < 0 ? (int)w : -EIO;
			off += n;
		}
		if (!r)
			r = ntfsb_release(v, st.ino);
		free(buf);
	} else if (!strcmp(cmd, "mkdir")) {
		NEED(1);
		r = resolve_parent(v, argv[3], &dir, &leaf);
		if (!r)
			r = ntfsb_create(v, dir, leaf, S_IFDIR, &st);
	} else if (!strcmp(cmd, "rm")) {
		NEED(1);
		r = resolve_parent(v, argv[3], &dir, &leaf);
		if (!r)
			r = ntfsb_remove(v, dir, leaf);
	} else if (!strcmp(cmd, "mv")) {
		uint64_t dir2;
		const char *leaf2;

		NEED(2);
		r = resolve_parent(v, argv[3], &dir, &leaf);
		if (!r)
			r = resolve_parent(v, argv[4], &dir2, &leaf2);
		if (!r)
			r = ntfsb_rename(v, dir, leaf, dir2, leaf2);
	} else if (!strcmp(cmd, "ln")) {
		NEED(2);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = resolve_parent(v, argv[4], &dir, &leaf);
		if (!r)
			r = ntfsb_link(v, ino, dir, leaf);
	} else if (!strcmp(cmd, "symlink")) {
		NEED(2);
		r = resolve_parent(v, argv[4], &dir, &leaf);
		if (!r)
			r = ntfsb_symlink(v, dir, leaf, argv[3], &st);
	} else if (!strcmp(cmd, "readlink")) {
		char *t = NULL;

		NEED(1);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = ntfsb_readlink(v, ino, &t);
		if (!r)
			printf("%s\n", t);
		free(t);
	} else if (!strcmp(cmd, "truncate")) {
		NEED(2);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = ntfsb_truncate(v, ino, strtoull(argv[4], NULL, 0));
	} else if (!strcmp(cmd, "setxattr")) {
		NEED(3);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = ntfsb_setxattr(v, ino, argv[4], argv[5], strlen(argv[5]), 0);
	} else if (!strcmp(cmd, "getxattr")) {
		char buf[65536];
		int64_t n = 0;

		NEED(2);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			n = ntfsb_getxattr(v, ino, argv[4], buf, sizeof(buf));
		if (n < 0)
			r = (int)n;
		else if (!r)
			printf("%.*s\n", (int)n, buf);
	} else if (!strcmp(cmd, "listxattr")) {
		NEED(1);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = ntfsb_listxattr(v, ino, xattr_cb, NULL);
	} else if (!strcmp(cmd, "rmxattr")) {
		NEED(2);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r)
			r = ntfsb_removexattr(v, ino, argv[4]);
	} else if (!strcmp(cmd, "label")) {
		NEED(1);
		r = ntfsb_set_label(v, argv[3]);
	} else if (!strcmp(cmd, "mftoff")) {
		uint32_t sector, cluster, mrs;
		int64_t mft_off, rs, re;

		NEED(1);
		r = resolve(v, argv[3], &ino, NULL);
		if (!r && boot_geometry(&sector, &cluster, &mrs, &mft_off)) {
			fprintf(stderr, "ntfstool: cannot parse the boot sector\n");
			r = -EINVAL;
		}
		if (!r) {
			ino_record_range(mft_off, mrs, ino, &rs, &re);
			printf("%s: ino %llu mft_record %lld..%lld\n", argv[3],
				(unsigned long long)ino,
				(long long)rs, (long long)re);
		}
	} else if (!strcmp(cmd, "stress")) {
		NEED(2);
		return stress(&dev, v, strtoull(argv[3], NULL, 0), atoi(argv[4]));
	} else if (!strcmp(cmd, "flushtest")) {
		NEED(1);
		return flushtest(&dev, v, argv[3]);
	} else {
		fprintf(stderr, "ntfstool: unknown command %s\n", cmd);
		r = -EINVAL;
	}

	{
		int ur = ntfsb_unmount(v);
		if (!r && ur)
			r = ur;
	}
	if (r) {
		fprintf(stderr, "ntfstool: %s: %s\n", cmd, strerror(-r));
		return 1;
	}
	return 0;
}
