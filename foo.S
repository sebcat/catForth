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
 * Linux but no care is taken to do so. */

.intel_syntax noprefix

/* Forth registers. Using rsi for IP and rax for W means we can use
 * lodsq in NEXT. Doing so also means that the rest of the code assumes
 * that IP and W don't change. rsp is used for PSP, which also means
 * that we'll use push and pop for parameter stack manipulations. */
.set REG_IP, rsi
.set REG_W, rax
.set REG_RSP, rbx

/* Some sizes, and initial LFA which will be updated by DEFCODE, DEFWORD */
.set DATA_SEGMENT_SIZE, (1 << 20)
.set RSTACK_SIZE, (1 << 20)
.set CELLSIZE,8
.set link, 0

/* syscall numbers */
.set SYS_exit,1
.set SYS_readv,120

/* load the next cell from IP into W and jump to the address W points to */
.macro NEXT
	lodsq
	jmp		[REG_W]
.endm

/* push the value in a register to the return stack */
.macro PUSHRSP reg
	lea		REG_RSP, [REG_RSP-CELLSIZE]
	mov		[REG_RSP], \reg
.endm

/* pop a value from the return stack to a register */
.macro POPRSP reg
	mov		\reg, [REG_RSP]
	lea		REG_RSP, [REG_RSP+CELLSIZE]
.endm

/* "compile" (allocate?) a CELL referencing a label */
.macro C_CELL label
	.quad	\label
.endm

/* define a low-level, "code" word */
.macro DEFCODE name,namelen,label,flags=0
LFA_\label:
	C_CELL	link
	.set	link, LFA_\label
	.byte	\flags | \namelen
	.ascii	"\name"
\label:
	C_CELL	PFA_\label
PFA_\label:
.endm

/* define a high-level Forth word */
.macro DEFWORD name,namelen,label,flags=0
LFA_\label:
	C_CELL	link
	.set	link, LFA_\label
	.byte	\flags | \namelen
	.ascii	"\name"
\label:
	C_CELL	ENTER
PFA_\label:
.endm

/* allocate the data segment and the return stack in .bss. A guard page (or
 * guard pages) would be nice to have between the data segment and the return
 * stack. It's possible to do with ELF program headers, but this will work for
 * now. */
.bss
.lcomm		DATA_SEGMENT, DATA_SEGMENT_SIZE
.lcomm		RSTACK, RSTACK_SIZE

/* ibuf - circular input buffer for stdin */
.set		IBUF_LEN, (1 << 10) /* must be a power of two */
.lcomm		ibuf_buf, IBUF_LEN
.lcomm		ibuf_curroff, 4
.lcomm		ibuf_endoff, 4

.text
.global _start
_start:
    /* Setup the VM registers and start the interpreter. */
	cld
FOO:
	movabs		REG_RSP, offset RSTACK + RSTACK_SIZE
	movabs		REG_IP, offset PFA_QUIT
	NEXT

ENTER:
	PUSHRSP	REG_IP
	add		REG_W, offset CELLSIZE
	mov		REG_IP, REG_W
	NEXT

	DEFCODE "EXIT",4,EXIT
	POPRSP	REG_IP
	NEXT

	/* ( -- n ) */
	DEFCODE "LIT",3,LIT
	lodsq
	push	REG_W
	NEXT

    /* ( n -- ) */
	DEFCODE "SC_EXIT",7,SC_EXIT
	pop		rdi
	mov		eax, SYS_exit
	syscall

	/* ( -- n) - read input to the input buffer, return number of bytes
     *           read, 0 on EOF and -1 on failure */
	DEFCODE "RIBUF",5,RIBUF
	push	REG_W
	push	REG_IP
	push	REG_RSP

	sub		rsp, 32 /* struct iovec iov[2] */
	mov		edx, 1  /* iovcnt */
	mov		ecx, [ibuf_curroff]

    /* iov[0].iov_base */
	mov		r9, offset ibuf_buf
	add		r9, rcx
	mov		[rsp], r9

	/* iov[0].iov_len */
	mov		r9d, IBUF_LEN
	sub		r9, rcx
	mov		[rsp+8], r9

	test	rcx, rcx
	je		1f
	inc		edx /* iovcnt++ */
	movq	[rsp+16], offset ibuf_buf /* iov[1].iov_base = ibuf_buf */
	movq	[rsp+24], rcx /* iov[1].iov_len = ibuf_curroff */

1:
	mov		eax, SYS_readv
	xor		rdi, rdi
	mov		rsi, rsp
	syscall

	/* update ibuf_endoff */
	test	rax, rax
	jle		2f
	add		rcx, rax
	and		ecx, offset IBUF_LEN-1
	mov		[ibuf_endoff], ecx

2:
	mov		r9, rax
	add		rsp, 32
	pop		REG_RSP
	pop		REG_IP
	pop		REG_W
	push	r9
	NEXT

	DEFWORD "BYE",3,BYE
	C_CELL	RIBUF
	C_CELL	RIBUF
	C_CELL	SC_EXIT

	/* QUIT should reset the return stack and enter interpretation state.
	 * Right now it just calls the exit syscall */
	DEFWORD "QUIT",4,QUIT
	C_CELL	BYE

