#!/bin/bash
#
# Copyright (C) 2026 Greg Burd
#
# This work is open source software, licensed under the terms of the
# BSD license as described in the LICENSE file in the top-level directory.
#
# Verify the invariants the UEFI preboot stub depends on, at build time.
#
# EVERY CHECK HERE EXISTS BECAUSE ITS VIOLATION FAILS SILENTLY AT RUNTIME.
# UEFI loads the stub at an address of its choosing and, since we declare
# ImageBase = 0 with no .reloc section, applies no fixups.  A dynamic
# relocation therefore does not fail to link and does not fail to load: it
# leaves a pointer holding a link-time address that happens to be a valid
# address of something else, and the stub reads garbage on a live box where the
# only diagnostic channel is a serial console that may not be up yet.
#
# Run with --self-test to exercise every check against known-bad input, which
# is the only way to know a gate can fail at all.

set -u

cross_prefix="${1:-}"
elf="${2:-}"

nm="${cross_prefix}nm"
readelf="${cross_prefix}readelf"

fail() {
    echo "check-efi-stub: FAIL: $*" >&2
    exit 1
}

# 1. No dynamic relocations.  See the rationale above.  Counted as relocation
#    SECTIONS rather than by matching data rows: the row format varies between
#    readelf versions, and a pattern that silently matches nothing would make
#    this check always-pass, which is the exact failure mode the self-test
#    below exists to catch (and did catch, on the first version of this file).
check_no_relocs() {
    local f=$1 n
    n=$($readelf -r "$f" 2>/dev/null | grep -c "^Relocation section" || true)
    [ "$n" -eq 0 ] || return 1
    return 0
}

# 2. No .data, .bss or .got.  objcopy -O binary lays the flat image out by
#    section address, so a writable or zero-filled section either opens a hole
#    that displaces the kernel ELF from image_start + 0x10000 (where prestart
#    looks for it) or holds initialised bytes that are never written to the
#    file and read as garbage.
check_no_data_sections() {
    local f=$1 bad
    bad=$($readelf -S "$f" 2>/dev/null |
          grep -oE '\.(data|bss|got|got\.plt|plt|data\.rel\.ro)\b' || true)
    [ -z "$bad" ] || return 1
    return 0
}

# 3. The "MZ" DOS magic must be the first two bytes, or no UEFI firmware will
#    look at the image at all.  This is the ccmp instruction trick in
#    preboot.S, and it is checked on the linked output rather than trusted from
#    the source, because an assembler that encoded it differently would produce
#    an image that still boots under QEMU and never boots under UEFI.
check_mz_magic() {
    local f=$1 magic
    magic=$($readelf -x .text "$f" 2>/dev/null |
            awk '/0x00000000/ {print $2; exit}')
    [ "$magic" = "4d5a40fa" ] || return 1
    return 0
}

# 4. The arm64 Image magic must still be at offset 0x38, because the same
#    bytes must remain a valid arm64 Image for the QEMU/KVM/Firecracker path.
#    "ARM\x64" = 0x41 0x52 0x4d 0x64.  readelf -x prints the address first, so
#    the fourth word of the row starting at 0x30 is awk field 4, not 5.
check_arm64_magic() {
    local f=$1 word
    word=$($readelf -x .text "$f" 2>/dev/null |
           awk '/0x00000030/ {print $4; exit}')
    [ "$word" = "41524d64" ] || return 1
    return 0
}

# 5. The EFI code must start at or above 0x1000, because
#    "scripts/imgedit.py setargs" writes up to max_cmdline = 1024 bytes of
#    command line into the image at offset 0x200.  Code below that boundary is
#    overwritten by the build itself, and the image then executes its own
#    command line as instructions.
check_efi_code_above_cmdline() {
    local f=$1 addr
    addr=$($nm "$f" 2>/dev/null | awk '/ osv_efi_pe_entry$/ {print $1; exit}')
    [ -n "$addr" ] || return 1
    [ $((0x$addr)) -ge 4096 ] || return 1
    return 0
}

run_checks() {
    local f=$1
    check_no_relocs "$f"              || fail "$f has dynamic relocations"
    check_no_data_sections "$f"       || fail "$f has a .data/.bss/.got section"
    check_mz_magic "$f"               || fail "$f does not start with MZ (4d5a40fa)"
    check_arm64_magic "$f"            || fail "$f lacks the arm64 Image magic at 0x38"
    check_efi_code_above_cmdline "$f" || fail "osv_efi_pe_entry is below 0x1000, the cmdline window"
}

# ---------------------------------------------------------------------------
# Negative tests.  A gate that cannot fail is not a gate, so each check is
# exercised against input built to violate exactly it, through the same
# interface the real build uses.
# ---------------------------------------------------------------------------
self_test() {
    local tmp cc as ld rc=0
    tmp=$(mktemp -d)
    cc="${cross_prefix}gcc"
    ld="${cross_prefix}ld.bfd"

    expect_fail() {
        local name=$1 fn=$2 f=$3
        if $fn "$f"; then
            echo "self-test: FAIL: $name passed on known-bad input"
            rc=1
        else
            echo "self-test: ok: $name rejects known-bad input"
        fi
    }
    expect_pass() {
        local name=$1 fn=$2 f=$3
        if $fn "$f"; then
            echo "self-test: ok: $name accepts known-good input"
        else
            echo "self-test: FAIL: $name rejected known-good input"
            rc=1
        fi
    }

    # Known-bad 1: a global pointer initialised to another symbol's address is
    # the canonical way to get a relocation into an otherwise clean stub.
    cat > "$tmp/relocs.c" <<'EOF'
void target(void) {}
void (*p)(void) = target;
EOF
    $cc -ffreestanding -fpie -c -o "$tmp/relocs.o" "$tmp/relocs.c" 2>/dev/null
    $ld -shared -o "$tmp/relocs.so" "$tmp/relocs.o" 2>/dev/null
    expect_fail "no-relocs" check_no_relocs "$tmp/relocs.so"

    # Known-bad 2: a zero-initialised global lands in .bss.
    cat > "$tmp/bss.c" <<'EOF'
int zeroed[64];
void f(void) { zeroed[0] = 1; }
EOF
    $cc -ffreestanding -fpie -c -o "$tmp/bss.o" "$tmp/bss.c" 2>/dev/null
    expect_fail "no-data-sections" check_no_data_sections "$tmp/bss.o"

    # Known-bad 3 and 4: the real header with the magics deliberately wrong.
    cat > "$tmp/badmagic.S" <<'EOF'
.text
_head:
	b	1f
	.long 0x00080000
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0xdeadbeef	// where "ARM\x64" belongs
	.long 0
1:	ret
EOF
    ${cross_prefix}as -o "$tmp/badmagic.o" "$tmp/badmagic.S" 2>/dev/null
    $ld -o "$tmp/badmagic.elf" "$tmp/badmagic.o" 2>/dev/null
    expect_fail "mz-magic" check_mz_magic "$tmp/badmagic.elf"
    expect_fail "arm64-magic" check_arm64_magic "$tmp/badmagic.elf"

    # Known-bad 5: the entry symbol inside the command-line window.
    cat > "$tmp/lowentry.S" <<'EOF'
.text
.globl osv_efi_pe_entry
osv_efi_pe_entry:
	ret
EOF
    ${cross_prefix}as -o "$tmp/lowentry.o" "$tmp/lowentry.S" 2>/dev/null
    printf 'SECTIONS { . = 0x200; .text : { *(.text) } }\n' > "$tmp/low.ld"
    $ld -o "$tmp/lowentry.elf" -T "$tmp/low.ld" "$tmp/lowentry.o" 2>/dev/null
    expect_fail "efi-code-above-cmdline" check_efi_code_above_cmdline "$tmp/lowentry.elf"

    # POSITIVE CONTROLS.  Without these, a check that rejects everything looks
    # identical to a check that works.
    #
    # They must run against a LINKED image built the way the real stub is: an
    # unlinked .o always carries .data, .bss and .rela.eh_frame, so a .o could
    # never pass and would prove only that the check says no to everything.
    # The first draft of this file used a .o and reported two false failures,
    # which is what the positive control is for.
    cat > "$tmp/clean.S" <<'EOF'
.text
_head:
	ccmp	x18, #0, #0xd, pl
	b	1f
	.long 0x00080000
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.long 0
	.byte 0x41
	.byte 0x52
	.byte 0x4d
	.byte 0x64
	.long 0
1:	ret
	.org 0x1000
.globl osv_efi_pe_entry
osv_efi_pe_entry:
	ret
EOF
    ${cross_prefix}as -o "$tmp/clean.o" "$tmp/clean.S" 2>/dev/null
    printf 'SECTIONS { . = 0; .text : { *(.text) } /DISCARD/ : { *(.eh_frame*) *(.note*) *(.comment) } }\n' > "$tmp/clean.ld"
    $ld -o "$tmp/clean.elf" -T "$tmp/clean.ld" "$tmp/clean.o" 2>/dev/null
    expect_pass "no-relocs" check_no_relocs "$tmp/clean.elf"
    expect_pass "no-data-sections" check_no_data_sections "$tmp/clean.elf"
    expect_pass "mz-magic" check_mz_magic "$tmp/clean.elf"
    expect_pass "arm64-magic" check_arm64_magic "$tmp/clean.elf"
    expect_pass "efi-code-above-cmdline" check_efi_code_above_cmdline "$tmp/clean.elf"

    find "$tmp" -type f -delete
    rmdir "$tmp"
    return $rc
}

if [ "${1:-}" = "--self-test" ] || [ "${2:-}" = "--self-test" ]; then
    [ "${1:-}" = "--self-test" ] && cross_prefix=""
    nm="${cross_prefix}nm"
    readelf="${cross_prefix}readelf"
    self_test
    exit $?
fi

[ -n "$elf" ] || { echo "usage: $0 CROSS_PREFIX preboot.elf | $0 [CROSS_PREFIX] --self-test" >&2; exit 2; }
run_checks "$elf"
