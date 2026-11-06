# Setup

Everything runs inside WSL2 (Ubuntu 24.04) on Windows. Spike only really runs on Linux, and
Verilator and cocotb are much easier there. Quartus (needed from Stage 2) stays on Windows.

If you can't install WSL (for example on a computer managed by IT), use a GitHub Codespace
on the repo instead and run steps 2–6 there.

## 1. WSL2 + Ubuntu (Windows, admin PowerShell)

```powershell
wsl --install -d Ubuntu-24.04
```

Restart Windows. Ubuntu opens and asks for a Linux username and password (these are separate
from your Windows ones). Everything below runs in that Ubuntu terminal.

## 2. System packages

```bash
sudo apt update
sudo apt install -y build-essential git make autoconf flex bison help2man perl perl-doc \
  python3 python3-venv python3-pip ccache libfl2 libfl-dev zlib1g zlib1g-dev \
  libgoogle-perftools-dev numactl device-tree-compiler libboost-regex-dev \
  libboost-system-dev gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf gtkwave
```

What these are for:
- `build-essential`, `autoconf`, `flex`, `bison`, `help2man`, `perl`, `ccache`, `libfl*`, `zlib1g*`,
  `libgoogle-perftools-dev`, `numactl`: building Verilator and the C++ it generates.
- `device-tree-compiler`, `libboost-*`: building Spike.
- `gcc-riscv64-unknown-elf`: the RISC-V cross compiler. It's named riscv64 but builds 32-bit
  code with `-march=rv32im -mabi=ilp32`.
- `gtkwave`: viewing waveforms.

## 3. Verilator (from source, pinned)

Ubuntu's packaged Verilator is too old for cocotb 2.x, so build a pinned version (takes a while):

```bash
mkdir -p ~/tools && cd ~/tools
git clone https://github.com/verilator/verilator verilator-src
cd verilator-src
git checkout v5.036
autoconf
./configure --prefix=$HOME/tools/verilator
make -j$(nproc)
make install
```

## 4. Spike (RISC-V reference simulator)

```bash
cd ~/tools
git clone https://github.com/riscv-software-src/riscv-isa-sim spike-src
cd spike-src
mkdir build && cd build
../configure --prefix=$HOME/tools/spike
make -j$(nproc)
make install
```

## 5. PATH

```bash
echo 'export PATH=$HOME/tools/verilator/bin:$HOME/tools/spike/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

## 6. Python environment (cocotb)

```bash
python3 -m venv ~/venvs/rv
echo 'source ~/venvs/rv/bin/activate' >> ~/.bashrc
source ~/venvs/rv/bin/activate
pip install "cocotb~=2.0" pytest numpy
```

## 7. Get the repo into WSL

Building on the Windows drive from WSL is slow, so keep the working copy in the Linux home folder.
Once the repo is on GitHub:

```bash
cd ~
git clone https://github.com/hridhayesh09/rv32im-core.git
```

Until then the Windows copy is reachable at `/mnt/c/Users/hridh/rv32im-core`.

## 8. Check

```bash
cd ~/rv32im-core
make check-tools
```

Every line should print a version. The output is the record of which tool versions this
project was built with.

## Optional

- VS Code with the "WSL" extension: edit files in WSL from Windows.
- Quartus Prime Lite with MAX 10 device support (Windows): needed from Stage 2. It compiles and
  reports resources and timing without the board plugged in.
