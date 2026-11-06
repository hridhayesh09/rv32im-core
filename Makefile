.PHONY: help check-tools test clean

help:
	@echo "make check-tools   print the version of every required tool"
	@echo "make test          run all tests"
	@echo "make clean         remove build output"

# Fails on the first missing tool, so a clean run means the setup is complete.
check-tools:
	@for t in verilator riscv64-unknown-elf-gcc spike python3 make; do \
	  command -v $$t > /dev/null || { echo "missing: $$t"; exit 1; }; \
	done
	@verilator --version
	@riscv64-unknown-elf-gcc --version | head -n 1
	@spike --help 2>&1 | head -n 1
	@python3 -c "import cocotb; print('cocotb', cocotb.__version__)"
	@python3 -c "import numpy; print('numpy', numpy.__version__)"
	@make --version | head -n 1

test:
	python3 -m pytest -v tests

clean:
	rm -rf build
