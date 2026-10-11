#ifndef NUSKU_ELFUTILS_CONFIG_H
#define NUSKU_ELFUTILS_CONFIG_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#define PACKAGE "elfutils"
#define PACKAGE_NAME "elfutils"
#define PACKAGE_VERSION "0.190"
#define VERSION "0.190"
#define PACKAGE_URL "https://sourceware.org/elfutils/"
#define PACKAGE_BUGREPORT "elfutils-devel@sourceware.org"

#define HAVE_DECL_MEMPCPY 1
#define HAVE_DECL_MEMRCHR 1
#define HAVE_DECL_POWEROF2 0
#define HAVE_DECL_REALLOCARRAY 1
#define HAVE_DECL_STRERROR_R 1
#define HAVE_MEMPCPY 1
#define HAVE_MREMAP 1
#define HAVE_LINUX_MREMAP 1
#define HAVE_STDATOMIC_H 1
#define HAVE_VISIBILITY 1
#define HAVE_PTHREAD_H 1
#define HAVE_ERR_H 1

#define USE_LOCKS 1
#define USE_ZLIB 1
/* no USE_ZSTD: zstd-compressed ELF sections are not supported, on purpose */
#define ENABLE_NLS 0
#define SYMBOL_VERSIONING 0
#define ELFUTILS_HAVE_NO_SYMVER 1
#define ELF_OBJECT_ONLY 1

/* elfutils' autoconf footer: defines internal_function, _(), rwlock_define... */
#include <eu-config.h>

/* assert_perror is a glibc extension; musl does not have it. */
#include <assert.h>
#include <stdlib.h>
#ifndef assert_perror
#define assert_perror(e) do { if ((e) != 0) abort(); } while (0)
#endif

#endif
