SIM           ?= icarus
TOPLEVEL_LANG ?= verilog
WAVES         ?= 1

PROJ_ROOT  := $(shell git rev-parse --show-toplevel 2>/dev/null || echo ../../../..)
RTL_CORE   := $(PROJ_ROOT)/rtl/core
RTL_MEM    := $(PROJ_ROOT)/rtl/memory

VERILOG_SOURCES := \
    $(RTL_CORE)/riscv_pkg.sv \
    $(RTL_CORE)/alu.sv \
    $(RTL_CORE)/regfile.sv \
    $(RTL_CORE)/imm_gen.sv \
    $(RTL_CORE)/decoder.sv \
    $(RTL_CORE)/branch_unit.sv \
    $(RTL_CORE)/fetch.sv \
    $(RTL_CORE)/hazard_unit.sv \
    $(RTL_CORE)/execute.sv \
    $(RTL_CORE)/load_align.sv \
    $(RTL_CORE)/riscv_core.sv \
    $(RTL_MEM)/sram.sv \
    $(RTL_CORE)/imem_sync.sv \
    $(RTL_CORE)/soc_core_tb_top.sv

TOPLEVEL := soc_core_tb_top
MODULE   := test_riscv_core

COMPILE_ARGS += -g2012

export PYTHONPATH := $(PROJ_ROOT)/verif/cocotb:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
