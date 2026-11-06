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
