all: regen
	for i in mk*; do ./$$i; done
	cp tfmix_*.txt ../sim

regen: regen.c
	gcc -O2 regen.c -lm -o regen

clean:
	-rm -rf *.txt x y regen
