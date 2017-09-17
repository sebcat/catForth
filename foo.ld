ENTRY(_start)

SECTIONS {
  PROVIDE (__executable_start = 0x400000); . = 0x400000 + SIZEOF_HEADERS;
  .text : {
    *(.text)
  }
  . = ALIGN (CONSTANT (MAXPAGESIZE)) - ((CONSTANT (MAXPAGESIZE) - .) &
      (CONSTANT (MAXPAGESIZE) - 1));

  __bss_start = .;
  .bss : {
   *(.bss)
  }
  . = ALIGN(64 / 8);
  _end = .; PROVIDE (end = .);

  /DISCARD/ : {
    *(*)
  }
}
