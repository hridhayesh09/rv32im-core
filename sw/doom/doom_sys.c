// System calls for doomgeneric on picolibc: stdout/stderr go to the UART, and the WAD file that
// tools/upload.py loaded into SDRAM (at WAD_BASE) is the only file that can be opened. Writes to
// any other file (Doom's config and save games) fail quietly.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "doom_rv32.h"

// ---------------------------------------------------------------- UART streams
static int uart_put(char c, FILE *f)
{
    (void)f;
    if (c == '\n')
        uart_putc('\r');
    uart_putc(c);
    return (unsigned char)c;
}

static FILE uart_stream = FDEV_SETUP_STREAM(uart_put, NULL, NULL, _FDEV_SETUP_WRITE);
FILE *const stdout = &uart_stream;
FILE *const stderr = &uart_stream;
FILE *const stdin  = NULL;

// ---------------------------------------------------------------- the WAD in SDRAM
// A WAD ends with its lump directory: the file size is the directory offset plus 16 bytes per
// lump (both are in the 12-byte header), so the loader doesn't have to pass the size.
static const uint8_t *const wad = (const uint8_t *)WAD_BASE;
static uint32_t wad_size;
static uint32_t wad_pos;
static int      wad_open;

static uint32_t le32(const uint8_t *p)
{
    return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

uint32_t wad_find_size(void)
{
    if (memcmp(wad, "IWAD", 4) != 0 && memcmp(wad, "PWAD", 4) != 0)
        return 0;
    wad_size = le32(wad + 8) + 16 * le32(wad + 4);
    return wad_size;
}

int wad_has_lump(const char *name)
{
    uint32_t n = le32(wad + 4), dir = le32(wad + 8);
    for (uint32_t i = 0; i < n; i++)
        if (strncmp((const char *)wad + dir + 16 * i + 8, name, 8) == 0)
            return 1;
    return 0;
}

const char *wad_name = "doom1.wad";

static int is_wad_path(const char *path)
{
    size_t lp = strlen(path), ln = strlen(wad_name);
    return lp >= ln && strcmp(path + lp - ln, wad_name) == 0 &&
           (lp == ln || path[lp - ln - 1] == '/');
}

#define WAD_FD 3

int open(const char *path, int flags, ...)
{
    if (is_wad_path(path) && (flags & O_ACCMODE) == O_RDONLY && wad_size && !wad_open) {
        wad_open = 1;
        wad_pos  = 0;
        return WAD_FD;
    }
    errno = ENOENT;
    return -1;
}

int close(int fd)
{
    if (fd == WAD_FD && wad_open) {
        wad_open = 0;
        return 0;
    }
    errno = EBADF;
    return -1;
}

ssize_t read(int fd, void *buf, size_t n)
{
    if (fd != WAD_FD || !wad_open) {
        errno = EBADF;
        return -1;
    }
    if (n > wad_size - wad_pos)
        n = wad_size - wad_pos;
    memcpy(buf, wad + wad_pos, n);
    wad_pos += n;
    return n;
}

ssize_t write(int fd, const void *buf, size_t n)
{
    if (fd == 1 || fd == 2) {
        const char *s = buf;
        for (size_t i = 0; i < n; i++)
            uart_put(s[i], NULL);
        return n;
    }
    errno = EBADF;
    return -1;
}

off_t lseek(int fd, off_t offset, int whence)
{
    if (fd != WAD_FD || !wad_open) {
        errno = EBADF;
        return -1;
    }
    off_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (off_t)wad_pos : (off_t)wad_size;
    if (base + offset < 0 || base + offset > (off_t)wad_size) {
        errno = EINVAL;
        return -1;
    }
    wad_pos = base + offset;
    return wad_pos;
}

int unlink(const char *path)
{
    (void)path;
    errno = ENOENT;
    return -1;
}

int rename(const char *from, const char *to)
{
    (void)from;
    (void)to;
    errno = ENOENT;
    return -1;
}

int mkdir(const char *path, mode_t mode)
{
    (void)path;
    (void)mode;
    errno = EROFS;
    return -1;
}

int gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    uint64_t us = cycles64() / (CLOCK_HZ / 1000000);
    tv->tv_sec  = us / 1000000;
    tv->tv_usec = us % 1000000;
    return 0;
}

int getentropy(void *buf, size_t n)
{
    memset(buf, 0, n);
    return 0;
}

void _exit(int status)
{
    printf("\nDoom exited (%d)\nDONE\n", status);
    for (;;)
        ;
}
