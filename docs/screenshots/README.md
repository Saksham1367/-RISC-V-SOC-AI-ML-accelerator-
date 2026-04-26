# Waveform & synthesis screenshots

Drop your captured PNGs in this folder using the names below. The repo's main
README references each by relative path.

| Filename | What to capture |
|----------|-----------------|
| `core_arith.png` | `riscv_core` waveform: a few cycles of `arithmetic_smoke` showing PC, instruction, ALU result, regfile write-enable. |
| `core_loaduse.png` | `riscv_core` waveform: load-use stall — show `dmem_re` for the LW, then the 1-cycle stall + bubble before the dependent ADD commits. |
| `core_branch.png` | `riscv_core` waveform: BEQ taken — PC redirects, IF/ID flush. |
| `pe_mac.png` | `pe` waveform: a sequence of valid_in pulses, with `acc_q` updating each cycle. |
| `sa_matmul.png` | `sa_buffer` waveform: full matmul cycle — the 4 staggered A streams entering the west edge, B streams entering the north, and `done` pulse with `c_mat[0]` showing the result. |
| `axil_handshake.png` | `axil` waveform: AW + W + B handshake on a single write transaction. |
| `accel_program.png` | `accelerator_top` or `soc` waveform: full program flow — write A/B over AXI4-Lite, CTRL=1 pulse, busy → done, then C reads. |
| `soc_full.png` | `soc` waveform: zoomed-out view of the entire RV32I program execution end-to-end (~50 µs). |
| `yosys_core.png` | (optional) screenshot of `synth/build/core.stats` total cell count. |
| `yosys_soc.png` | (optional) screenshot of the `soc.stats` summary. |

## How to capture

```bash
source /c/oss-cad-suite/environment

# 1. Re-run the suite with waves enabled (writes .fst under sim/<suite>/)
WAVES=1 python scripts/run_tests.py riscv_core sa_buffer accel_top soc

# 2. Open the wave file
python scripts/open_waves.py riscv_core      # opens GTKWave on the FST
# (or directly:  gtkwave sim/riscv_core/soc_core_tb_top.fst)

# 3. In GTKWave:
#    - File ▸ Add ▸ Signals → drag the signals into the wave panel
#    - Use Edit ▸ Color Format / Data Format for clarity
#    - File ▸ Write Save File (.gtkw) if you want to reproduce the layout
#    - Edit ▸ Make Print/Screenshot → save as PNG into this folder
```

A quick GTKWave layout that looks good for the README:

* **Core**: `clk`, `rst_n`, `pc_q`, `id_instr`, `ex_ctrl.alu_op`, `wb_we`, `wb_rd`, `wb_data`.
* **PE**: `clk`, `valid_in`, `a_in`, `b_in`, `acc_q`.
* **Systolic array**: the 4×4 grid of `acc_out[i][j]` plus the west `a_west[]` and north `b_north[]`.
* **AXI4-Lite**: full 5-channel signal group — AWADDR/AWVALID/AWREADY, WDATA/WVALID/WREADY, BVALID/BREADY, ARADDR/ARVALID/ARREADY, RDATA/RVALID/RREADY.

When you save the screenshots into this folder using the filenames above, the
main README's images will resolve automatically.
