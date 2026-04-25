# Toolchain Setup — OSS CAD Suite

This project uses the **OSS CAD Suite** from YosysHQ — one bundled distribution that ships every open-source EDA tool we need (Icarus Verilog, Verilator, Yosys, GTKWave, surfer, sby) along with a Python environment pre-wired for cocotb.

## 1. Download

1. Open https://github.com/YosysHQ/oss-cad-suite-build/releases/latest
2. Download the file matching your OS:
   - Windows: **`oss-cad-suite-windows-x64-YYYYMMDD.exe`** (self-extracting archive, ~600 MB compressed, ~2 GB extracted)

## 2. Extract

1. Move the downloaded `.exe` to `C:\` (root of C: drive).
2. Double-click it. When prompted for the destination, choose `C:\` — it will create `C:\oss-cad-suite\`.
3. Wait for extraction to finish (~2–3 min on SSD).

After extraction the path `C:\oss-cad-suite\environment` (a shell file with no extension) must exist.

## 3. Activate from Git Bash

Every time you open a new Git Bash shell to work on this project:

```bash
source /c/oss-cad-suite/environment
```

This puts `iverilog`, `vvp`, `verilator`, `yosys`, `gtkwave`, `python` (the cocotb-aware bundled Python), and `make` on your `PATH`.

> **Important:** Do **not** use the system Python 3.13 with cocotb in this project — use the Python that comes inside OSS CAD Suite. After `source`-ing `environment`, `which python` should point inside `/c/oss-cad-suite/`.

## 4. Verify Install

After activation, run:

```bash
iverilog -V
verilator --version
yosys -V
gtkwave --version
python -c "import cocotb; print('cocotb', cocotb.__version__)"
make --version
```

Each command should print a version string. If any fail, the install is incomplete — re-extract before continuing.

## 5. Optional — Persistent Activation

If you'd like `oss-cad-suite` to activate automatically in every Git Bash session, add this line to `~/.bashrc`:

```bash
source /c/oss-cad-suite/environment
```

Skip this if you'd rather activate per-session.
