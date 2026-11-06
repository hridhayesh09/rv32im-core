// Self-modifying code: overwrite the instruction right after FENCE.I. That instruction has
// already been fetched (old version) when the store writes memory, so the core must throw it
// away and fetch it again, or it runs the old instruction.
#include "common.h"

TEST_BEGIN
    la   x10, patch
    li   x11, 0x02a00613       // addi x12, x0, 42
    sw   x11, 0(x10)
    fence.i
patch:
    addi x12, x0, 1            // replaced by: addi x12, x0, 42
    NOP2
    CHECK(1, x12, 42)
TEST_END
