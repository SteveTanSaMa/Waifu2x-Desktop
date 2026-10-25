#ifndef Waifu2x_SystemArchive_h
#define Waifu2x_SystemArchive_h

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// The macOS SDK provides libarchive and its manual pages, but omits its headers.
// Declare only the public system-library ABI used by our streaming reader.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);

#endif
