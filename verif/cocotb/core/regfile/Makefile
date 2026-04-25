SIM           ?= icarus
TOPLEVEL_LANG ?= verilog
WAVES         ?= 1

PROJ_ROOT  := $(shell git rev-parse --show-toplevel 2>/dev/null || echo ../../../..)
RTL_CORE   := $(PROJ_ROOT)/rtl/core

VERILOG_SOURCES := \
    $(RTL_CORE)/riscv_pkg.sv \
    $(RTL_CORE)/regfile.sv

TOPLEVEL := regfile
MODULE   := test_regfile

COMPILE_ARGS += -g2012

export PYTHONPATH := $(PROJ_ROOT)/verif/cocotb:$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
