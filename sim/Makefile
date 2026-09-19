nvc:
	nvc --std=93 -a --relaxed stdlib.vhd stdio.vhd ../rtl/iris_div.vhd \
  ../rtl/iris_mul.vhd ../rtl/irisfpu.vhd testbench.vhd
	nvc -e -j testbench

nvc-sim: nvc
	nvc --ieee-warnings=off -r testbench
	nvc -e -j testbench -g filename=paranoia.txt
	nvc --ieee-warnings=off -r testbench

nvc-testfloat: nvc
	nvc -e -j testbench -g filename=tfmix_near.txt
	nvc --ieee-warnings=off -r testbench
	nvc -e -j testbench -g filename=tfmix_zero.txt
	nvc --ieee-warnings=off -r testbench
	nvc -e -j testbench -g filename=tfmix_up.txt
	nvc --ieee-warnings=off -r testbench
	nvc -e -j testbench -g filename=tfmix_down.txt
	nvc --ieee-warnings=off -r testbench

ghdl:
	ghdl -a -O2 stdlib.vhd stdio.vhd ../rtl/iris_div.vhd ../rtl/iris_mul.vhd \
  ../rtl/irisfpu.vhd testbench.vhd
	ghdl -e testbench

ghdl-sim: ghdl
	./testbench --ieee-asserts=disable

vsim: work
	-vlib work
	vcom stdlib.vhd stdio.vhd ../rtl/iris_div.vhd ../rtl/iris_mul.vhd \
  ../rtl/irisfpu.vhd testbench.vhd

vsim-sim: vsim
	vsim testbench -do run.do < q.do
	vsim testbench -do run.do -gfilename=paranoia.txt < q.do

clean:
	-rm -rf e~testbench.o iris_div.o irisfpu.o iris_mul.o stdio.o stdlib.o \
  testbench testbench.o transcript work work-obj93.cf vsim.wlf tf*
