/*
 * Copyright (c) 2017 Sebastian Cato
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

/* ITC Forth for FreeBSD/amd64. Should be easy to adapt to 32-bit x86 or
 * Linux but no care is taken to do so.
 *
 * Tabs are assumed to be four spaces wide.
 */

.intel_syntax noprefix

/* Forth registers. Using rsi for IP and rax for W means we can use
 * lodsq in NEXT. Doing so also means that the rest of the code assumes
 * that IP and W don't change. rsp is used for PSP, which also means
 * that we'll use push and pop for parameter stack manipulations. */
.set REG_IP, rsi
.set REG_W, rax
.set REG_RSP, rbx

/* word flags */
.set F_HIDDEN,0x80
.set F_IMMED,0x40
.set F_MASK,0x1f

/* Some sizes, and initial LFA which will be updated by DEFCODE, DEFWORD,
 * DEFVAR */
.set DATA_SEGMENT_SIZE, (1 << 20)
.set RSTACK_SIZE, (1 << 20)
.set CELLSIZE,8
.set ALIGNMENT,4
.set link, 0

/* syscall numbers */
.set SYS_exit,1
.set SYS_write,4
.set SYS_readv,120

.set STDOUT_FILENO,1

/* load the next cell from IP into W and jump to the address W points to */
.macro NEXT
    lodsq
    jmp     [REG_W]
.endm

/* push the value in a register to the return stack */
.macro PUSHRSP reg
    lea     REG_RSP, [REG_RSP-CELLSIZE]
    mov     [REG_RSP], \reg
.endm

/* pop a value from the return stack to a register */
.macro POPRSP reg
    mov     \reg, [REG_RSP]
    lea     REG_RSP, [REG_RSP+CELLSIZE]
.endm

/* "compile" (allocate?) a CELL referencing a label */
.macro C_CELL label
    .quad   \label
.endm

/* define a low-level, "code" word */
.macro DEFCODE name,namelen,label,flags=0
    .align ALIGNMENT
LFA_\label:
    C_CELL  link
    .set    link, LFA_\label
    .byte   \flags | \namelen
    .ascii  "\name"
    .align ALIGNMENT
\label:
    C_CELL  PFA_\label
PFA_\label:
.endm

/* define a high-level Forth word */
.macro DEFWORD name,namelen,label,flags=0
    .align ALIGNMENT
LFA_\label:
    C_CELL  link
    .set    link, LFA_\label
    .byte   \flags | \namelen
    .ascii  "\name"
    .align ALIGNMENT
\label:
    C_CELL  ENTER
PFA_\label:
.endm

/* define a code word for variables used in the .S file */
.macro DEFVAR name,namelen,label,flags=0,initial=0
    DEFCODE \name,\namelen,\label,\flags
    movabs  r9, offset VAR_\label
    push    r9
    NEXT
VAR_\label:
    C_CELL  \initial
.endm

/* allocate the data segment and the return stack in .bss. A guard page (or
 * guard pages) would be nice to have between the data segment and the return
 * stack. It's possible to do with ELF program headers, but this will work for
 * now. */
.bss
.lcomm      DATA_SEGMENT, DATA_SEGMENT_SIZE
.lcomm      RSTACK, RSTACK_SIZE

/* ibuf - circular input buffer for stdin */
.set        IBUF_LEN, (1 << 10) /* must be a power of two */
.lcomm      ibuf_buf, IBUF_LEN
.lcomm      ibuf_curroff, 4
.lcomm      ibuf_endoff, 4

.lcomm      wordbuf,256

.text
.global _start
_start:
    /* Setup the VM registers and start the interpreter. */
    cld
    movabs      REG_RSP, offset RSTACK + RSTACK_SIZE
    movabs      REG_IP, offset PFA_QUIT
    NEXT

/* ENTER: thread interpreter, used as a CFA for high-level words */
ENTER:
    PUSHRSP REG_IP
    add     REG_W, offset CELLSIZE
    mov     REG_IP, REG_W
    NEXT

/* _RIBUF: read bytes to the input buffer.
 *   Returns the number of bytes read, 0 on EOF and -1 on failure.
 *   r9 is used as the return register to avoid conflict with REG_W */
_RIBUF:
    push    REG_W
    push    REG_IP
    push    REG_RSP
    push    rdx
    push    rcx

    sub     rsp, 32 /* struct iovec iov[2] */
    mov     edx, 1  /* iovcnt */
    mov     ecx, [ibuf_curroff]

    /* iov[0].iov_base */
    mov     r9, offset ibuf_buf
    add     r9, rcx
    mov     [rsp], r9

    /* iov[0].iov_len */
    mov     r9d, IBUF_LEN
    sub     r9, rcx
    mov     [rsp+8], r9

    test    rcx, rcx
    je      1f
    inc     edx /* iovcnt++ */
    movq    [rsp+16], offset ibuf_buf /* iov[1].iov_base = ibuf_buf */
    movq    [rsp+24], rcx /* iov[1].iov_len = ibuf_curroff */

1:
    mov     eax, SYS_readv
    xor     rdi, rdi
    mov     rsi, rsp
    syscall

    /* update ibuf_endoff */
    test    rax, rax
    jle     2f
    mov     ecx, [ibuf_curroff] /* ecx possibly syscall tainted, so re-read */
    add     rcx, rax
    and     ecx, offset IBUF_LEN-1
    mov     [ibuf_endoff], ecx

2:
    mov     r9, rax
    add     rsp, 32

    pop     rcx
    pop     rdx
    pop     REG_RSP
    pop     REG_IP
    pop     REG_W
    ret

    DEFCODE "EXIT",4,EXIT
    POPRSP  REG_IP
    NEXT

    /* ( -- n ) */
    DEFCODE "LIT",3,LIT
    lodsq
    push    REG_W
    NEXT

    /* ( n -- ) */
    DEFCODE "SC_EXIT",7,SC_EXIT
    pop     rdi
    mov     eax, SYS_exit
    syscall

    /* ( -- n ) */
    DEFCODE "KEY",3,KEY
    mov     ecx, [ibuf_curroff]
    mov     r9d, [ibuf_endoff]
    cmp     ecx, r9d
    jne     1f
    call    _RIBUF
    test    r9, r9
    jg      1f
    push    -1
    NEXT
1:
    mov     edx, offset ibuf_buf
    movzx   edi, byte ptr [edx + ecx]
    inc     ecx
    and     ecx, offset IBUF_LEN-1
    mov     [ibuf_curroff], ecx
    push    rdi
    NEXT

    /* ( x -- x x ) */
    DEFCODE "DUP",3,DUP
    pop     r9
    push    r9
    push    r9
    NEXT

    DEFCODE "OVER",4,OVER
    mov     rdx, [rsp+8]
    push    rdx
    NEXT

    DEFCODE "DROP",4,DROP
    pop     r9
    NEXT

    /* ( x y -- y x ) */
    DEFCODE "SWAP",4,SWAP
    pop     r9
    pop     rcx
    push    r9
    push    rcx
    NEXT

    DEFCODE "BRANCH",6,BRANCH
    add     REG_IP, [REG_IP]
    NEXT

    /* ( n -- ) */
    DEFCODE "0BRANCH",7,ZBRANCH
    pop     r9
    test    r9,r9
    jz      PFA_BRANCH
    lodsq
    NEXT

    /* ( x1 x2 -- flag ) */
    DEFCODE "=",1,EQUALS
    pop     rcx
    pop     r9
    xor     rdi, rdi
    xor     rdx, rdx
    inc     rdx
    cmp     rcx, r9
    cmovz   rdi, rdx
    push    rdi
    NEXT

    /* ( x1 x2 -- flag ) */
    DEFCODE "<>",2,NOT_EQUALS
    pop     rcx
    pop     r9
    xor     rdi, rdi
    xor     rdx, rdx
    inc     rdx
    cmp     rcx, r9
    cmovnz  rdi, rdx
    push    rdi
    NEXT

    /* ( n addr -- ) */
    DEFCODE "!",1,STORE
    pop     rdi
    pop     rcx
    mov     [rdi], rcx
    NEXT

    /* ( c addr -- ) */
    DEFCODE "C!",2,C_STORE
    pop     rdi
    pop     rcx
    mov     [rdi], cl
    NEXT

    /* ( n n -- n ) */
    DEFCODE "+",1,ADD
    pop     rdi
    pop     rcx
    add     rcx, rdi
    push    rcx
    NEXT

    /* ( char addr -- addr+1 ) */
    DEFCODE "C!+",3,C_STORE_ADD
    pop     rdi
    pop     rcx
    mov     [rdi], cl
    inc     rdi
    push    rdi
    NEXT

    /* ( addr -- addr+1 u ) */
    DEFCODE "C@+",3,C_FETCH_ADD
    pop     rdi
    movzx   rcx, byte ptr [rdi]
    inc     rdi
    push    rdi
    push    rcx
    NEXT

    /* ( x -- ) */
    DEFCODE ">R",2,TO_R
    pop     rcx
    PUSHRSP rcx
    NEXT

    /* ( -- x ) */
    DEFCODE "R>",2,R_FROM
    POPRSP  rcx
    push    rcx
    NEXT

    /* ( -- x ) */
    DEFCODE "R@",2,R_FETCH
    mov     rcx, [REG_RSP]
    push    rcx
    NEXT

    /* ( addr -- x ) */
    DEFCODE "@",1,FETCH
    pop     r9
    mov     rcx, [r9]
    push    rcx
    NEXT

    /* ( n1 n2 - n ) */
    DEFCODE "-",1,SUB
    pop     rcx
    pop     rdx
    sub     rdx, rcx
    push    rdx
    NEXT

    /* ( c-addr u -- ) */
    DEFCODE "TYPE",4,TYPE
    pop     rdx
    pop     r9
    push    REG_W
    push    REG_IP
    push    REG_RSP

    /* XXX: This does not handle partial writes right now */
    mov     eax, SYS_write
    mov     rsi, r9
    mov     rdi, STDOUT_FILENO
    syscall

    pop     REG_RSP
    pop     REG_IP
    pop     REG_W
    NEXT

    /* ( c-addr len -- n nleft ) */
    DEFCODE "catNUMBER",9,catNUMBER
    pop     r11         /* r11: len */
    pop     rdi         /* rdi: c-addr */
    xor     eax, eax    /* rax: number */
    xor     r9d, r9d    /* r9: number negation flag */
    test    r11, r11    /* zero len? */
    jne     1f

    /* string is zero length */
    push    rax
    push    rax
    NEXT

1:
    /* negation check */
    cmp     BYTE PTR [rdi], '-'
    jne     2f
    inc     rdi
    dec     r11
    mov     r9d, 0x1
2:
    mov     r10, QWORD PTR [VAR_BASE] /* r10: number base */
    xor     r8d, r8d /* r8: c-addr offset */
3:
    cmp     r11, r8
    je      6f /* jump to end if offset == len */
    movzx   ecx, BYTE PTR [rdi+r8]
    imul    rax, r10
    lea     rdx, [rcx-'0']
    cmp     rdx, 0x9
    jbe     5f
    lea     rdx, [rcx-'A']
    cmp     rdx, 25
    ja      4f
    lea     rdx, [rcx-55] /* 'A'-55 = 10 */
    jmp     5f
4:
    lea     rdx, [rcx-'a']
    cmp     rdx, 25
    ja      7f
    lea     rdx, [rcx-87] /* 'a'-87 = 10 */
5:
    /* is current symbol >= base? If so, error out */
    cmp     r10, rdx
    jb      7f

    add     rax, rdx
    inc     r8
    jmp     3b
6:
    mov     rdx, rax
    neg     rdx
    test    r9d, r9d
    cmovne  rax, rdx
7:
    push    rax /* converted number */
    sub     r11, r8
    push    r11 /* number of bytes left (0 on success) */
    NEXT

    /* ( c -- flag ) */
    DEFCODE "WS?",3,IS_WS
    xor     rcx, rcx
    pop     rdx
    cmp     dl, ' '
    je      1f
    cmp     dl, '\r'
    je      1f
    cmp     dl, '\n'
    je      1f
    cmp     dl, '\t'
    je      1f
    push    rcx
    NEXT
1:
    inc     rcx
    push    rcx
    NEXT

    /* (nfa c-addr -- flag ) */
    DEFCODE "NFAMATCH",8,NFAMATCH
    pop     rdi /* word c-addr */
    pop     rax /* nfa (NB: clobbers REG_W/rax) */

    /* check if the length fields are equal */
    mov     dl, [rax]
    mov     dh, [rdi]
    xor     dh, dl
    and     dh, F_MASK
    jz      1f
    xor     rdx, rdx
    push    rdx
    NEXT
1:
    movzx   rcx, byte ptr [rdi]
    inc     rdi
    inc     rax
2:
    jrcxz   3f
    mov     dh, byte ptr [rdi]
    cmp     dh, byte ptr [rax]
    jnz     4f
    inc     rdi
    inc     rax
    dec     rcx
    jnz     2b
3:
    /* NFA was a match */
    xor     rdx, rdx
    inc     rdx
    push    rdx
    NEXT
4:
    /* NFA was not a match */
    xor     rdx, rdx
    push    rdx
    NEXT

    /* ( lfa -- xt 1|-1) XXX: Does this need to be a code word? */
    DEFCODE "LFA_XTFY",8,LFA_XTFY
    pop     rax
    add     rax, CELLSIZE   /* LFA -> NFA */
    mov     cl, [rax]       /* cl: len|flags */
    mov     dl, 1
    test    cl, F_IMMED
    jnz     1f
    mov     dl, -1          /* word is not immediate */
1:
    movsx   rdx, dl         /* rdx: immed */
    and     cl, F_MASK
    add     cl, ALIGNMENT   /* XXX: includes len byte adjustment */
    movzx   rcx, cl
    add     rax, rcx
    and     rax, ~(ALIGNMENT - 1)
    push    rax
    push    rdx
    NEXT

    DEFCODE "EXECUTE",7,EXECUTE
    pop     rax
    jmp     [rax]

    /* ( n -- ) */
    DEFWORD ",",1,COMMA
    C_CELL  HERE
    C_CELL  FETCH
    C_CELL  STORE
    C_CELL  HERE
    C_CELL  FETCH
    C_CELL  CELL_ADD
    C_CELL  HERE
    C_CELL  STORE
    C_CELL  EXIT

    DEFWORD "1=",2,ONE_EQUALS
    C_CELL  LIT
    C_CELL  1
    C_CELL  EQUALS
    C_CELL  EXIT

    DEFWORD "2OVER",5,TWO_OVER
    C_CELL  OVER
    C_CELL  OVER
    C_CELL  EXIT

    DEFWORD "2DROP",5,TWO_DROP
    C_CELL  DROP
    C_CELL  DROP
    C_CELL  EXIT

    DEFWORD "0",1,ZERO
    C_CELL  LIT
    C_CELL  0
    C_CELL  EXIT

    /* ( "<wss>ccc<ws>" -- c-addr ) */
    /* non-standard WORD implementation */
    DEFWORD "catWORD",4,catWORD
    C_CELL  KEY
    /* TODO: check return value of KEY for EOF and error and call BYE, or
     *       have KEY call BYE */
    C_CELL  DUP
    C_CELL  IS_WS
    C_CELL  ZBRANCH
    C_CELL  2f-.
    C_CELL  DROP
    C_CELL  BRANCH
    C_CELL  PFA_catWORD-.
2:
    /* S: key */
    C_CELL  LIT
    C_CELL  wordbuf+1
    C_CELL  C_STORE_ADD
    C_CELL  TO_R
3:
    /* S: */
    C_CELL  KEY
    C_CELL  DUP
    C_CELL  IS_WS
    C_CELL  ZERO
    C_CELL  EQUALS
    C_CELL  ZBRANCH
    C_CELL  4f-.
    C_CELL  R_FROM
    C_CELL  C_STORE_ADD /* XXX: There's a potential overflow here */
    C_CELL  TO_R
    C_CELL  BRANCH
    C_CELL  3b-.
4:
    C_CELL  DROP
    C_CELL  R_FROM
    C_CELL  LIT
    C_CELL  wordbuf+1
    C_CELL  SUB
    C_CELL  LIT
    C_CELL  wordbuf
    C_CELL  C_STORE
    C_CELL  LIT
    C_CELL  wordbuf
    C_CELL  EXIT

    /* ( -- u ) */
    DEFWORD "CELL",4,CELL
    C_CELL  LIT
    C_CELL  CELLSIZE
    C_CELL  EXIT

    /* ( n -- n ) */
    DEFWORD "CELL+",5,CELL_ADD
    C_CELL  CELL
    C_CELL  ADD
    C_CELL  EXIT

    /* ( c-addr -- c-addr 0  |  xt 1  |  xt -1 ) */
    DEFWORD "FIND",4,FIND
    C_CELL  TO_R
    C_CELL  LATEST
    C_CELL  FETCH
1:
    C_CELL  DUP
    C_CELL  ZERO
    C_CELL  EQUALS
    C_CELL  ZBRANCH
    C_CELL  2f-.
    /* S: 0 R: c-addr */
    C_CELL  R_FROM
    C_CELL  SWAP
    C_CELL  EXIT
2:
    C_CELL  DUP
    C_CELL  CELL_ADD
    C_CELL  R_FETCH
    /* S: LFA NFA c-addr R: c-addr */
    C_CELL  NFAMATCH
    /* S: LFA 0|1 R: c-addr */
    C_CELL  ZBRANCH
    C_CELL  3f-.
    C_CELL  R_FROM
    C_CELL  DROP
    C_CELL  LFA_XTFY /* LFA -> xt 1|-1 */
    C_CELL  EXIT
3:
    /* advance LFA, check next entry */
    C_CELL  FETCH
    C_CELL  BRANCH
    C_CELL  1b-.


    /* ( c-addr - c-addr+1 u ) */
    DEFWORD "COUNT",5,COUNT
    C_CELL  C_FETCH_ADD
    C_CELL  EXIT

    DEFWORD "BYE",3,BYE
    C_CELL  ZERO
    C_CELL  SC_EXIT

    DEFWORD "INTERPRET",9,INTERPRET
    C_CELL  catWORD
    C_CELL  FIND
    C_CELL  DUP
    C_CELL  ZBRANCH /* branch if word not found (should be number) */
    C_CELL  1f-.
    C_CELL  ONE_EQUALS
    C_CELL  ZBRANCH /* branch if non-immediate */
    C_CELL  4f-.
    C_CELL  EXECUTE /* immediate - execute it */
    C_CELL  EXIT

    /* Word not found, should be a number */
1:
    C_CELL  DROP
    C_CELL  COUNT
    C_CELL  catNUMBER
    C_CELL  ZBRANCH
    C_CELL  2f-.
    /* invalid number */
    /* TODO: error instead of exiting */
    C_CELL  BYE

2:
    /* valid number - which state are we in? */
    C_CELL  STATE
    C_CELL  FETCH
    C_CELL  ZBRANCH
    C_CELL  3f-.

    /* number, state: compiling */
    C_CELL  LIT
    C_CELL  LIT
    C_CELL  COMMA
    C_CELL  COMMA
    C_CELL  EXIT

3:
    /* number, state: interpreting. Just exit */
    C_CELL  EXIT

4:
    /* execution token - which state are we in? */
    C_CELL  STATE
    C_CELL  FETCH
    C_CELL  ZBRANCH
    C_CELL  5f-.

    /* xt, state: compiling */
    C_CELL  COMMA
    C_CELL  EXIT

5:
    /* xt, state: interpreting */
    C_CELL  EXECUTE
    C_CELL  EXIT

    /* QUIT should reset the return stack and enter interpretation state.
     * Right now it's used as an entry point for debugger oriented programming
     */
    DEFWORD "QUIT",4,QUIT
1:
    C_CELL  INTERPRET
    C_CELL  BRANCH
    C_CELL  1b-.

    DEFVAR  "STATE",5,STATE,,0 /* 0 when interpreting */
    DEFVAR  "BASE",4,BASE,,10
    DEFVAR  "HERE",4,HERE,,DATA_SEGMENT
    /* should be the last entry in this file */
    DEFVAR  "LATEST",6,LATEST,,LFA_LATEST
