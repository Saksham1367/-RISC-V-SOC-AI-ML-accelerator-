# =============================================================================
# Cocotb Makefile — ALU unit test
# Usage: source /c/oss-cad-suite/environment && make
# =============================================================================
SIM           ?= icarus
TOPLEVEL_LANG ?= verilog
WAVES         ?= 1

# Repo-relative paths
PROJ_ROOT  := $(shell git rev-parse --show-toplevel 2>/dev/null || echo ../../../..)
RTL_CORE   := $(PROJ_ROOT)/rtl/core

VERILOG_SOURCES := \
    $(RTL_CORE)/riscv_pkg.sv \
    $(RTL_CORE)/alu.sv

TOPLEVEL := alu
MODULE   := test_alu

# Icarus needs SystemVerilog mode
COMPILE_ARGS += -g2012

# Tell cocotb where to find common helpers
export PYTHONPATH := $(PROJ_ROOT)/verif/cocotb:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
