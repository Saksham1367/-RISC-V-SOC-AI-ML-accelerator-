# Toolchain Setup — OSS CAD Suite + cocotb

This project's toolchain on Windows:

| Tool | Source | Notes |
|------|--------|-------|
| Icarus Verilog, Verilator, Yosys, GTKWave | OSS CAD Suite (bundled) | Activate via `environment` |
| cocotb 2.0+ | System Python 3.13 (`pip install --user cocotb`) | OSS CAD Suite's bundled Python lacks SSL, so we install cocotb against the system Python instead |
| make | Not used | Tests run via cocotb's Python runner — no GNU Make needed on Windows |

## 1. Download OSS CAD Suite

1. Open https://github.com/YosysHQ/oss-cad-suite-build/releases/latest
2. Download `oss-cad-suite-windows-x64-YYYYMMDD.exe` (self-extracting 7-zip archive, ~330 MB compressed, ~2 GB extracted).

## 2. Extract to `C:\`

Use 7-Zip (or just double-click the `.exe`) to extract to `C:\`. The result must be:

```
C:\oss-cad-suite\
├── bin\          (iverilog, verilator, yosys, gtkwave, ...)
├── lib\          (python3.exe, libs)
├── share\
├── environment.bat
├── environment.ps1
└── environment   ← supplied by this repo (Bash activation)
```

The `environment` file (no extension) is a small Bash wrapper that this project ships — the upstream archive only ships `.bat`/`.ps1`. After extraction, copy `setup/environment` from this repo to `C:\oss-cad-suite\environment`.

## 3. Install cocotb against system Python

```bash
"/c/Users/$USER/AppData/Local/Programs/Python/Python313/python.exe" -m pip install --user cocotb cocotb-bus
```

This installs `cocotb-config` to `~/AppData/Roaming/Python/Python313/Scripts/`.

## 4. Activate from Git Bash

Every new Git Bash session (or add to `~/.bashrc` to make permanent):

```bash
source /c/oss-cad-suite/environment
export PATH="/c/Users/$USER/AppData/Roaming/Python/Python313/Scripts:$PATH"
```

## 5. Verify

```bash
iverilog -V      # Icarus Verilog 14.0 (devel)
yosys -V         # Yosys 0.x
gtkwave --version
cocotb-config --version    # 2.0.x
```

## 6. Run Phase 1 regression

```bash
cd /c/Users/saksh/Desktop/riscv-soc-ai-ml-accelerator
python scripts/run_tests.py all
```

Expected: 4 suites, 22 tests, all PASS.

> **Why no Make?** GNU Make is not bundled on Windows. cocotb 2.0 provides a native Python runner (`cocotb_tools.runner`) that drives the simulator directly. `scripts/run_tests.py` uses it — no Make required.

> **Why not OSS CAD Suite's bundled Python?** That Python is built without `ssl`, so `pip install` cannot reach PyPI. The system Python 3.13 works fine for cocotb 2.0.
