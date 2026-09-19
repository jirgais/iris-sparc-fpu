## IRIS open-source SPARC V8 FPU

The IRIS open-source FPU implements single- and double-precision
floating-point operations according to the IEEE-754 standard. All four
rounding modes and sub-normal operands are fully supported. The FPU
implements all SP and DP FPU operations defined in the SPARC V8 standard,
including FSMULD.

IRIS is functionally compatible with the Meiko FPU used in
Sun Microsparc processors. The individual instruction latencies
might vary slightly between IRIS and Meiko, but the calculated values
are identical for any type of operation and inputs. IRIS also supports
the FSMULD instruction which Meiko does not.

## Performance

IRIS FPU is iterative, which means that only one instruction can be excuted at a time. The table below shows the number of cycles necessary for each group of instrutions.

|  Instruction     |   Description        |  Clk min|  Clk avg|  Clk max|
|------------------|----------------------|---------|---------|---------|
|  FADDS/D, FSUBS/D| Add/Sub Singel/Double|    5    |   5.5   |    9    |
|  FMULS, FSMULD   | Multiply Single      |    5    |   7.5   |   11    |
|  FMULD           | Multiply Double      |    5    |   8.5   |   12    |
|  FDIVS           | Divide Single        |   11    |   21    |   32    |
|  FDIVS           | Divide Double        |   26    |   31    |   63    |
|  FSQRTS          | Square Root Single   |   34    |   34    |   35    |
|  FSQRTD          | Square Root Double   |   61    |   61    |   62    |
|  FXTOX           | Conversion           |    5    |    5    |    8    |



The IRIS FPU occupies approximately 3,500 LUT and 3 DSP48E1 blocks (18x18 multipler) on Xilinx FPGAs. The maximum frequency ranges from 100 MHz on Spartan6 to 200 MHz on Virtex7. The maximum gate depth is typically 8 LUTs.

## Simulation and synthesis

The IRIS FPU consists of three files:

    iris_mul.vhd     -- multiplier
    iris_div.vhd     -- divider
    irifpu.vhd       -- main datapath and top-level unit

A testbench is provided in the `sim` directory. The testbench reads instructions and operands from a text file, and checks the FPU result and exception flags. To run the simulation with [NVC](https://github.com/nickg/nvc), just do:

    make nvc-sim

To synthesise the FPU with ISE or Quartus, do:

    make ise

or

    make quartus

To see all `Makefile` targets, do:

    make help


## Additional test vectors with Testfloat

To generate more test vectors using the [Berkeley testfloat](https://github.com/ucb-bar/berkeley-testfloat-3) , do:

    make testfloat

This will generate 4 testfloat mixes: tfmix_near.txt, tfmix_zero.txt, tfmix_up.txt and tfmix_down.txt. Note that you have to have `testfloat_gen` in the PATH. You can then simulate the files with:

    make nvc-testfloat

A pre-compiled version of `testfloat_gen` for Ubuntu-x86_64 is in the   `testfloat` directory.

