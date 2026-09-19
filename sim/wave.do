onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -radix hexadecimal /testbench/val
add wave -noupdate -radix hexadecimal /testbench/vals
add wave -noupdate -radix hexadecimal /testbench/main/calc
add wave -noupdate -radix hexadecimal /testbench/main/calcs
add wave -noupdate -radix hexadecimal -childformat {{/testbench/main/cexc(7) -radix hexadecimal} {/testbench/main/cexc(6) -radix hexadecimal} {/testbench/main/cexc(5) -radix hexadecimal} {/testbench/main/cexc(4) -radix hexadecimal} {/testbench/main/cexc(3) -radix hexadecimal} {/testbench/main/cexc(2) -radix hexadecimal} {/testbench/main/cexc(1) -radix hexadecimal} {/testbench/main/cexc(0) -radix hexadecimal}} -subitemconfig {/testbench/main/cexc(7) {-height 30 -radix hexadecimal} /testbench/main/cexc(6) {-height 30 -radix hexadecimal} /testbench/main/cexc(5) {-height 30 -radix hexadecimal} /testbench/main/cexc(4) {-height 30 -radix hexadecimal} /testbench/main/cexc(3) {-height 30 -radix hexadecimal} /testbench/main/cexc(2) {-height 30 -radix hexadecimal} /testbench/main/cexc(1) {-height 30 -radix hexadecimal} /testbench/main/cexc(0) {-height 30 -radix hexadecimal}} /testbench/main/cexc
add wave -noupdate /testbench/main/i
add wave -noupdate -radix hexadecimal /testbench/main/fcc_ref
add wave -noupdate /testbench/fpu0/clock
add wave -noupdate -radix hexadecimal /testbench/fpu0/FpInst
add wave -noupdate /testbench/fpu0/FpOp
add wave -noupdate /testbench/fpu0/FpLd
add wave -noupdate /testbench/fpu0/Reset
add wave -noupdate -radix hexadecimal /testbench/fpu0/fprf_dout1
add wave -noupdate -radix hexadecimal /testbench/fpu0/fprf_dout2
add wave -noupdate -radix hexadecimal /testbench/fpu0/RoundingMode
add wave -noupdate /testbench/fpu0/FpBusy
add wave -noupdate -radix hexadecimal /testbench/fpu0/FracResult
add wave -noupdate -radix hexadecimal /testbench/fpu0/ExpResult
add wave -noupdate -radix hexadecimal /testbench/fpu0/SignResult
add wave -noupdate /testbench/fpu0/SNnotDB
add wave -noupdate -radix hexadecimal /testbench/fpu0/Excep
add wave -noupdate -radix hexadecimal /testbench/fpu0/ConditionCodes
add wave -noupdate -radix hexadecimal /testbench/fpu0/r
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 3} {254 ns} 0} {{Cursor 3} {6292914 ns} 0}
quietly wave cursor active 1
configure wave -namecolwidth 318
configure wave -valuecolwidth 453
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {207 ns} {366 ns}
