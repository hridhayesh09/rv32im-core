// Graphics on the VGA framebuffer: 320x240 pixels, 16 colours (palette indices).
#ifndef GFX_H
#define GFX_H

#include <stdint.h>

#define GFX_WIDTH  320
#define GFX_HEIGHT 240

#define VGA_FB        ((volatile uint8_t *)0x20000000u)
#define VGA_PALETTE(i) (*(volatile uint32_t *)(0x10003000u + 4 * (i)))
#define VGA_STATUS    (*(volatile uint32_t *)0x10003040u)
#define VGA_FRAME     (*(volatile uint32_t *)0x10003044u)

// Default palette (CGA colours)
enum {
    BLACK, BLUE, GREEN, CYAN, RED, MAGENTA, BROWN, LIGHT_GREY,
    DARK_GREY, LIGHT_BLUE, LIGHT_GREEN, LIGHT_CYAN, LIGHT_RED, LIGHT_MAGENTA, YELLOW, WHITE
};

static inline void gfx_pixel(int x, int y, int colour)
{
    VGA_FB[y * GFX_WIDTH + x] = (uint8_t)colour;
}

void gfx_clear(int colour);
void gfx_rect(int x, int y, int w, int h, int colour);       // filled, clipped to the screen
void gfx_text(int x, int y, const char *s, int colour, int scale);  // 5x7 font, 6*scale per char
int  gfx_text_width(const char *s, int scale);
void gfx_wait_vblank(void);                                   // wait for the next frame to start
void gfx_set_palette(int index, uint32_t rgb12);              // 0xRGB, 4 bits per channel

#endif
