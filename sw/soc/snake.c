// Snake on the VGA display.
//
// Controls: KEY0 turns right, KEY1 turns left (relative to the snake), or W/A/S/D over the UART
// (absolute directions). Any key or button starts a game and restarts after game over.
// The score is on screen, on the 7-segment displays and printed over the UART.
#include "gfx.h"
#include "soc.h"

#ifndef STEP_US
#define STEP_US 120000          // one move every 120 ms
#endif

#define CELL 8
#define COLS (GFX_WIDTH / CELL)      // 40
#define ROWS (GFX_HEIGHT / CELL)     // 30
#define TOP  2                       // rows 0-1: the score bar

enum { RIGHT, DOWN, LEFT, UP };
static const int DX[4] = {1, 0, -1, 0};
static const int DY[4] = {0, 1, 0, -1};

static uint8_t snake_x[COLS * ROWS], snake_y[COLS * ROWS];   // ring buffer, head at `head`
static uint8_t occupied[ROWS][COLS];
static int head, length, direction, score, food_x, food_y;
static uint32_t seed;

static uint32_t next_random(void)
{
    seed = seed * 1103515245u + 12345u;
    return seed >> 8;
}

static void draw_cell(int cx, int cy, int colour)
{
    gfx_rect(cx * CELL, cy * CELL, CELL, CELL, BLACK);
    gfx_rect(cx * CELL + 1, cy * CELL + 1, CELL - 2, CELL - 2, colour);
}

static int is_wall(int cx, int cy)
{
    return cx == 0 || cx == COLS - 1 || cy == TOP || cy == ROWS - 1;
}

static void place_food(void)
{
    do {
        food_x = 1 + next_random() % (COLS - 2);
        food_y = TOP + 1 + next_random() % (ROWS - TOP - 2);
    } while (occupied[food_y][food_x]);
    draw_cell(food_x, food_y, LIGHT_RED);
}

static void show_score(void)
{
    char text[] = "SCORE 000";
    text[6] = '0' + score / 100 % 10;
    text[7] = '0' + score / 10 % 10;
    text[8] = '0' + score % 10;
    gfx_rect(0, 0, GFX_WIDTH, TOP * CELL, BLACK);
    gfx_text(4, 4, text, WHITE, 1);
    hex_show_dec(score);
}

// Input: -1 if none, otherwise a new direction (UART W/A/S/D) or a turn (buttons), or 4 for
// "some other key" (used to start a game).
static uint32_t keys_before;
static int read_input(void)
{
    int c = uart_try_getc();
    if (c >= 0) {
        switch (c | 0x20) {   // lower case
        case 'd': return RIGHT;
        case 's': return DOWN;
        case 'a': return LEFT;
        case 'w': return UP;
        default:  return 4;
        }
    }
    uint32_t keys = GPIO_KEYS;
    uint32_t pressed = keys & ~keys_before;   // only new presses
    keys_before = keys;
    if (pressed & 1) return (direction + 1) % 4;   // KEY0: turn right
    if (pressed & 2) return (direction + 3) % 4;   // KEY1: turn left
    return -1;
}

static void wait_for_start(void)
{
    while (read_input() < 0)
        ;
    seed ^= (uint32_t)timer_cycles();   // how long the player took: a different game each time
}

static void new_game(void)
{
    gfx_clear(BLACK);
    for (int cx = 0; cx < COLS; cx++)
        for (int cy = TOP; cy < ROWS; cy++)
            if (is_wall(cx, cy))
                draw_cell(cx, cy, DARK_GREY);
    for (int cy = 0; cy < ROWS; cy++)
        for (int cx = 0; cx < COLS; cx++)
            occupied[cy][cx] = 0;

    length = 3;
    head = length - 1;
    direction = RIGHT;
    score = 0;
    for (int i = 0; i < length; i++) {
        snake_x[i] = 5 + i;
        snake_y[i] = 15;
        occupied[15][5 + i] = 1;
        draw_cell(5 + i, 15, i == head ? LIGHT_GREEN : GREEN);
    }
    show_score();
    place_food();
}

// Moves one step. Returns 0 if the snake crashed.
static int step(void)
{
    int x = snake_x[head] + DX[direction];
    int y = snake_y[head] + DY[direction];
    int tail = (head - length + 1 + COLS * ROWS) % (COLS * ROWS);
    int eating = x == food_x && y == food_y;

    // Moving into the cell the tail is leaving is allowed (unless the snake grows this step).
    if (is_wall(x, y) || (occupied[y][x] && !(x == snake_x[tail] && y == snake_y[tail] && !eating)))
        return 0;

    if (eating) {
        length++;
        score++;
        show_score();
        printf("score %d\n", score);
    } else {
        occupied[snake_y[tail]][snake_x[tail]] = 0;
        gfx_rect(snake_x[tail] * CELL, snake_y[tail] * CELL, CELL, CELL, BLACK);
    }
    draw_cell(snake_x[head], snake_y[head], GREEN);          // old head becomes body
    head = (head + 1) % (COLS * ROWS);
    snake_x[head] = x;
    snake_y[head] = y;
    occupied[y][x] = 1;
    draw_cell(x, y, LIGHT_GREEN);
#ifdef TRACE
    printf("head %d %d\n", x, y);
#endif
    if (eating)
        place_food();
    return 1;
}

int main(void)
{
    seed = 1;
    gfx_clear(BLACK);
    const char *title = "SNAKE";
    gfx_text((GFX_WIDTH - gfx_text_width(title, 4)) / 2, 70, title, LIGHT_GREEN, 4);
    const char *hint = "PRESS A KEY OR BUTTON";
    gfx_text((GFX_WIDTH - gfx_text_width(hint, 1)) / 2, 140, hint, WHITE, 1);
    printf("SNAKE ready\n");
    keys_before = GPIO_KEYS;
    wait_for_start();

    for (;;) {
        new_game();
        printf("start\n");
        uint64_t next = timer_cycles();
        for (;;) {
            next += (uint64_t)STEP_US * (TIMER_CLK_HZ / 1000000u);
            int turned = 0;
            while (timer_cycles() < next) {
                int in = read_input();
                // One change of direction per step, and never straight back into the body.
                if (!turned && in >= 0 && in < 4 && in != (direction + 2) % 4) {
                    direction = in;
                    turned = 1;
                }
            }
            if (!step())
                break;
        }
        const char *over = "GAME OVER";
        gfx_text((GFX_WIDTH - gfx_text_width(over, 3)) / 2, 100, over, YELLOW, 3);
        printf("GAME OVER score %d\n", score);
        printf("DONE\n");
        wait_for_start();
    }
}
