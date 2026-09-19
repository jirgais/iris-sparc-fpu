
all help: 
	@echo ""
	@echo "  makefile targets:"
	@echo ""
	@echo "  make nvc           : compile with nvc"
	@echo "  make nvc-sim       : simulate testbench with nvc"
	@echo "  make ghdl          : compile with ghdl"
	@echo "  make ghdl-sim      : simulate testbench with ghdl"
	@echo "  make vsim          : compile with vsim"
	@echo "  make vsim-sim      : simulate testbench with vsim"
	@echo "  make ise           : synthesize with ISE"
	@echo "  make quartus       : synthesize with QUARTUS"
	@echo "  make testfloat     : generate additional testfloat vectors"
	@echo "  make nvc-testfloat : simulate additional testfloat vectors with nvc"
	@echo ""
	@echo "  make clean         : clean all generated files"
	@echo ""

vsim:
	make -C sim vsim

vsim-sim:
	make -C sim vsim-sim

ghdl:
	make -C sim ghdl

ghdl-sim:
	make -C sim ghdl-sim

nvc:
	make -C sim nvc

nvc-sim:
	make -C sim nvc-sim

nvc-testfloat:
	make -C sim nvc-testfloat

ise:
	make -C syn ise

quartus:
	make -C syn quartus

.PHONY: testfloat
testfloat:
	make -C testfloat

clean:
	make -C sim clean
	make -C syn clean
	make -C testfloat clean
