/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

SECTIONS
{
        /* The preboot stub is concatenated with the kernel ELF to form
         * loader.img, and both an arm64 Image loader and a UEFI PE loader map
         * it identity-wise, so the layout here IS the layout at runtime.
         *
         * .rodata is placed in the same output section as .text deliberately:
         * objcopy -O binary emits a flat file from the section addresses, so a
         * .rodata left at its default address would open a multi-megabyte hole
         * in loader.img and push the kernel ELF away from image_start + 0x10000,
         * which is where prestart looks for it.  There must also be no .data or
         * .bss here at all; the check in scripts/check-efi-stub.sh enforces
         * that, because a zero-initialised global would land in a hole in the
         * flat image and read as garbage rather than as zero.
         */
        . = 0;
        .text : {
                *(.text)
                *(.text.*)
                *(.rodata)
                *(.rodata.*)
        }

        /* Everything the stub must not have.  Keeping these named and empty
         * makes an accidental addition a loud link-time DISCARD rather than a
         * silent hole in the flat image.
         */
        /DISCARD/ : {
                *(.comment)
                *(.note*)
                *(.eh_frame*)
                *(.interp)
        }
}
