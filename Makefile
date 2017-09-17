.PHONY: clean

AS ?= as
RM ?= rm -f
LD ?= ld

all: foo

foo.o: foo.S
	$(AS) -o foo.o foo.S

foo: foo.o
	$(LD) -o foo foo.o

clean: foo.o foo
	$(RM) foo.o foo