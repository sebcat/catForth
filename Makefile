.PHONY: clean

AS ?= as
RM ?= rm -f
LD ?= ld

all: foo

foo.o: foo.S
	$(AS) -o foo.o foo.S

foo: foo.o foo.ld
	$(LD) -T foo.ld -o foo foo.o

clean:
	$(RM) foo.o foo
