// doomgeneric platform layer for rv32im-core (CPU-only build: caches, 8-bit VGA mode).
//
//   video     doomgeneric runs in CMAP256 mode at 320x200: its frame is 8-bit palette indices,
//             the format of the VGA framebuffer, so DG_ScreenBuffer points straight at it and
//             each frame is one memcpy into video memory. The palette goes to the VGA's 256-entry
//             palette only when Doom changes it (damage flash, pickups).
//   input     key events from tools/doom_keys.py over the UART: 0xD1 key = pressed,
//             0xD0 key = released (key = a doomkeys.h code).
//   time      the cycle counter.
//   files     the WAD in SDRAM (doom_sys.c).
//
// Switch SW0 up at start: run the timedemo of demo 1 and print the frame rate (a benchmark).
// Every 5 seconds the frame rate is also printed on the UART.
#include <stdio.h>
#include <string.h>

#include "doom_rv32.h"
#include "doomgeneric.h"
#include "doomkeys.h"
#include "i_video.h"

extern boolean palette_changed;

static uint32_t frames, stat_frames;
static uint64_t stat_start;

void DG_Init(void)
{
    free(DG_ScreenBuffer);
    DG_ScreenBuffer = (pixel_t *)VGA_FB;
    memset((void *)VGA_FB, 0, DOOMGENERIC_RESX * DOOMGENERIC_RESY);
    stat_start = cycles64();
}

void DG_DrawFrame(void)
{
    if (palette_changed) {
        for (int i = 0; i < 256; i++)
            VGA_PALETTE256[i] = (colors[i].r >> 4) << 8 | (colors[i].g >> 4) << 4 | colors[i].b >> 4;
        palette_changed = false;
    }
    frames++;
    GPIO_LEDS = frames;
    uint64_t now = cycles64();
    if (now - stat_start >= 5ull * CLOCK_HZ) {
        uint32_t f = frames - stat_frames;
        uint32_t ms = (now - stat_start) / (CLOCK_HZ / 1000);
        printf("%lu frames in %lu ms: %lu.%lu fps\n", (unsigned long)f, (unsigned long)ms,
               (unsigned long)(f * 1000 / ms), (unsigned long)(f * 10000 / ms % 10));
        stat_frames = frames;
        stat_start = now;
    }
}

void DG_SleepMs(uint32_t ms)
{
    uint64_t end = cycles64() + (uint64_t)ms * (CLOCK_HZ / 1000);
    while (cycles64() < end)
        ;
}

uint32_t DG_GetTicksMs(void)
{
    return cycles64() / (CLOCK_HZ / 1000);
}

// Key events: bytes from the UART are collected until a whole event (2 bytes) is there.
#define KEYQ 32
static uint8_t keyq_key[KEYQ], keyq_pressed[KEYQ];
static unsigned keyq_head, keyq_tail;

static void poll_uart(void)
{
    static int marker = -1;
    int c;
    while ((c = uart_try_getc()) >= 0) {
        if (marker < 0) {
            if (c == 0xD0 || c == 0xD1)
                marker = c;
        } else {
            unsigned next = (keyq_head + 1) % KEYQ;
            if (next != keyq_tail) {
                keyq_key[keyq_head] = c;
                keyq_pressed[keyq_head] = marker == 0xD1;
                keyq_head = next;
            }
            marker = -1;
        }
    }
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    poll_uart();
    if (keyq_tail == keyq_head)
        return 0;
    *key = keyq_key[keyq_tail];
    *pressed = keyq_pressed[keyq_tail];
    keyq_tail = (keyq_tail + 1) % KEYQ;
    return 1;
}

void DG_SetWindowTitle(const char *title)
{
    printf("%s\n", title);
}

int main(void)
{
    printf("Doom on rv32im-core\n");
    uint32_t size = wad_find_size();
    if (!size) {
        printf("no WAD at 0x%08lx: upload one with --data 0x%08lx <file.wad>\nDONE\n",
               (unsigned long)WAD_BASE, (unsigned long)WAD_BASE);
        return 1;
    }
    if (wad_has_lump("FREEDOOM"))
        wad_name = wad_has_lump("MAP01") ? "freedoom2.wad" : "freedoom1.wad";
    else if (wad_has_lump("MAP01"))
        wad_name = "doom2.wad";
    else if (wad_has_lump("E2M1"))
        wad_name = "doom.wad";
    else
        wad_name = "doom1.wad";
    printf("WAD: %lu bytes, playing as %s\n", (unsigned long)size, wad_name);

    static char *argv[] = {"doom", "-iwad", NULL, "-timedemo", "demo1", NULL};
    argv[2] = (char *)wad_name;
    int argc = (GPIO_SWITCHES & 1) ? 5 : 3;
    doomgeneric_Create(argc, argv);
    for (;;)
        doomgeneric_Tick();
}
