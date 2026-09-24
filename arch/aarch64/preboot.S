/*
 * Copyright (C) 2014 Huawei Technologies Duesseldorf GmbH
 *
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

image_start = .
cmdline_addr = . + 0x200 // 512 bytes after start of image
target = . + 0x10000     // start of the ELF in physical memory

.text
.align 16

_head:
	/* This header is read two different ways by two different kinds of
	 * loader, and both readings must stay valid.
	 *
	 * 1. An arm64 Linux Image loader (QEMU -kernel, KVM, Firecracker) reads
	 *    the header described in Documentation/arm64/booting.txt: a branch
	 *    at offset 0, the load offset at 0x08, the image size at 0x10, and
	 *    the magic "ARM\x64" at 0x38.  It enters at offset 0 with x0 = DTB.
	 *
	 * 2. A UEFI loader reads a PE/COFF image: "MZ" at offset 0 and the file
	 *    offset of the PE header at 0x3c.  It enters at the entry point
	 *    named in the optional header, with (image handle, system table),
	 *    and describes the machine with ACPI rather than a device tree.
	 *
	 * The two coexist because of one trick borrowed from Linux's EFI stub:
	 * the first four bytes are a real, harmless A64 instruction whose
	 * encoding begins with the ASCII bytes "MZ".
	 *
	 *     ccmp x18, #0, #0xd, pl   encodes as  4d 5a 40 fa  =  "MZ@."
	 *
	 * It writes only NZCV, and x18 is not live at entry from any loader.
	 * The Image loader executes it and falls through to the branch that
	 * follows; the PE loader never executes it and merely reads "MZ".  The
	 * remaining collision is settled by spending a header field that was
	 * previously zero padding: offset 0x3c, an Image "reserved" field,
	 * becomes the PE header pointer, and the PE header itself lives past
	 * the end of the Image header, at 0x40.
	 *
	 * The result is ONE artifact that both kinds of loader accept, so the
	 * existing QEMU/KVM/Firecracker path is not merely preserved, it is
	 * literally the same bytes.  This is why there is no build-time switch
	 * here: an off-by-default EFI mode would mean the configuration we test
	 * is not the configuration we ship.
	 */
	ccmp	x18, #0, #0xd, pl	// "MZ@." to a PE loader, a no-op to us
	b	prestart		// Image entry, x0 = DTB
	.long 0x00080000	// image load offset
	.long 0x00000000
	.long 0			// image size will be populated by Makefile
	.long 0
	.long 0			// unused informative flags, Xen/QEMU
	.long 0			//    image loaders ignore this field
	.long 0			// reserved
	.long 0			// reserved
	.long 0			// reserved
	.long 0			// reserved
	.long 0			// reserved
	.long 0			// reserved
	.byte 0x41		// magic number, "ARM\x64"
	.byte 0x52
	.byte 0x4d
	.byte 0x64
	.long pe_header - _head	// PE header offset, per PE/COFF

	/* ---------------- PE/COFF headers ----------------
	 *
	 * Four size fields here cannot be known until the kernel ELF has been
	 * linked and concatenated onto this stub, so they are emitted as zero
	 * and patched by "scripts/imgedit.py setsize_aarch64" in the same pass
	 * that fills in the Image header's own size field.  imgedit finds them
	 * by reading the PE offset back out of _head + 0x3c and then walking
	 * the PE structure, so this layout is not restated there as a set of
	 * magic constants.
	 *
	 * The image is mapped identity-wise: SizeOfHeaders, BaseOfCode and the
	 * single section's VirtualAddress and PointerToRawData are all 0x1000,
	 * so byte N of the file lands at offset N from the image base whatever
	 * the firmware does.  prestart depends on exactly that, because it
	 * locates the kernel ELF as image_start + 0x10000, PC-relatively.
	 */
	.align 3
pe_header:
	.ascii "PE"
	.short 0
coff_header:
	.short 0xaa64			// IMAGE_FILE_MACHINE_ARM64
	.short 1			// NumberOfSections
	.long 0				// TimeDateStamp
	.long 0				// PointerToSymbolTable
	.long 0				// NumberOfSymbols
	.short section_table - optional_header	// SizeOfOptionalHeader
	.short 0x0206			// EXECUTABLE_IMAGE | LINE_NUMS_STRIPPED
					//   | DEBUG_STRIPPED
optional_header:
	.short 0x020b			// PE32+
	.byte 0x02			// MajorLinkerVersion
	.byte 0x14			// MinorLinkerVersion
	.long 0				// SizeOfCode              (imgedit)
	.long 0				// SizeOfInitializedData
	.long 0				// SizeOfUninitializedData
	.long osv_efi_pe_entry - _head	// AddressOfEntryPoint
	.long 0x1000			// BaseOfCode
	/* NOTE: PE32+ has NO BaseOfData field.  PE32 does.  Emitting one here
	 * would shift every following field by four bytes, and the firmware
	 * would either reject the image or load it with a wrong SizeOfImage. */

extra_header_fields:
	.quad 0				// ImageBase, 0 = load anywhere
	.long 0x1000			// SectionAlignment
	.long 0x200			// FileAlignment
	.short 0			// MajorOperatingSystemVersion
	.short 0			// MinorOperatingSystemVersion
	.short 0			// MajorImageVersion
	.short 0			// MinorImageVersion
	.short 0			// MajorSubsystemVersion
	.short 0			// MinorSubsystemVersion
	.long 0				// Win32VersionValue

	.long 0				// SizeOfImage             (imgedit)
	.long 0x1000			// SizeOfHeaders
	.long 0				// CheckSum
	.short 10			// Subsystem: EFI application
	.short 0			// DllCharacteristics
	.quad 0				// SizeOfStackReserve
	.quad 0				// SizeOfStackCommit
	.quad 0				// SizeOfHeapReserve
	.quad 0				// SizeOfHeapCommit
	.long 0				// LoaderFlags
	.long 6				// NumberOfRvaAndSizes

	.quad 0				// ExportTable
	.quad 0				// ImportTable
	.quad 0				// ResourceTable
	.quad 0				// ExceptionTable
	.quad 0				// CertificationTable
	.quad 0				// BaseRelocationTable

section_table:
	/* One section, covering the stub and the kernel ELF alike.  There is no
	 * .reloc section: the stub is built to contain no dynamic relocations
	 * at all (the Makefile checks this) and ImageBase is 0, so there is
	 * nothing for the firmware to fix up.
	 */
	.ascii ".text\0\0\0"
	.long 0				// VirtualSize             (imgedit)
	.long 0x1000			// VirtualAddress
	.long 0				// SizeOfRawData           (imgedit)
	.long 0x1000			// PointerToRawData
	.long 0				// PointerToRelocations
	.long 0				// PointerToLineNumbers
	.short 0			// NumberOfRelocations
	.short 0			// NumberOfLineNumbers
	.long 0xe0000020		// CODE | EXECUTE | READ | WRITE
					//   (the kernel ELF's data lives in
					//    this section too)

	/* Static assertion, evaluated by the assembler.
	 *
	 * scripts/imgedit.py locates the section table by reading
	 * SizeOfOptionalHeader out of the COFF header, so it stays correct if
	 * this changes.  The value is pinned here anyway because getting it
	 * wrong is not a build failure: PE32+ has 112 bytes of optional header
	 * plus 8 bytes per data directory, and emitting the wrong NUMBER of
	 * directories, or mistaking a directory for 16 bytes instead of 8,
	 * produces a header that some firmware accepts and some rejects.
	 * 112 + 6 * 8 = 160.
	 */
	.if (section_table - optional_header) != 160
	.err	// SizeOfOptionalHeader is not 112 + 6*8; see the comment above
	.endif

.globl prestart
.hidden prestart
prestart:
        mov     x5, x0     /* save device tree blob physical addr */
        adr     x4, cmdline_addr
        adr     x3, target /* elf header start */

        // load virtual address of the entry point from ELF header + 24 into x0
        ldr     w0, [x3, #24]
        ldr     w1, [x3, #28]
        orr     x0, x0, x1, LSL #32

        // calculate offset of elf entry point in physical memory relative to image_start
        and     x0, x0, #0x1fffff // offset in 2MB segment
        sub     x0, x0, #0x80000  // subtract the image load offset (see "image load offset" in the _head section above)

        // add the offset calculated above to the physical address of image_start
        adr     x1, image_start   // fetch physical address of the image_start
        add     x0, x0, x1        // add entry point offset to the image_start address

        // jump to elf entry point address in physical memory
        br      x0

	/* Everything below must live above 0x600, because
	 * "scripts/imgedit.py setargs" writes the command line into the image
	 * at offset 0x200 (cmdline_addr) and it may be up to max_cmdline =
	 * 1024 bytes long.  Code placed in that window would be silently
	 * overwritten by the build, producing an image that executes the
	 * command line as instructions.  0x1000 is used rather than 0x600 so
	 * that the boundary also coincides with BaseOfCode and the section's
	 * VirtualAddress above.
	 */
	.org 0x1000

/* ------------------------------------------------------------------ *
 * UEFI entry path
 * ------------------------------------------------------------------ */
.globl osv_efi_pe_entry
.hidden osv_efi_pe_entry
.type osv_efi_pe_entry, "function"
osv_efi_pe_entry:
	/* Entered from firmware with x0 = EFI image handle,
	 * x1 = EFI_SYSTEM_TABLE *, MMU and caches ON, at EL1 or EL2, on a
	 * firmware-provided stack.  AAPCS64 applies (unlike x86_64 UEFI, which
	 * uses the Microsoft ABI).
	 *
	 * The C stub needs to know where our own first byte ended up.  The PE
	 * ImageBase is 0 and we perform no relocations, so it cannot be read
	 * out of the headers; take it PC-relatively instead, which is right
	 * wherever the firmware chose to load us.
	 */
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	adrp	x2, _head
	add	x2, x2, #:lo12:_head
	bl	osv_efi_main
	/* Reached only if the stub declined to boot.  Return the status to the
	 * firmware so it can report it, rather than leaving a silent box that
	 * is indistinguishable from firmware which never ran us.
	 */
	ldp	x29, x30, [sp], #16
	ret

/* void osv_efi_enter_kernel(u64 image_base, u64 dtb, u64 image_size)
 *
 * Called after ExitBootServices.  Hands control to the relocated image at its
 * Image entry point, honouring the arm64 Linux boot protocol: MMU off, caches
 * off, at EL1, x0 = DTB.  Never returns.
 */
.globl osv_efi_enter_kernel
.hidden osv_efi_enter_kernel
.type osv_efi_enter_kernel, "function"
osv_efi_enter_kernel:
	mov	x19, x0			// image base (survives the loops below)
	mov	x20, x1			// dtb
	mov	x21, x2			// image size

	/* Clean the copied image and the DTB out to the Point of Coherency.
	 * We are about to turn the D-cache off, after which loads bypass it,
	 * so anything still only in the cache would be invisible to the
	 * kernel.  Omitting this does not fail loudly: it faults later,
	 * somewhere unrelated, the first time execution reaches a line that
	 * never made it out of the cache.
	 */
	mrs	x0, ctr_el0
	ubfx	x0, x0, #16, #4		// CWG: log2 of words in the largest line
	mov	x1, #4
	lsl	x1, x1, x0		// line size in bytes
	sub	x2, x1, #1

	mov	x3, x19
	add	x4, x19, x21
	bic	x3, x3, x2
1:	dc	civac, x3
	add	x3, x3, x1
	cmp	x3, x4
	b.lo	1b

	mov	x3, x20
	add	x4, x20, #0x10000	// the DTB buffer the stub filled
	bic	x3, x3, x2
2:	dc	civac, x3
	add	x3, x3, x1
	cmp	x3, x4
	b.lo	2b
	dsb	sy
	isb

	/* If the firmware left us at EL2, drop to EL1.  boot.S's validate_el
	 * checks CurrentEL and halts on anything other than EL1, so without
	 * this the boot dies in a wfi loop with nothing on the console and
	 * looks exactly like firmware that never ran us at all.
	 */
	mrs	x0, currentel
	ubfx	x0, x0, #2, #2
	cmp	x0, #2
	b.ne	el1_entry

	/* EL2 -> EL1.  Configure the minimum a 64-bit EL1 guest needs. */
	mov	x0, #(1 << 31)		// HCR_EL2.RW: EL1 is AArch64
	msr	hcr_el2, x0

	/* Let EL1 read the counters and use the timers untrapped.  OSv's
	 * arm_clock reads cntfrq_el0 and cntvct_el0 almost immediately and
	 * aborts the boot on an implausible frequency, so a trap here would
	 * surface as a bogus clock rather than as a fault.
	 */
	mrs	x0, cnthctl_el2
	orr	x0, x0, #3		// EL1PCTEN | EL1PCEN
	msr	cnthctl_el2, x0
	msr	cntvoff_el2, xzr

	/* Do not trap EL1 FP/SIMD or CP15 accesses at EL2. */
	mov	x0, #0x33ff
	msr	cptr_el2, x0
	msr	hstr_el2, xzr
	msr	mdcr_el2, xzr

	/* EL1 starts with its own MMU off; boot.S sets sctlr_el1 properly. */
	ldr	x0, =0x30d00800		// reserved-1 bits set, M/C/I clear
	msr	sctlr_el1, x0

	/* Return to EL1h with interrupts masked, at our EL1 continuation. */
	mov	x0, #0x3c5		// DAIF masked, M[3:0] = 0b0101 (EL1h)
	msr	spsr_el2, x0
	adr	x0, el1_entry
	msr	elr_el2, x0
	eret

el1_entry:
	/* Turn the MMU and caches off, as the arm64 boot protocol requires.
	 * boot.S re-establishes all of it.
	 */
	mrs	x0, sctlr_el1
	bic	x0, x0, #(1 << 0)	// M: MMU off
	bic	x0, x0, #(1 << 2)	// C: D-cache off
	bic	x0, x0, #(1 << 12)	// I: I-cache off
	msr	sctlr_el1, x0
	isb
	tlbi	vmalle1
	dsb	nsh
	ic	iallu
	dsb	nsh
	isb

	/* Enter the image exactly as an Image loader would: x0 = DTB physical
	 * address, branch to the first byte.  From here on, the UEFI path and
	 * the QEMU/Firecracker path are the same instructions.
	 */
	mov	x0, x20
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, xzr
	br	x19
