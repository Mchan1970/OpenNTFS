/* Hand-written config.h for building libntfs-3g on macOS (arm64 / x86_64)
 * inside the FSKit extension. No autotools needed. */
#ifndef NTFS_CORE_CONFIG_H
#define NTFS_CORE_CONFIG_H

#define PACKAGE "ntfs-3g"
#define PACKAGE_NAME "ntfs-3g"
#define PACKAGE_VERSION "2026.9.28"
#define VERSION "2026.9.28"
#define PACKAGE_STRING "ntfs-3g 2026.9.28"
#define PACKAGE_BUGREPORT ""

#define WORDS_LITTLEENDIAN 1
#define _FILE_OFFSET_BITS 64

#define HAVE_CTYPE_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_GETOPT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIBGEN_H 1
#define HAVE_LIMITS_H 1
#define HAVE_LOCALE_H 1
#define HAVE_MACHINE_ENDIAN_H 1
#define HAVE_STDARG_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDDEF_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYSLOG_H 1
#define HAVE_SYS_DISK_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_MOUNT_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_TIME_H 1
#define HAVE_UNISTD_H 1
#define HAVE_WCHAR_H 1

#define HAVE_CLOCK_GETTIME 1
#define HAVE_FFS 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_MBSINIT 1
#define HAVE_REALPATH 1
#define HAVE_STRSEP 1
#define HAVE_DAEMON 1

/* Unicode normalisation is handled by the callers of the bridge (names are
 * composed to NFC before they reach libntfs-3g), so ENABLE_NFCONV stays off. */
/* No dlopen()ed reparse plugins inside a sandboxed extension. */
#define DISABLE_PLUGINS 1
#define IGNORE_MTAB 1


/* Redirections used when mkntfs / ntfsfix are built to run in-process
 * (see ntfs_maint.c). The Makefile passes these as -D flags instead. */
#if defined(NTFS_MAINT) && !defined(exit)
#define exit ntfsm_exit
#define ntfs_device_unix_io_ops ntfsb_maint_io_ops
#define ntfs_mount ntfsb_maint_mount
#define ntfs_log_handler_outerr ntfsm_log_handler
#endif

#endif
