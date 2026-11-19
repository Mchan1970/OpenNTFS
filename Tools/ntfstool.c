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

static int g_fd = -1;
static unsigned long g_nw, g_nw_small, g_nr;

static int64_t io_pread(void *ctx, void *buf, int64_t count, int64_t off)
{
	ssize_t r = pread(g_fd, buf, count, off);
	g_nr++;
	if (getenv("NTFSTOOL_TRACE") && g_nw > 150 && g_nw < 175)
		fprintf(stderr, "R %10lld +%lld\n", (long long)off, (long long)count);
	(void)ctx;
	return r < 0 ? -errno : r;
}

static void io_stats(void)
{
	if (getenv("NTFSTOOL_STATS"))
		fprintf(stderr, "device writes: %lu (%lu of <= 64K), reads: %lu\n",
			g_nw, g_nw_small, g_nr);
}

static int64_t io_pwrite(void *ctx, const void *buf, int64_t count, int64_t off)
{
	ssize_t r = pwrite(g_fd, buf, count, off);
	g_nw++;
	if (getenv("NTFSTOOL_TRACE") && g_nw > 150 && g_nw < 175)
		fprintf(stderr, "W %10lld +%lld\n", (long long)off, (long long)count);
	if (count <= 65536)
		g_nw_small++;
	(void)ctx;
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

/* Every command main() dispatches, and whether it opens the image
 * read-only. Returns 1 (read-only), 0 (read-write) or -1 (unknown). */
static int command_mode(const char *cmd)
{
	static const struct { const char *name; int ro; } commands[] = {
		{ "probe", 1 }, { "check", 1 }, { "info", 1 }, { "ls", 1 },
		{ "stat", 1 }, { "cat", 1 }, { "get", 1 }, { "readlink", 1 },
		{ "getxattr", 1 }, { "listxattr", 1 },
		{ "format", 0 }, { "repair", 0 }, { "put", 0 }, { "mkdir", 0 },
		{ "rm", 0 }, { "mv", 0 }, { "ln", 0 }, { "symlink", 0 },
		{ "truncate", 0 }, { "setxattr", 0 }, { "rmxattr", 0 },
		{ "label", 0 }, { "stress", 0 },
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
	} else if (!strcmp(cmd, "stress")) {
		NEED(2);
		return stress(&dev, v, strtoull(argv[3], NULL, 0), atoi(argv[4]));
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
