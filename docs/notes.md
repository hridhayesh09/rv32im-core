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
