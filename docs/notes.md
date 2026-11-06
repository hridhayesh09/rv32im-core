# Notes

Plain-English explanations of every part of this project, written to learn from and to
explain in interviews. Each stage adds a section.

## Stage 0: The tools and why each one is here

### Verilator
Verilator turns SystemVerilog into C++ and compiles it into a fast program that simulates the
design one clock cycle at a time. It only knows 0 and 1 (no X or Z), and it ignores `#` delays.
That makes it much faster than an event-driven simulator like Icarus, which is what makes running
thousands of instructions (riscv-tests, random tests, C programs, later CoreMark) practical.

### cocotb
cocotb lets you write testbenches in Python. The Python test drives the design's inputs and
checks its outputs while the simulator runs. Checking against a Python model (for example
`(a + b) & 0xFFFFFFFF` for the ALU) is quick to write and easy to read.

### RISC-V GCC
A cross compiler: it runs on the PC but produces RISC-V machine code. It compiles the tests and
the C programs into ELF files, which get turned into memory images that the simulated CPU runs.

### Spike
Spike is the official RISC-V reference simulator (the "golden model"). It runs the same program
as the CPU and says what should happen. With `--log-commits` it prints every instruction it
retires and every register and memory write it made.

### Lockstep comparison
The CPU reports the same information for every instruction it retires (PC, register written and
value, memory written and value). A script compares the two lists one instruction at a time and
stops at the first difference. This catches bugs the moment they happen, not hundreds of
instructions later when a test's final answer comes out wrong.

### Interview questions

**Why Verilator and not Icarus?**
Verilator compiles the design into a cycle-based C++ model, so it is much faster: important when
running full programs. The tradeoffs are that it is 2-state (no X propagation) and ignores timing
delays, so it is meant for synthesizable RTL, which is what a CPU is.

**What is a golden model and why do you need one?**
A trusted reference implementation of the spec. Without one you have to hand-write the expected
result of every test. With one, any program becomes a test: run it on both and compare.

**Why compare at every retired instruction, not just the final result?**
A wrong result might not show up until much later, or may never reach the final output. Comparing
at every retired instruction points to the exact instruction where the CPU went wrong.

## Stage 1, step 1: ALU, register file, decoder

These are the three building blocks every later stage uses. Each one is tested on its own
before it goes into the pipeline, because a bug is much easier to find in a 30-line module
than in a whole CPU.

### ALU (`rtl/alu.sv`)
The ALU is the calculator. It takes two 32-bit numbers `a` and `b` and an operation, and gives
one 32-bit result. It does the 10 RV32I operations: add, subtract, shift left, shift right
(logical and arithmetic), set-less-than (signed and unsigned), xor, or, and.

It is *combinational*: no clock, the output just follows the inputs. The pipeline decides
when to capture the result.

Things worth knowing:
- **Shifts use only the low 5 bits of `b`.** A 32-bit value can only shift 0–31 places, so
  the spec says to ignore the upper bits. Shifting by 32 is the same as shifting by 0.
- **SRL vs SRA.** Logical right shift fills with zeros; arithmetic right shift copies the sign
  bit, so a negative number stays negative (it divides by 2 and rounds down).
- **SLT vs SLTU.** The same bits compare differently: `0xFFFFFFFF` is -1 signed (less than 0)
  but the largest number unsigned.
- **There is no overflow flag.** RISC-V does not have condition flags; branches compare two
  registers directly.

**How it is tested:** every operation on every pair of 11 boundary values (0, 1, the largest
positive number, the most negative number, all ones, shift amounts 31 and 32, ...) and 20,000
random cases, all compared with a Python model.

### Register file (`rtl/regfile.sv`)
The 32 registers x0–x31, each 32 bits. Two read ports (an instruction can read two registers,
rs1 and rs2) and one write port (it writes at most one, rd).

- **x0 is always zero.** Writes to it are ignored. This gives the ISA a free zero:
  `mv a0, a1` is really `addi a0, a1, 0`, and `nop` is `addi x0, x0, 0`.
- **Reads are combinational, writes happen on the clock edge.**
- **Write-before-read.** If the instruction in WB is writing x5 in the same cycle that the
  instruction in ID reads x5, the read returns the *new* value. Without this, the pipeline would
  need one more forwarding path. This is the third of the three ways a value can reach a
  dependent instruction early (the other two are the forwarding paths in Stage 1, step 3).
- **No reset.** Real RISC-V cores don't clear their registers at reset; startup code sets the
  registers it needs. It also keeps the hardware smaller.

**How it is tested:** first every register is written with a known value, then 20,000 random
cycles of reads and writes (a quarter of reads hit the register being written, to exercise the
bypass) compared with a Python model, plus directed tests for x0 and write-before-read.

### Decoder (`rtl/decoder.sv`)
The decoder looks at the 32-bit instruction and works out what it means: which registers it
reads and writes, its immediate (the constant inside the instruction), and a set of control
signals that tell the later stages what to do (which ALU operation, whether to access memory,
whether it is a branch or jump, what to write back).

- **Instruction formats.** RISC-V has six layouts: R (register-register), I (immediate,
  including loads and JALR), S (stores), B (branches), U (LUI, AUIPC) and J (JAL).
  The register fields rs1, rs2 and rd are always in the same bit positions, so they can be read
  before the decoder even knows what the instruction is.
- **Why the immediate bits look scrambled.** In B and J formats the immediate's bits are
  shuffled around. That is on purpose: it keeps the sign bit always at bit 31 and puts as many
  bits as possible in the same place across formats, so the hardware needs fewer multiplexers.
- **B and J immediates have an implicit 0 at bit 0**, because instructions are at least 2 bytes
  aligned. That doubles the jump range for free.
- **`uses_rs1` / `uses_rs2`.** Every instruction has bits where rs1 and rs2 would be, even when
  it doesn't use them (LUI, JAL). The hazard unit will use these flags so it doesn't stall for a
  dependency that isn't real.
- **`reg_write` is off when rd is x0.** Writing x0 does nothing, so no forwarding or hazard logic
  should ever think a result is coming from x0.
- **Illegal instructions** come out with every side effect turned off and `illegal` set. Later,
  this lets the CPU stop safely instead of doing something random. The M-extension encodings
  are illegal until the multiply/divide step. FENCE is a no-op (an in-order core with one memory
  path already keeps loads and stores in order); FENCE.I is not supported, because the
  instruction and data memories are separate.

**How it is tested:** a Python encoder (written separately from the RTL) packs random field values
into instruction words for every RV32I instruction, and the decoder must unpack the same values:
20,000 random instructions, plus the largest and smallest immediate of every format. Then 40,000
random and mutated words check that the decoder flags exactly the illegal ones. A bug planted in
the branch immediate was caught by two of the three tests.

### Interview questions

**Why is x0 hardwired to zero?**
It gives a constant zero without spending an instruction, and lets many instructions double as
others: `nop`, `mv`, `j` (JAL with rd = x0), `beqz`, etc. are all just normal instructions using x0.
That keeps the base ISA small.

**Why does RISC-V scramble the immediate bits in branch and jump instructions?**
To keep the sign bit at bit 31 in every format and to keep bits in the same position across formats
wherever possible. Sign extension is then always from bit 31, and the immediate generator needs
fewer multiplexers. Hardware simplicity was chosen over encoding readability.

**What is write-before-read in a register file and why does a pipeline want it?**
When WB writes a register in the same cycle ID reads it, the read returns the new value. Without it,
an instruction three behind a producer would read a stale value, and the pipeline would need an extra
forwarding path or stall.

**What's the difference between SRA and SRL? Between SLT and SLTU?**
SRA fills with the sign bit (signed divide by a power of two, rounding down); SRL fills with zeros.
SLT compares as signed numbers, SLTU as unsigned. The bits are the same; only the interpretation
differs.

**Why does the decoder output `uses_rs1`/`uses_rs2` instead of letting the hazard unit just compare
register numbers?**
The rs1/rs2 bit fields always contain *something*, even for instructions like LUI and JAL that don't
read registers. Comparing them blindly would cause stalls for dependencies that don't exist.

**How do you know your tests can find bugs?**
I plant a bug on purpose (for example, take the wrong bit for the branch immediate) and check that
the test fails with a clear message, then restore the file. A test that has never failed might not
be checking anything.

## Stage 1, steps 2-4: the pipeline, branch flush, forwarding, load-use stall

### The pipeline (`rtl/core.sv`)
A pipeline works like an assembly line. Running one instruction takes five steps, and each step
has its own hardware, so while one instruction is being executed the next one is being decoded
and the one after that is being fetched. Up to five instructions are in flight at once. Each
one still takes five cycles, but one finishes every cycle.

| Stage | What happens |
|---|---|
| **IF** (fetch) | Send the PC to the instruction memory; the PC moves on to PC+4. |
| **ID** (decode) | The instruction arrives. Decode it and read rs1 and rs2 from the register file. |
| **EX** (execute) | The ALU computes. Branches compare and jumps compute their target. |
| **MEM** (memory) | Loads and stores send their address (and data) to the data memory. |
| **WB** (write back) | The loaded data arrives; write the result to rd. |

Between stages are **pipeline registers** (`d`, `e`, `m`, `w` in the code): on every clock edge
each instruction moves one stage forward, taking everything later stages will need with it.

**Valid bits and bubbles.** Each pipeline register has a `valid` bit. A slot with `valid = 0` is a
*bubble*: an empty slot that does nothing. Bubbles appear after reset, when instructions are
flushed, and when the pipeline stalls. Every action with an effect (writing a register, writing
memory, jumping) checks `valid` first.

**Synchronous-read memories.** FPGA block RAM (the MAX 10's M9K blocks) gives its read data one
clock *after* it gets the address. So IF sends the PC and the instruction shows up in ID, and MEM
sends the address and the loaded data shows up in WB. The memory's output register takes the
place of a pipeline register, so this costs no extra cycles compared to the textbook design.

### Control hazards: branch flush
The core doesn't know where a branch goes until EX. By then it has already fetched two more
instructions (now in IF and ID), assuming the branch is not taken ("predict not taken" is just
"keep fetching PC+4").
- **Not taken:** the guess was right; nothing is lost.
- **Taken, or any jump:** those two instructions are on the wrong path. They are **flushed**
  (turned into bubbles) and fetch restarts at the target. That costs 2 cycles: the
  **branch penalty**.

Stage 5 will add a branch predictor to guess taken branches and avoid most of that penalty.

### Data hazards: forwarding
`add x5, x1, x2` followed by `sub x6, x5, x3`: the `sub` reads x5 in ID while the `add` is still
in EX, and x5 is only written in WB, three cycles later. Without help, `sub` would read the old
x5.

But the value already exists: the `add` computed it in EX. **Forwarding** (also called bypassing)
sends it straight to the ALU input:
- 1 instruction later: the producer is in **MEM**, take its result from there.
- 2 instructions later: the producer is in **WB**, take the write-back value.
- 3 instructions later: the producer writes in WB in the same cycle the consumer reads in ID; the
  register file's **write-before-read** handles it.
- If two older instructions both write the register, the newer one (MEM) wins.

Forwarding works for anything that reads registers in EX: ALU operands, store address and data,
branch comparisons and the JALR base.

### Data hazards: the load-use stall
A load is different: its data only exists once the load reaches WB. If the very next instruction
needs it (`lw x5, 0(x10)` then `addi x6, x5, 1`), there is nothing to forward yet when `addi` is in
EX. So the core **stalls**: IF and ID hold their instructions for one cycle (the PC doesn't move,
and the instruction memory output is frozen) and a bubble goes into EX. One cycle later, `addi`
enters EX just as the load reaches WB, and WB forwarding supplies the value.

The stall only happens when it's really needed: the consumer must actually read the register
(`uses_rs1`/`uses_rs2` from the decoder) and the load must actually write one (not x0). A load
followed by an independent instruction costs nothing; compilers schedule code to make that the
common case.

### How it is tested: lockstep with Spike
Each program in `tests/asm/` runs twice: on Spike (the official RISC-V simulator) and on the core
in Verilator. Spike prints every instruction it retires (PC, instruction, register written and its
value, memory address and store data). The core reports the same through its `rvfi_*` retire
signals. The test compares the two lists one instruction at a time and stops at the first
difference, printing both sides.

The programs:
- `padded_alu.S`, `padded_mem.S`, `control_flow.S`: every RV32I instruction, written with NOPs
  between dependent instructions so they didn't need forwarding (written before it existed).
  `control_flow.S` puts a `j fail` right after every taken branch and jump, so a missing flush
  fails immediately.
- `forwarding.S`: back-to-back dependencies at distance 1, 2 and 3, on every kind of consumer.
- `load_use.S`: loads used immediately, by every kind of consumer, plus cases that must not stall.

Each program also checks its own results and reports pass/fail through `tohost`. Spike runs the
same checks, so a mistake in a test's expected value shows up as Spike failing, not as a fake
CPU bug.

Every hazard mechanism was switched off once on purpose to make sure its test catches it:
no flush (the core ran the wrong-path `j fail`), MEM forwarding replaced (a stale value at
instruction #2) and no load-use stall (a stale loaded value at instruction #4).

### Interview questions

**Walk me through your pipeline.**
Five stages: IF, ID, EX, MEM, WB, with pipeline registers between them carrying each instruction's
data and control signals. Branches resolve in EX with predict-not-taken and a 2-cycle penalty on
taken branches. Data hazards are handled by forwarding from MEM and WB plus write-before-read in
the register file, and the one case forwarding can't cover, a load followed by a use, stalls one
cycle.

**What are the three kinds of hazards?**
Structural (two instructions need the same hardware at once: avoided here with separate
instruction and data memories), data (an instruction needs a result that isn't written yet:
forwarding and the load-use stall) and control (the next PC isn't known until a branch resolves:
predict not taken and flush).

**Why can't you forward a load result the same way as an ALU result?**
The ALU result exists at the end of EX. The load result only exists after the memory access, at
the end of MEM (in WB with synchronous-read memory). An instruction right behind the load is
already in EX by then, so it has to wait one cycle.

**What's the branch penalty, and how would you reduce it?**
2 cycles for every taken branch or jump, because they resolve in EX. Ways to reduce it: resolve
branches in ID (needs a comparator and forwarding into ID, and lengthens that stage), predict
branches with a branch predictor and branch target buffer, or let the compiler lay out code so
the common path falls through.

**What's the difference between a stall and a flush?**
A stall holds instructions where they are (and inserts a bubble behind them) because they can't
proceed yet; nothing is thrown away. A flush throws away instructions that should never have
been fetched by turning them into bubbles.

**Why give every pipeline register a valid bit instead of turning bubbles into NOPs?**
A valid bit is one flop and one AND gate per side effect, and it's unambiguous: a bubble can never
be confused with a real instruction (an actual `nop` in the program retires and shows up in the
trace; a bubble doesn't).

**How did you verify the pipeline?**
Lockstep comparison against Spike at every retired instruction, on directed test programs for
each hazard type. I also disabled each hazard mechanism on purpose to confirm the tests catch it.

## Stage 1, step 6: the official riscv-tests

[riscv-tests](https://github.com/riscv-software-src/riscv-tests) is the RISC-V project's own set
of instruction tests. The `rv32ui` suite ("RV32, user-level, integer") has one test per base
instruction, each with dozens of cases: edge values, every register used as source and
destination, and back-to-back dependencies at different distances (the "bypass" cases), which
test forwarding again from a different angle.

**The environment file.** Each test includes `riscv_test.h`, which says how a test starts and
how it reports pass/fail. The official version sets up machine-mode CSRs and trap handlers and
ends with ECALL, which this core doesn't have yet. So `tests/env/riscv_test.h` is a minimal
replacement: clear all registers, run the test, write the result to `tohost` (1 = pass,
(test number << 1) | 1 = fail). Writing your own environment is the normal way to bring up the
suite on a new core.

**How they run.** Each test runs in lockstep with Spike, like the hand-written programs: every
retired instruction must match, not just the final pass/fail.

**Result** (`make test`): 40 of 42 rv32ui tests pass, comparing 13,107 instructions against
Spike. Two are excluded, with the reason printed in the test output:
- `fence_i`: the test rewrites its own code and runs it. With separate instruction and data
  memories, the instruction side never sees the new code. Supporting it needs FENCE.I to
  flush/reload instruction memory (or a cache), which comes later.
- `ma_data`: misaligned loads and stores (e.g. a word at an address that isn't a multiple of
  4). The spec allows a core to either handle them in hardware or trap and handle them in
  software; this core does neither yet.

A planted bug (SRA behaving like SRL) failed the `sra`, `srai` and `lui` tests.

### Interview questions

**How did you know your CPU implements the ISA correctly?**
Three layers: unit tests of the ALU, register file and decoder against Python models; the
official riscv-tests rv32ui suite; and lockstep comparison against Spike on every retired
instruction of every test, so a bug is caught at the exact instruction where it happens.

**What is a misaligned access and what does RISC-V say about it?**
An access whose address isn't a multiple of its size, like a 4-byte load from address 0x1002.
RISC-V lets the implementation choose: handle it in hardware, or raise an exception so software
can emulate it. Simple cores usually trap, because handling it in hardware means splitting one
access into two.

**Why does FENCE.I exist?**
A core can have separate paths (or caches) for instructions and data. When a program writes
new code with stores (a JIT, a bootloader), FENCE.I tells the core to make those stores visible
to instruction fetch before running the new code.

## Stage 1, step 8: random instruction tests

Directed tests only check the cases someone thought of. Random tests find the ones nobody
thought of: odd combinations of hazards, registers and values.

`tests/core/random_program.py` writes random RV32I programs. Each one:
- starts with every register holding a random value (with extra weight on edge values like
  0x80000000 and 0xFFFFFFFF), and a 256-byte data buffer full of random data;
- runs 400 random items: ALU ops, loads and stores of every size inside the buffer, forward
  branches and jumps (JAL, and JALR through a computed address), LUI/AUIPC, FENCE, and small
  counted loops (backward branches);
- uses a small "hot" set of 4 registers 60% of the time, so instructions constantly depend on
  the one just before: forwarding and load-use stalls happen all the time.

There are no expected values in the program. The oracle is Spike: every retired instruction must
match in lockstep. Jumps only go forward (and loops have a counter), so every program ends.

Seeds are fixed (0, 1, 2, ...) so any failure can be reproduced exactly. CI runs 20 programs on
every push; `RANDOM_PROGRAMS=300 make test` runs more.

**Results** (actual runs): 20 programs = 9,296 instructions compared in CI; a 300-program run
compared 140,187 instructions with zero mismatches. A planted bug (no load-use stall when only rs2
depends on the load) failed 14 of the 20 CI programs.

### Interview questions

**Directed tests or random tests?**
Both. Directed tests prove the features you know about and give clear failures; random tests
explore combinations you didn't think of. Constrained-random is the standard in industry DV: random
within rules that keep the program legal (aligned addresses inside the buffer, forward-only jumps,
bounded loops).

**What is the "oracle" in your random tests?**
Spike, the reference model. Random programs have no hand-written expected values; correctness means
every retired instruction matches Spike.

**How do you reproduce a failing random test?**
Every program comes from a fixed seed, so rerunning that seed regenerates exactly the same program.

## Stage 1, step 9: the M extension (multiply and divide)

The M extension adds 8 instructions:
- **MUL**: low 32 bits of rs1 × rs2 (the same for signed and unsigned).
- **MULH / MULHSU / MULHU**: the high 32 bits of the 64-bit product, treating the operands as
  signed×signed, signed×unsigned, or unsigned×unsigned.
- **DIV / DIVU**: quotient, rounded toward zero. **REM / REMU**: remainder; its sign follows the
  dividend, so `dividend = divisor × quotient + remainder` always holds.

**No exceptions for division.** RISC-V never traps on divide. Dividing by zero gives a quotient
of all ones (-1) and a remainder equal to the dividend; the one signed overflow case,
-2^31 / -1, gives -2^31 with remainder 0. The hardware handles both without any special path.

### The multiply/divide unit (`rtl/muldiv.sv`)
It is a separate unit next to the ALU, because multiply and divide are much bigger and slower than
an add. It takes several cycles, and the pipeline waits for it:

- **Multiply: 2 extra cycles.** The operands are first copied into registers, then a 33×33-bit
  signed multiplier computes the product into the result register. Extending each operand to 33
  bits (with its sign bit for signed operands, a 0 for unsigned) lets one signed multiplier do
  all four MUL variants. Having registers on both sides gives the multiplier a full clock cycle,
  which matters on the FPGA, where it maps onto the hardware multiplier (DSP) blocks.
- **Divide: 33 extra cycles.** *Restoring division*, the long division from school in binary:
  each cycle shifts one more bit of the dividend into the remainder, and if the divisor fits it is
  subtracted and the quotient bit is 1. 32 bits take 32 cycles. Signed division divides the
  magnitudes and fixes the signs at the end.

Measured on the core: 64 independent instructions took 80 cycles for ADD, 208 for MUL and 2,192
for DIVU (the same program otherwise), so (208 − 80) / 64 = **2 extra cycles per MUL** and
(2192 − 80) / 64 = **33 extra cycles per DIVU**.

### How the pipeline waits: the EX stall
When an M instruction is in EX and the unit isn't done, the core **stalls EX**: the instruction
stays in EX, IF and ID hold too, and bubbles go into MEM (so instructions already ahead keep
going and retire). When the unit says `done`, the result goes into the EX/MEM register like an
ALU result, and from there forwarding works exactly as for any other instruction.

The unit copies its operands when it starts, so they are the correct forwarded values at that
moment, even though the instructions they were forwarded from move on.

### Tradeoffs worth knowing
- **Faster multiply:** a single-cycle multiplier needs no stall but makes EX slower, which lowers
  the clock for every instruction. A pipelined multiplier (several stages, a new multiply every
  cycle) is what high-performance cores use; it adds forwarding/hazard cases.
- **Faster divide:** radix-4 or SRT dividers produce 2+ bits per cycle at more area. Division is
  rare in most code (compilers turn division by constants into multiplies), so a slow, small
  divider is a common choice for small cores.
- **Not blocking the pipeline:** an out-of-order core keeps running independent instructions while
  a divide is in progress. This in-order core simply waits.

**Results** (`make test`): all 8 official rv32um tests pass in lockstep with Spike (2,181
instructions); a directed `muldiv.S` covers forwarding into and out of the unit, back-to-back M
instructions, a load-use stall into a multiply, and branches right after a divide; the random
programs now include M instructions (a 300-program run compared 140,887 instructions, 6,667 of
them multiply/divide, with no mismatch). The unit's own tests check every operation on all pairs
of 10 edge values plus 3,000 random cases. A planted bug (remainder sign not fixed) failed the
official `rem` test.

### Interview questions

**Why is divide so much slower than multiply?**
A multiply's partial products are all known up front and can be added in parallel (a tree of
adders, or the FPGA's DSP blocks). Division is sequential: each quotient bit depends on the
remainder left by the previous step.

**What does RISC-V do on division by zero?**
No trap: the quotient is all ones and the remainder is the dividend. That keeps the hardware
simple; software that cares checks the divisor first.

**How did you implement MULHSU with one multiplier?**
Extend both operands to 33 bits, the signed one with its sign bit and the unsigned one with a 0,
then do one 33×33 signed multiply. The extra bit makes an unsigned 32-bit value a non-negative
signed number.

**What happens to the pipeline during a 33-cycle divide?**
The divide stays in EX; IF and ID hold, and bubbles go into MEM, so older instructions finish. When
the unit is done, the divide moves on and the pipeline continues.
