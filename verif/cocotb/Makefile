# =============================================================================
# Top-level convenience Makefile — runs all Phase 1 cocotb suites.
# Usage: source /c/oss-cad-suite/environment && make
# =============================================================================
.PHONY: all alu regfile imm_gen riscv_core clean

all: alu regfile imm_gen riscv_core
	@echo ""
	@echo "============================================================"
	@echo "  Phase 1 regression complete."
	@echo "============================================================"

alu:
	@echo ">>> ALU"
	$(MAKE) -C core/alu

regfile:
	@echo ">>> Regfile"
	$(MAKE) -C core/regfile

imm_gen:
	@echo ">>> Immediate generator"
	$(MAKE) -C core/imm_gen

riscv_core:
	@echo ">>> RISC-V core integration"
	$(MAKE) -C core/riscv_core

clean:
	$(MAKE) -C core/alu clean
	$(MAKE) -C core/regfile clean
	$(MAKE) -C core/imm_gen clean
	$(MAKE) -C core/riscv_core clean
