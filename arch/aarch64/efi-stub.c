/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * UEFI boot stub for OSv/aarch64.
 *
 * WHY THIS EXISTS
 * ---------------
 * OSv/aarch64 is entered by arch/aarch64/preboot.S's "prestart", which
 * implements the arm64 Linux Image boot protocol: a loader places the flat
 * image at (2 MB-aligned base + 0x80000), passes the physical address of a
 * device tree blob in x0, and branches to the image's first instruction.
 * QEMU, KVM and Firecracker all honour that contract.
 *
 * UEFI does not.  It loads a PE/COFF image at an address of its own choosing,
 * calls the image's PE entry point with (image handle, system table), and
 * describes the machine with ACPI tables rather than a device tree.  Every
 * aarch64 device OSv discovers, it discovers from the device tree, through the
 * dtb_get*() accessors in arch/aarch64/arch-dtb.cc.
 *
 * This file bridges the two.  It runs while EFI boot services are still
 * available and:
 *
 *   1. finds the ACPI RSDP in the EFI configuration table,
 *   2. reads MADT, GTDT, FADT, SPCR and MCFG,
 *   3. synthesizes a device tree blob describing what it found,
 *   4. allocates a 2 MB-aligned home for the kernel below 4 GB and copies the
 *      flat image there,
 *   5. exits boot services, and
 *   6. re-enters the image at "prestart" with x0 = the synthesized DTB,
 *
 * so that from arch-dtb.cc's point of view nothing has changed.  The 110
 * dtb_get* call sites are untouched.
 *
 * WHY A SYNTHESIZED DTB RATHER THAN AN ACPI DISCOVERY PATH
 * -------------------------------------------------------
 * An ACPI path for aarch64, parallel to the x86 drivers/acpi.cc and sitting
 * behind the same accessors, is the better end state and is how Linux and
 * FreeBSD do it.  It is also a large change that cannot be validated until
 * something boots.  Translating in the stub keeps the change additive: no
 * existing aarch64 code path is modified, and the DTB entry contract that is
 * already proven under QEMU/KVM stays the single way the kernel starts.
 *
 * CONSTRAINTS THIS CODE MUST RESPECT, and why
 * ------------------------------------------
 *  * Position independence.  UEFI loads us anywhere, so this file is built
 *    -fpie and must produce no dynamic relocations: no static or global
 *    variables, no initialised pointer tables, no string arrays.  Everything
 *    is a local or an argument.  (The build checks this; see the Makefile.)
 *  * No libc.  Freestanding, with local copies of the two or three byte
 *    helpers needed.
 *  * Everything the kernel will touch early must live below 4 GB, because
 *    boot.S's ident_pt_l3_ttbr0 maps only 0-4 GB one-to-one.
 *  * We must hand the kernel only memory we actually own.  ACPI tables, EFI
 *    runtime code and the firmware's own data all live in "the machine's RAM";
 *    a /memory node covering all of it would have OSv scribble on them.  So we
 *    allocate a block and describe exactly that block.
 */

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;
typedef signed long long   s64;

#define NULL ((void *)0)

/* ------------------------------------------------------------------ *
 * Minimal UEFI bindings.  Only what this stub calls.
 * aarch64 UEFI uses plain AAPCS64, so no calling-convention attribute
 * is needed (unlike x86_64, which needs ms_abi).
 * ------------------------------------------------------------------ */

typedef u64 efi_status;
typedef void *efi_handle;

#define EFI_SUCCESS            0ULL
#define EFI_ALLOCATE_MAX_ADDRESS  1
#define EFI_LOADER_DATA           2
#define EFI_BUFFER_TOO_SMALL   0x8000000000000005ULL

struct efi_table_header {
    u64 signature;
    u32 revision;
    u32 header_size;
    u32 crc32;
    u32 reserved;
};

struct efi_simple_text_output {
    void *reset;
    efi_status (*output_string)(struct efi_simple_text_output *, u16 *);
    void *test_string;
    void *query_mode;
    void *set_mode;
    void *set_attribute;
    void *clear_screen;
    void *set_cursor_position;
    void *enable_cursor;
    void *mode;
};

struct efi_boot_services {
    struct efi_table_header hdr;
    void *raise_tpl;
    void *restore_tpl;
    efi_status (*allocate_pages)(u32 type, u32 mem_type, u64 pages, u64 *memory);
    efi_status (*free_pages)(u64 memory, u64 pages);
    efi_status (*get_memory_map)(u64 *map_size, void *map, u64 *map_key,
                                 u64 *desc_size, u32 *desc_version);
    efi_status (*allocate_pool)(u32 pool_type, u64 size, void **buf);
    efi_status (*free_pool)(void *buf);
    void *create_event;
    void *set_timer;
    void *wait_for_event;
    void *signal_event;
    void *close_event;
    void *check_event;
    void *install_protocol_interface;
    void *reinstall_protocol_interface;
    void *uninstall_protocol_interface;
    void *handle_protocol;
    void *reserved;
    void *register_protocol_notify;
    void *locate_handle;
    void *locate_device_path;
    void *install_configuration_table;
    void *load_image;
    void *start_image;
    void *exit;
    void *unload_image;
    efi_status (*exit_boot_services)(efi_handle image, u64 map_key);
};

/* *** THESE ASSERTS ARE NOT DECORATION. ***
 *
 * EFI_BOOT_SERVICES is a table of bare function pointers with no tags and no
 * self-description, so a single omitted field shifts every later entry by one
 * slot and the compiler cannot see it.  The failure is not a crash: the call
 * lands on a REAL, ADJACENT EFI function which returns a plausible error.
 *
 * This bit us.  An earlier version of this file omitted SignalEvent, so
 * exit_boot_services resolved to UnloadImage, which duly returned
 * EFI_INVALID_PARAMETER (0x8000000000000003).  Everything before the event
 * services (AllocatePages, GetMemoryMap, AllocatePool) worked perfectly, which
 * made it read like a memory-map-key bug and sent the investigation to the
 * retry loop instead of to the struct.
 *
 * Offsets per UEFI 2.10 section 4.4: a 24-byte EFI_TABLE_HEADER followed by
 * 8-byte pointers, so slot N is at 24 + N*8.
 */
_Static_assert(sizeof(struct efi_table_header) == 24,
               "EFI_TABLE_HEADER must be 24 bytes");
_Static_assert(__builtin_offsetof(struct efi_boot_services, allocate_pages) == 24 + 2 * 8,
               "AllocatePages is boot-services slot 2");
_Static_assert(__builtin_offsetof(struct efi_boot_services, get_memory_map) == 24 + 4 * 8,
               "GetMemoryMap is boot-services slot 4");
_Static_assert(__builtin_offsetof(struct efi_boot_services, allocate_pool) == 24 + 5 * 8,
               "AllocatePool is boot-services slot 5");
_Static_assert(__builtin_offsetof(struct efi_boot_services, exit_boot_services) == 24 + 26 * 8,
               "ExitBootServices is boot-services slot 26");

struct efi_guid {
    u32 data1;
    u16 data2;
    u16 data3;
    u8  data4[8];
};

struct efi_config_table_entry {
    struct efi_guid vendor_guid;
    void *vendor_table;
};

struct efi_system_table {
    struct efi_table_header hdr;
    u16 *firmware_vendor;
    u32 firmware_revision;
    efi_handle console_in_handle;
    void *con_in;
    efi_handle console_out_handle;
    struct efi_simple_text_output *con_out;
    efi_handle standard_error_handle;
    void *std_err;
    void *runtime_services;
    struct efi_boot_services *boot_services;
    u64 nr_table_entries;
    struct efi_config_table_entry *config_table;
};

/* Same reasoning as the boot-services asserts above.  A misplaced config_table
 * would make the ACPI search read arbitrary memory and report "no RSDP", which
 * is indistinguishable from a machine that genuinely has no ACPI.
 *
 * These are stated as ABSOLUTE offsets from UEFI 2.10 table 4.3 rather than as
 * "slot N * 8", because EFI_SYSTEM_TABLE is not a uniform array of pointers:
 * FirmwareRevision is a UINT32 followed by four bytes of padding.  (The first
 * version of these asserts used slot arithmetic and failed on a struct that
 * was in fact correct, which is a good argument for checking against the
 * published offsets instead of against a pattern.) */
_Static_assert(__builtin_offsetof(struct efi_system_table, con_out) == 64,
               "ConOut must be at offset 64");
_Static_assert(__builtin_offsetof(struct efi_system_table, boot_services) == 96,
               "BootServices must be at offset 96");
_Static_assert(__builtin_offsetof(struct efi_system_table, nr_table_entries) == 104,
               "NumberOfTableEntries must be at offset 104");
_Static_assert(__builtin_offsetof(struct efi_system_table, config_table) == 112,
               "ConfigurationTable must be at offset 112");

/* ------------------------------------------------------------------ *
 * Byte helpers.  No libc here.
 * ------------------------------------------------------------------ */

static void stub_memcpy(void *dst, const void *src, u64 n)
{
    u8 *d = dst;
    const u8 *s = src;
    while (n--)
        *d++ = *s++;
}

static void stub_memset(void *dst, u8 c, u64 n)
{
    u8 *d = dst;
    while (n--)
        *d++ = c;
}

static int stub_strlen(const char *s)
{
    int n = 0;
    while (s[n])
        n++;
    return n;
}

/* Print an ASCII string on the EFI console.  Converts to UTF-16 in chunks on
 * the stack, so it needs no allocation and works before we own any memory.
 * This is the only diagnostic channel available before ExitBootServices, and
 * on EC2 it lands in the instance serial console, which is the whole point. */
static void stub_puts(struct efi_system_table *st, const char *s)
{
    u16 buf[80];
    int n = 0;

    if (!st->con_out)
        return;
    while (*s) {
        if (*s == '\n')
            buf[n++] = '\r';
        buf[n++] = (u16)(u8)*s++;
        if (n >= 76) {
            buf[n] = 0;
            st->con_out->output_string(st->con_out, buf);
            n = 0;
        }
    }
    buf[n] = 0;
    st->con_out->output_string(st->con_out, buf);
}

static void stub_puthex(struct efi_system_table *st, u64 v)
{
    char buf[19];
    int i;

    buf[0] = '0';
    buf[1] = 'x';
    for (i = 0; i < 16; i++)
        buf[2 + i] = "0123456789abcdef"[(v >> ((15 - i) * 4)) & 0xf];
    buf[18] = 0;
    stub_puts(st, buf);
}

/* Unaligned little-endian readers.  ACPI tables are packed and are NOT
 * guaranteed to be naturally aligned for every field (the MADT GICC MPIDR at
 * offset 0x44 is the standing example: 8 bytes on a 4-byte boundary).  A
 * plain *(u64*) cast there is an alignment fault waiting to happen, so every
 * ACPI read goes through these. */
static u16 rd16(const u8 *p)
{
    return (u16)p[0] | ((u16)p[1] << 8);
}

static u32 rd32(const u8 *p)
{
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

static u64 rd64(const u8 *p)
{
    return (u64)rd32(p) | ((u64)rd32(p + 4) << 32);
}

/* ------------------------------------------------------------------ *
 * Flattened device tree writer.
 *
 * Append-only, single pass, big-endian.  Deliberately not libfdt: libfdt's
 * fdt_sw.c would do this job, but it is compiled into the kernel proper with
 * .rodata pointer tables that this position-independent, relocation-free stub
 * cannot consume.  The subset needed here is small enough to write out.
 *
 * Layout produced:  header | empty mem_rsvmap | struct block | strings block
 * ------------------------------------------------------------------ */

#define FDT_MAGIC        0xd00dfeed
#define FDT_BEGIN_NODE   1
#define FDT_END_NODE     2
#define FDT_PROP         3
#define FDT_END          9

struct fdt_writer {
    u8 *base;        /* start of the buffer                       */
    u64 cap;         /* buffer capacity in bytes                  */
    u64 struct_off;  /* offset of the struct block                */
    u64 struct_len;  /* bytes used in the struct block            */
    u64 strings_off; /* offset of the strings block               */
    u64 strings_len; /* bytes used in the strings block           */
    int overflow;    /* set once anything did not fit             */
};

static void fdt_put_be32(u8 *p, u32 v)
{
    p[0] = (u8)(v >> 24);
    p[1] = (u8)(v >> 16);
    p[2] = (u8)(v >> 8);
    p[3] = (u8)v;
}

static void fdt_emit(struct fdt_writer *w, const void *data, u64 len)
{
    u64 pad = (4 - (len & 3)) & 3;

    if (w->struct_off + w->struct_len + len + pad > w->strings_off) {
        w->overflow = 1;
        return;
    }
    stub_memcpy(w->base + w->struct_off + w->struct_len, data, len);
    w->struct_len += len;
    stub_memset(w->base + w->struct_off + w->struct_len, 0, pad);
    w->struct_len += pad;
}

static void fdt_emit_be32(struct fdt_writer *w, u32 v)
{
    u8 t[4];

    fdt_put_be32(t, v);
    fdt_emit(w, t, 4);
}

/* Intern a property name in the strings block.  No dedup: libfdt does not
 * require it and the tree is a couple of dozen properties. */
static u32 fdt_string(struct fdt_writer *w, const char *s)
{
    u64 len = (u64)stub_strlen(s) + 1;
    u64 off = w->strings_len;

    if (w->strings_off + w->strings_len + len > w->cap) {
        w->overflow = 1;
        return 0;
    }
    stub_memcpy(w->base + w->strings_off + w->strings_len, s, len);
    w->strings_len += len;
    return (u32)off;
}

static void fdt_begin_node(struct fdt_writer *w, const char *name)
{
    fdt_emit_be32(w, FDT_BEGIN_NODE);
    fdt_emit(w, name, (u64)stub_strlen(name) + 1);
}

static void fdt_end_node(struct fdt_writer *w)
{
    fdt_emit_be32(w, FDT_END_NODE);
}

static void fdt_prop(struct fdt_writer *w, const char *name,
                     const void *val, u64 len)
{
    u32 nameoff = fdt_string(w, name);

    fdt_emit_be32(w, FDT_PROP);
    fdt_emit_be32(w, (u32)len);
    fdt_emit_be32(w, nameoff);
    if (len)
        fdt_emit(w, val, len);
}

static void fdt_prop_empty(struct fdt_writer *w, const char *name)
{
    fdt_prop(w, name, NULL, 0);
}

static void fdt_prop_str(struct fdt_writer *w, const char *name, const char *s)
{
    fdt_prop(w, name, s, (u64)stub_strlen(s) + 1);
}

static void fdt_prop_u32(struct fdt_writer *w, const char *name, u32 v)
{
    u8 t[4];

    fdt_put_be32(t, v);
    fdt_prop(w, name, t, 4);
}

/* A <u32 ...> cell array, up to 12 cells, which covers the widest property
 * this stub writes (the timer's 4 interrupt specifiers = 12 cells). */
static void fdt_prop_cells(struct fdt_writer *w, const char *name,
                           const u32 *cells, int n)
{
    u8 t[48];
    int i;

    for (i = 0; i < n; i++)
        fdt_put_be32(t + i * 4, cells[i]);
    fdt_prop(w, name, t, (u64)n * 4);
}

/* reg = <addr size> with #address-cells = <2>, #size-cells = <2>. */
static void fdt_prop_reg(struct fdt_writer *w, const char *name,
                         const u64 *addr, const u64 *size, int pairs)
{
    u32 cells[12];
    int i;

    for (i = 0; i < pairs; i++) {
        cells[i * 4 + 0] = (u32)(addr[i] >> 32);
        cells[i * 4 + 1] = (u32)addr[i];
        cells[i * 4 + 2] = (u32)(size[i] >> 32);
        cells[i * 4 + 3] = (u32)size[i];
    }
    fdt_prop_cells(w, name, cells, pairs * 4);
}

static void fdt_writer_init(struct fdt_writer *w, void *buf, u64 cap)
{
    w->base = buf;
    w->cap = cap;
    /* header is 40 bytes, then an empty (terminator-only) reserve map */
    w->struct_off = 40 + 16;
    w->struct_len = 0;
    /* Put the strings block in the second half.  Both blocks grow towards
     * each other and fdt_emit/fdt_string check the meeting point. */
    w->strings_off = cap / 2;
    w->strings_len = 0;
    w->overflow = 0;
    stub_memset(buf, 0, w->struct_off);
}

/* Close the tree and write the header.  The struct and strings blocks are
 * made adjacent so the result is a normal, packed DTB.
 * Returns the total size, or 0 if anything overflowed. */
static u64 fdt_writer_finish(struct fdt_writer *w)
{
    u8 *h = w->base;
    u64 strings_dst;

    fdt_emit_be32(w, FDT_END);
    if (w->overflow)
        return 0;

    strings_dst = w->struct_off + w->struct_len;
    /* memmove semantics: destination is strictly below the source, so a
     * forward copy is safe. */
    stub_memcpy(h + strings_dst, h + w->strings_off, w->strings_len);

    fdt_put_be32(h + 0,  FDT_MAGIC);
    fdt_put_be32(h + 4,  (u32)(strings_dst + w->strings_len));
    fdt_put_be32(h + 8,  (u32)w->struct_off);
    fdt_put_be32(h + 12, (u32)strings_dst);
    fdt_put_be32(h + 16, 40);            /* off_mem_rsvmap                */
    fdt_put_be32(h + 20, 17);            /* version                       */
    fdt_put_be32(h + 24, 16);            /* last_comp_version             */
    fdt_put_be32(h + 28, 0);             /* boot_cpuid_phys               */
    fdt_put_be32(h + 32, (u32)w->strings_len);
    fdt_put_be32(h + 36, (u32)w->struct_len);
    return strings_dst + w->strings_len;
}

/* ------------------------------------------------------------------ *
 * ACPI
 * ------------------------------------------------------------------ */

#define ACPI_HDR_LEN     36

/* MADT (signature "APIC") interrupt controller structure types, ACPI 6.x
 * table 5.21. */
#define MADT_GICC        0x0B
#define MADT_GICD        0x0C
#define MADT_GIC_MSI     0x0D
#define MADT_GICR        0x0E
#define MADT_GIC_ITS     0x0F

/* Field offsets inside a MADT GICC (type 0x0B) structure. */
#define GICC_FLAGS       0x0C
#define GICC_PHYS_BASE   0x20   /* GICv2 CPU interface                     */
#define GICC_GICR_BASE   0x3C
#define GICC_MPIDR       0x44

/* MADT GICD (type 0x0C). */
#define GICD_PHYS_BASE   0x08
#define GICD_VERSION     0x14

/* MADT GICR (type 0x0E). */
#define GICR_RANGE_BASE  0x04
#define GICR_RANGE_LEN   0x0C

/* MADT GIC ITS (type 0x0F). */
#define GITS_PHYS_BASE   0x08

/* GTDT field offsets, ACPI 6.x table 5.117. */
#define GTDT_SEC_EL1_GSIV    0x30
#define GTDT_SEC_EL1_FLAGS   0x34
#define GTDT_NS_EL1_GSIV     0x38
#define GTDT_NS_EL1_FLAGS    0x3C
#define GTDT_VIRT_EL1_GSIV   0x40
#define GTDT_VIRT_EL1_FLAGS  0x44
#define GTDT_NS_EL2_GSIV     0x48
#define GTDT_NS_EL2_FLAGS    0x4C

/* FADT ARM boot architecture flags, ACPI 6.x section 5.2.9. */
#define FADT_ARM_BOOT_ARCH   0x81
#define FADT_PSCI_COMPLIANT  (1 << 0)
#define FADT_PSCI_USE_HVC    (1 << 1)

/* SPCR field offsets, Microsoft Serial Port Console Redirection table. */
#define SPCR_IFACE_TYPE      0x24
#define SPCR_BASE_ADDR       0x2C   /* Address field of the GAS at 0x28   */
#define SPCR_INTERRUPT_TYPE  0x34
#define SPCR_GSIV            0x36

/* SPCR interface types that are PL011 register compatible for the console
 * subset OSv's driver touches. */
#define SPCR_IFACE_PL011     0x03
#define SPCR_IFACE_SBSA32    0x0D
#define SPCR_IFACE_SBSA      0x0E
#define SPCR_IFACE_16550     0x00
#define SPCR_IFACE_16550_DBG 0x12

/* MCFG: first allocation structure starts after an 8-byte reserved field. */
#define MCFG_FIRST_ALLOC     (ACPI_HDR_LEN + 8)

/* What we managed to learn about the machine.  Passed around by pointer; no
 * statics, because this file must produce no relocations. */
struct machine {
    u64 gicd_base;
    int gic_version;
    u64 gicr_base;
    u64 gicr_len;
    u64 gicc_base;        /* GICv2 CPU interface                          */
    u64 its_base;
    u64 v2m_base;

    u64 mpidr[256];
    int nr_cpus;

    u32 timer_gsiv[4];    /* secure EL1, non-secure EL1, virtual, EL2     */
    u32 timer_flags[4];
    int have_timer;

    u64 uart_base;
    u32 uart_gsiv;
    int uart_kind;        /* SPCR interface type                          */

    u64 ecam_base;
    int have_ecam;

    int psci;             /* 0 = none, 1 = present                        */
    int psci_hvc;         /* 1 = hvc conduit, 0 = smc                     */
};

static int sig_is(const u8 *t, const char *s)
{
    return t[0] == (u8)s[0] && t[1] == (u8)s[1] &&
           t[2] == (u8)s[2] && t[3] == (u8)s[3];
}

static const u8 *acpi_find_rsdp(struct efi_system_table *st)
{
    u64 i;

    /* ACPI 2.0+ table GUID: 8868e871-e4f1-11d3-bc22-0080c73c8881.
     * Checked before the 1.0 GUID (eb9d2d30-...) because we want the XSDT. */
    for (i = 0; i < st->nr_table_entries; i++) {
        struct efi_guid *g = &st->config_table[i].vendor_guid;

        if (g->data1 == 0x8868e871 && g->data2 == 0xe4f1 && g->data3 == 0x11d3 &&
            g->data4[0] == 0xbc && g->data4[1] == 0x22 && g->data4[2] == 0x00 &&
            g->data4[3] == 0x80 && g->data4[4] == 0xc7 && g->data4[5] == 0x3c &&
            g->data4[6] == 0x88 && g->data4[7] == 0x81)
            return st->config_table[i].vendor_table;
    }
    return NULL;
}

static void acpi_parse_madt(const u8 *madt, struct machine *m)
{
    u32 len = rd32(madt + 4);
    u32 off = ACPI_HDR_LEN + 8;   /* skip LocalApicAddress + Flags */
    u64 gicr_from_gicc_lo = 0;
    u64 gicr_from_gicc_hi = 0;

    while (off + 2 <= len) {
        u8 type = madt[off];
        u8 elen = madt[off + 1];
        const u8 *e = madt + off;

        if (elen < 2 || off + elen > len)
            break;

        switch (type) {
        case MADT_GICC:
            /* Only enabled CPUs.  A disabled GICC is a socket that is not
             * populated or a core the firmware has parked; handing its MPIDR
             * to smp_launch() would PSCI-on something that never answers and
             * smp_launch() spins forever waiting for it. */
            if (elen >= GICC_MPIDR + 8 &&
                (rd32(e + GICC_FLAGS) & 1) &&
                m->nr_cpus < (int)(sizeof(m->mpidr) / sizeof(m->mpidr[0]))) {
                u64 gicr = (elen >= GICC_GICR_BASE + 8) ?
                            rd64(e + GICC_GICR_BASE) : 0;

                m->mpidr[m->nr_cpus++] = rd64(e + GICC_MPIDR);
                if (!m->gicc_base)
                    m->gicc_base = rd64(e + GICC_PHYS_BASE);
                if (gicr) {
                    if (!gicr_from_gicc_lo || gicr < gicr_from_gicc_lo)
                        gicr_from_gicc_lo = gicr;
                    if (gicr > gicr_from_gicc_hi)
                        gicr_from_gicc_hi = gicr;
                }
            }
            break;
        case MADT_GICD:
            if (elen >= GICD_VERSION + 1) {
                m->gicd_base = rd64(e + GICD_PHYS_BASE);
                m->gic_version = e[GICD_VERSION];
            }
            break;
        case MADT_GICR:
            if (elen >= GICR_RANGE_LEN + 4) {
                m->gicr_base = rd64(e + GICR_RANGE_BASE);
                m->gicr_len = rd32(e + GICR_RANGE_LEN);
            }
            break;
        case MADT_GIC_ITS:
            if (elen >= GITS_PHYS_BASE + 8 && !m->its_base)
                m->its_base = rd64(e + GITS_PHYS_BASE);
            break;
        case MADT_GIC_MSI:
            if (elen >= 0x10 && !m->v2m_base)
                m->v2m_base = rd64(e + 0x08);
            break;
        default:
            break;
        }
        off += elen;
    }

    /* Some firmware describes redistributors per-CPU in the GICC entries and
     * omits the GICR discovery range.  OSv's gic_v3_redist walks the range
     * from a single base by GICR_STRIDE, so a contiguous span derived from
     * the per-CPU bases is an equivalent description. */
    if (!m->gicr_base && gicr_from_gicc_lo) {
        m->gicr_base = gicr_from_gicc_lo;
        m->gicr_len = (gicr_from_gicc_hi - gicr_from_gicc_lo) + 0x20000;
    }
}

static void acpi_parse_gtdt(const u8 *gtdt, struct machine *m)
{
    u32 len = rd32(gtdt + 4);

    if (len < GTDT_NS_EL2_FLAGS + 4)
        return;
    m->timer_gsiv[0]  = rd32(gtdt + GTDT_SEC_EL1_GSIV);
    m->timer_flags[0] = rd32(gtdt + GTDT_SEC_EL1_FLAGS);
    m->timer_gsiv[1]  = rd32(gtdt + GTDT_NS_EL1_GSIV);
    m->timer_flags[1] = rd32(gtdt + GTDT_NS_EL1_FLAGS);
    m->timer_gsiv[2]  = rd32(gtdt + GTDT_VIRT_EL1_GSIV);
    m->timer_flags[2] = rd32(gtdt + GTDT_VIRT_EL1_FLAGS);
    m->timer_gsiv[3]  = rd32(gtdt + GTDT_NS_EL2_GSIV);
    m->timer_flags[3] = rd32(gtdt + GTDT_NS_EL2_FLAGS);
    m->have_timer = 1;
}

static void acpi_parse_fadt(const u8 *fadt, struct machine *m)
{
    u32 len = rd32(fadt + 4);
    u16 flags;

    if (len < FADT_ARM_BOOT_ARCH + 2)
        return;
    flags = rd16(fadt + FADT_ARM_BOOT_ARCH);
    if (flags & FADT_PSCI_COMPLIANT) {
        m->psci = 1;
        m->psci_hvc = (flags & FADT_PSCI_USE_HVC) ? 1 : 0;
    }
}

static void acpi_parse_spcr(const u8 *spcr, struct machine *m)
{
    u32 len = rd32(spcr + 4);

    if (len < SPCR_GSIV + 4)
        return;
    m->uart_kind = spcr[SPCR_IFACE_TYPE];
    m->uart_base = rd64(spcr + SPCR_BASE_ADDR);
    m->uart_gsiv = rd32(spcr + SPCR_GSIV);
}

static void acpi_parse_mcfg(const u8 *mcfg, struct machine *m)
{
    u32 len = rd32(mcfg + 4);

    if (len < MCFG_FIRST_ALLOC + 16)
        return;
    m->ecam_base = rd64(mcfg + MCFG_FIRST_ALLOC);
    m->have_ecam = 1;
}

static void acpi_scan(struct efi_system_table *st, struct machine *m)
{
    const u8 *rsdp = acpi_find_rsdp(st);
    const u8 *xsdt;
    u32 xsdt_len;
    u32 i, n;

    if (!rsdp) {
        stub_puts(st, "osv-efi: no ACPI RSDP in the EFI configuration table\n");
        return;
    }
    xsdt = (const u8 *)(unsigned long)rd64(rsdp + 0x18);
    if (!xsdt || !sig_is(xsdt, "XSDT")) {
        stub_puts(st, "osv-efi: no XSDT\n");
        return;
    }
    xsdt_len = rd32(xsdt + 4);
    if (xsdt_len < ACPI_HDR_LEN)
        return;
    n = (xsdt_len - ACPI_HDR_LEN) / 8;

    for (i = 0; i < n; i++) {
        const u8 *t = (const u8 *)(unsigned long)rd64(xsdt + ACPI_HDR_LEN + i * 8);

        if (!t)
            continue;
        if (sig_is(t, "APIC"))
            acpi_parse_madt(t, m);
        else if (sig_is(t, "GTDT"))
            acpi_parse_gtdt(t, m);
        else if (sig_is(t, "FACP"))
            acpi_parse_fadt(t, m);
        else if (sig_is(t, "SPCR"))
            acpi_parse_spcr(t, m);
        else if (sig_is(t, "MCFG"))
            acpi_parse_mcfg(t, m);
    }
}

/* ------------------------------------------------------------------ *
 * ACPI -> device tree
 * ------------------------------------------------------------------ */

/* Turn a GSIV into the three cells of an "interrupts" entry as
 * arch-dtb.cc's dtb_get_int_spec() reads them.  That function accepts only
 * cell 0 == 0 (SPI, base 32) or 1 (PPI, base 16) and then computes
 * irq_id = base + cell1, so for either kind irq_id comes out equal to the
 * GSIV.  ACPI GTDT/SPCR flags use bit 0 for edge(1)/level(0) triggering,
 * which is the inverse sense of the device tree's IRQ_TYPE encoding, so it is
 * translated rather than copied. */
static void gsiv_cells(u32 gsiv, u32 flags, u32 *out)
{
    int edge = (flags & 1) != 0;
    int low  = (flags & 2) != 0;

    if (gsiv >= 16 && gsiv < 32) {
        out[0] = 1;              /* PPI, base 16 */
        out[1] = gsiv - 16;
    } else {
        out[0] = 0;              /* SPI, base 32 */
        out[1] = gsiv - 32;
    }
    if (edge)
        out[2] = low ? 2 : 1;    /* IRQ_TYPE_EDGE_FALLING / _RISING */
    else
        out[2] = low ? 8 : 4;    /* IRQ_TYPE_LEVEL_LOW / _HIGH      */
}

/* Emit a node name of the form "<base-name>@<hex addr>", which is what
 * dtb_get_mmio_serial_console() and human readers both expect. */
static void node_name_at(char *out, const char *stem, u64 addr)
{
    int i = 0;
    int shift = 60;
    int started = 0;

    while (stem[i]) {
        out[i] = stem[i];
        i++;
    }
    out[i++] = '@';
    while (shift >= 0) {
        u32 nib = (u32)((addr >> shift) & 0xf);

        if (nib || started || shift == 0) {
            out[i++] = "0123456789abcdef"[nib];
            started = 1;
        }
        shift -= 4;
    }
    out[i] = 0;
}

/* Build the device tree OSv/aarch64 expects.  Every node here exists because
 * a named dtb_get*() accessor looks for it; nothing is emitted "for
 * completeness". */
static u64 build_dtb(struct machine *m, void *buf, u64 cap,
                     u64 mem_base, u64 mem_size, const char *cmdline)
{
    struct fdt_writer w;
    u32 cells[12];
    u64 addr[2], size[2];
    char name[32];
    int i;

    fdt_writer_init(&w, buf, cap);

    fdt_begin_node(&w, "");
    fdt_prop_u32(&w, "#address-cells", 2);
    fdt_prop_u32(&w, "#size-cells", 2);
    fdt_prop_str(&w, "compatible", "osv,efi-synthesized");
    fdt_prop_str(&w, "model", "OSv UEFI stub synthesized from ACPI");

    /* /chosen/bootargs.  dtb_setup() prefers this over the cmdline pointer in
     * x4, so putting it here makes the stub the single source of the command
     * line and removes the need for fdt_setprop() slack in this buffer. */
    fdt_begin_node(&w, "chosen");
    fdt_prop_str(&w, "bootargs", cmdline);
    fdt_end_node(&w);

    /* /memory: read by dtb_get_phys_memory() into memory::phys_mem_size and
     * mmu::mem_addr.  This describes ONLY the block the stub allocated, which
     * is the whole point: OSv treats this range as free and will write over
     * anything inside it. */
    node_name_at(name, "memory", mem_base);
    fdt_begin_node(&w, name);
    fdt_prop_str(&w, "device_type", "memory");
    addr[0] = mem_base;
    size[0] = mem_size;
    fdt_prop_reg(&w, "reg", addr, size, 1);
    fdt_end_node(&w);

    /* /cpus: dtb_parse_cpus() counts subnodes with device_type = "cpu" and
     * takes each reg as the MPIDR.  #address-cells must live on /cpus rather
     * than on the cpu node, because dtb_getprop_u32_cascade() starts at the
     * PARENT.  #size-cells is required even though it is zero: dtb_get_reg()
     * bails out if the cascade for it fails. */
    fdt_begin_node(&w, "cpus");
    fdt_prop_u32(&w, "#address-cells", 2);
    fdt_prop_u32(&w, "#size-cells", 0);
    for (i = 0; i < m->nr_cpus; i++) {
        node_name_at(name, "cpu", m->mpidr[i]);
        fdt_begin_node(&w, name);
        fdt_prop_str(&w, "device_type", "cpu");
        fdt_prop_str(&w, "compatible", "arm,armv8");
        fdt_prop_str(&w, "enable-method", "psci");
        cells[0] = (u32)(m->mpidr[i] >> 32);
        cells[1] = (u32)m->mpidr[i];
        fdt_prop_cells(&w, "reg", cells, 2);
        fdt_end_node(&w);
    }
    fdt_end_node(&w);

    /* /timer: dtb_parse_timer_irq() requires exactly four interrupt
     * specifiers and uses index 2, the EL1 virtual timer. */
    if (m->have_timer) {
        fdt_begin_node(&w, "timer");
        fdt_prop_str(&w, "compatible", "arm,armv8-timer");
        fdt_prop_empty(&w, "always-on");
        for (i = 0; i < 4; i++)
            gsiv_cells(m->timer_gsiv[i], m->timer_flags[i], &cells[i * 3]);
        fdt_prop_cells(&w, "interrupts", cells, 12);
        fdt_end_node(&w);
    }

    /* /psci: dtb_get_psci_method() aborts the boot if it cannot find this,
     * and smp_launch() needs cpu_on to bring up secondaries. */
    if (m->psci) {
        fdt_begin_node(&w, "psci");
        fdt_prop_str(&w, "compatible", "arm,psci-1.0");
        fdt_prop_str(&w, "method", m->psci_hvc ? "hvc" : "smc");
        fdt_end_node(&w);
    }

    /* The serial console.  SPCR interface types 0x03 (PL011), 0x0d and 0x0e
     * (SBSA generic UART) are all PL011 register compatible over the transmit
     * path OSv's driver uses, so all three are described as "arm,pl011".
     * 16550-style ports get the ns16550a node that
     * dtb_get_mmio_serial_console() looks for, which is why the node name
     * must be "uart@<hex>": that accessor sscanf()s the address back out of
     * the node name rather than reading reg. */
    if (m->uart_base) {
        int is_16550 = (m->uart_kind == SPCR_IFACE_16550 ||
                        m->uart_kind == SPCR_IFACE_16550_DBG);

        node_name_at(name, is_16550 ? "uart" : "pl011", m->uart_base);
        fdt_begin_node(&w, name);
        fdt_prop_str(&w, "compatible", is_16550 ? "ns16550a" : "arm,pl011");
        addr[0] = m->uart_base;
        size[0] = 0x1000;
        fdt_prop_reg(&w, "reg", addr, size, 1);
        /* A GSIV of 0 means "no interrupt" (SBSA consoles are often polled).
         * Emitting a bogus specifier would have OSv enable a spurious SPI, so
         * the property is simply omitted. */
        if (m->uart_gsiv) {
            gsiv_cells(m->uart_gsiv, 0, cells);
            fdt_prop_cells(&w, "interrupts", cells, 3);
        }
        fdt_end_node(&w);
    }

    /* The interrupt controller.  dtb_get_gic_v3() wants two reg pairs,
     * distributor then redistributor; dtb_get_gic_v2() wants distributor then
     * CPU interface. */
    if (m->gicd_base && m->gic_version >= 3 && m->gicr_base) {
        node_name_at(name, "intc", m->gicd_base);
        fdt_begin_node(&w, name);
        fdt_prop_str(&w, "compatible", "arm,gic-v3");
        fdt_prop_empty(&w, "interrupt-controller");
        fdt_prop_u32(&w, "#interrupt-cells", 3);
        addr[0] = m->gicd_base;
        size[0] = 0x10000;
        addr[1] = m->gicr_base;
        size[1] = m->gicr_len;
        fdt_prop_reg(&w, "reg", addr, size, 2);
        fdt_end_node(&w);

        if (m->its_base) {
            node_name_at(name, "its", m->its_base);
            fdt_begin_node(&w, name);
            fdt_prop_str(&w, "compatible", "arm,gic-v3-its");
            fdt_prop_empty(&w, "msi-controller");
            addr[0] = m->its_base;
            size[0] = 0x20000;
            fdt_prop_reg(&w, "reg", addr, size, 1);
            fdt_end_node(&w);
        }
    } else if (m->gicd_base && m->gicc_base) {
        node_name_at(name, "intc", m->gicd_base);
        fdt_begin_node(&w, name);
        fdt_prop_str(&w, "compatible", "arm,cortex-a15-gic");
        fdt_prop_empty(&w, "interrupt-controller");
        fdt_prop_u32(&w, "#interrupt-cells", 3);
        addr[0] = m->gicd_base;
        size[0] = 0x10000;
        addr[1] = m->gicc_base;
        size[1] = 0x2000;
        fdt_prop_reg(&w, "reg", addr, size, 2);
        fdt_end_node(&w);

        if (m->v2m_base) {
            node_name_at(name, "v2m", m->v2m_base);
            fdt_begin_node(&w, name);
            fdt_prop_str(&w, "compatible", "arm,gic-v2m-frame");
            fdt_prop_empty(&w, "msi-controller");
            addr[0] = m->v2m_base;
            size[0] = 0x1000;
            fdt_prop_reg(&w, "reg", addr, size, 1);
            fdt_end_node(&w);
        }
    }

    /* NO PCI NODE IS EMITTED, DELIBERATELY, AND THIS IS THE ONE PLACE WHERE
     * ACPI CANNOT BE TRANSLATED STATICALLY.  MCFG gives the ECAM base, but
     * dtb_get_pci_ranges() needs the host bridge's memory and I/O windows and
     * dtb_get_pci_irqmap() needs its interrupt routing, and on ACPI both of
     * those live in the DSDT as a _CRS / _PRT, i.e. behind an AML
     * interpreter.  arch_setup_pci() returns early when dtb_get_pci_cfg()
     * fails and arch_init_drivers() skips enumeration when the config space
     * is unset, so omitting the node yields a correct PCI-less boot rather
     * than a wrong one.  A guessed window would silently mis-program BARs.
     * Closing this gap is what an ACPI discovery path (with AML, or with the
     * _CRS decoded by the ACPICA already vendored for x86) is for. */
    (void)m->have_ecam;

    fdt_end_node(&w);   /* / */

    return fdt_writer_finish(&w);
}

/* ------------------------------------------------------------------ *
 * Entry
 * ------------------------------------------------------------------ */

#define IMAGE_TEXT_OFFSET   0x80000     /* arm64 Image load offset        */
#define TWO_MB              0x200000ULL
#define DTB_BYTES           0x10000ULL
#define LOW_MEM_LIMIT       0x100000000ULL   /* boot.S ident-maps 0-4 GB  */

static u64 align_up(u64 v, u64 a)
{
    return (v + a - 1) & ~(a - 1);
}

/* Implemented in preboot.S: turns the MMU and caches off, drops to EL1 if the
 * firmware left us at EL2, and branches to the relocated image with
 * x0 = DTB physical address.  Never returns. */
extern void osv_efi_enter_kernel(u64 image_base, u64 dtb, u64 image_size);

/* Called from the PE entry trampoline in preboot.S.
 *
 * image_start is the runtime address of our own first byte, obtained
 * PC-relatively by the caller rather than from the PE ImageBase, so it is
 * correct wherever the firmware put us. */
efi_status osv_efi_main(efi_handle image_handle, struct efi_system_table *st,
                        u64 image_start)
{
    struct efi_boot_services *bs = st->boot_services;
    struct machine m;
    u64 image_size;
    u64 want, alloc_base = 0, alloc_size = 0;
    u64 kernel_base, dtb_phys, dtb_len;
    u64 map_size = 0, map_key = 0, desc_size = 0;
    u32 desc_version = 0;
    void *map = NULL;
    efi_status rc;
    int attempt;

    stub_puts(st, "\nosv-efi: OSv UEFI stub, aarch64\n");

    /* The flat image's own arm64 Image header carries the memory footprint at
     * offset 0x10 (patched by scripts/imgedit.py setsize_aarch64).  It covers
     * .bss, so it is an upper bound on the bytes we must move and the exact
     * amount of room the kernel needs. */
    image_size = rd64((const u8 *)(unsigned long)image_start + 0x10);
    if (image_size < 0x10000 || image_size > 0x10000000) {
        stub_puts(st, "osv-efi: implausible image size ");
        stub_puthex(st, image_size);
        stub_puts(st, ", refusing to boot\n");
        return EFI_SUCCESS;
    }

    stub_memset(&m, 0, sizeof(m));
    acpi_scan(st, &m);

    /* Allocate the block OSv will own.  Descending sizes so a small instance
     * still boots; below 4 GB because boot.S's boot page tables only ident-map
     * that much, which is the same constraint #1490 was about.
     *
     * ponytail: the guest gets what the stub allocates, not all machine RAM.
     * Lifting it means describing several /memory ranges from the EFI memory
     * map AND extending the boot-time ident map past 4 GB. */
    want = align_up(image_size + IMAGE_TEXT_OFFSET + DTB_BYTES + TWO_MB * 2,
                    TWO_MB);
    for (attempt = 0; attempt < 8; attempt++) {
        u64 try_size = 3ULL << 30;   /* 3 GB, then halve */
        u64 pages;
        int i;

        for (i = 0; i < attempt; i++)
            try_size >>= 1;
        if (try_size < want)
            try_size = want;
        pages = align_up(try_size, 0x1000) / 0x1000;
        alloc_base = LOW_MEM_LIMIT - 1;
        rc = bs->allocate_pages(EFI_ALLOCATE_MAX_ADDRESS, EFI_LOADER_DATA,
                                pages, &alloc_base);
        if (rc == EFI_SUCCESS) {
            alloc_size = pages * 0x1000;
            break;
        }
        alloc_size = 0;
        if (try_size == want)
            break;
    }
    if (!alloc_size) {
        stub_puts(st, "osv-efi: could not allocate memory below 4 GB\n");
        return EFI_SUCCESS;
    }

    /* OSv's physical layout, from the comment in arch_setup_free_memory():
     *   mem_addr + 0x00000 .. 0x80000  boot
     *   mem_addr + 0x80000 .. 0x90000  the DTB copy dtb_setup() makes
     *   mem_addr + 0x90000 ..          the kernel ELF
     * and boot.S derives the 63 GB kernel mapping by rounding text_start down
     * to 2 MB, which only lands correctly when the flat image starts exactly
     * 0x80000 above a 2 MB boundary.  That is the arm64 Image protocol's
     * text_offset, and getting it wrong does not fail cleanly: the kernel maps
     * the wrong 2 MB and faults with the MMU half on. */
    kernel_base = align_up(alloc_base, TWO_MB) + IMAGE_TEXT_OFFSET;
    dtb_phys = align_up(kernel_base + image_size, 0x1000);

    if (dtb_phys + DTB_BYTES > alloc_base + alloc_size) {
        stub_puts(st, "osv-efi: allocation too small for image + DTB\n");
        return EFI_SUCCESS;
    }

    /* The cmdline lives at image_start + 0x200 in the flat image, written
     * there by scripts/imgedit.py setargs, exactly as the QEMU path expects. */
    dtb_len = build_dtb(&m, (void *)(unsigned long)dtb_phys, DTB_BYTES,
                        align_up(alloc_base, TWO_MB),
                        (alloc_base + alloc_size) - align_up(alloc_base, TWO_MB),
                        (const char *)(unsigned long)(image_start + 0x200));
    if (!dtb_len) {
        stub_puts(st, "osv-efi: device tree did not fit\n");
        return EFI_SUCCESS;
    }

    stub_puts(st, "osv-efi: cpus ");
    stub_puthex(st, (u64)m.nr_cpus);
    stub_puts(st, " gic v");
    stub_puthex(st, (u64)m.gic_version);
    stub_puts(st, " gicd ");
    stub_puthex(st, m.gicd_base);
    /* Print whichever of the two is meaningful for this GIC generation.  A
     * bare "gicr 0x0" on a GICv2 machine reads like a parse failure when it
     * is simply the wrong question. */
    if (m.gic_version >= 3) {
        stub_puts(st, " gicr ");
        stub_puthex(st, m.gicr_base);
        stub_puts(st, " len ");
        stub_puthex(st, m.gicr_len);
    } else {
        stub_puts(st, " gicc ");
        stub_puthex(st, m.gicc_base);
    }
    stub_puts(st, "\nosv-efi: uart ");
    stub_puthex(st, m.uart_base);
    stub_puts(st, " kind ");
    stub_puthex(st, (u64)m.uart_kind);
    /* The UART's own GSIV matters as much as its address: dtb_get_uart() and
     * dtb_get_mmio_serial_console() BOTH return 0 when the interrupt specifier
     * is missing, and arch_init_early_console() then silently falls back to the
     * PL011 default base of 0x9000000.  On a machine whose console is not there
     * that produces a completely silent boot, so this value is the difference
     * between a diagnosable failure and an invisible one. */
    stub_puts(st, " uart_gsiv ");
    stub_puthex(st, (u64)m.uart_gsiv);
    stub_puts(st, " timer_virt_gsiv ");
    stub_puthex(st, (u64)m.timer_gsiv[2]);
    stub_puts(st, "\nosv-efi: psci ");
    stub_puts(st, m.psci ? (m.psci_hvc ? "hvc" : "smc") : "NONE");
    stub_puts(st, " kernel at ");
    stub_puthex(st, kernel_base);
    stub_puts(st, " dtb at ");
    stub_puthex(st, dtb_phys);
    stub_puts(st, "\n");

    /* Refuse to continue without the three things whose absence makes the
     * kernel abort() or spin with no console, rather than jumping and leaving
     * a silent box.  A diagnostic here is worth more than a hang there. */
    if (!m.gicd_base || !m.nr_cpus || !m.have_timer) {
        stub_puts(st, "osv-efi: ACPI did not describe GIC, CPUs and timer; "
                      "not booting\n");
        return EFI_SUCCESS;
    }

    /* Move the image to its aligned home.  Copying before ExitBootServices
     * keeps the console available for the messages above. */
    stub_memcpy((void *)(unsigned long)kernel_base,
                (const void *)(unsigned long)image_start, image_size);

    /* ExitBootServices takes the memory map KEY, and rejects a stale one.  The
     * map has to be fetched even though this stub does not otherwise use it.
     *
     * *** THE ORDER HERE MATTERS AND THE OBVIOUS RETRY IS SELF-DEFEATING. ***
     * AllocatePool itself modifies the memory map, and therefore invalidates
     * the key.  A retry that allocates a fresh buffer each time round can
     * never converge: it changes the very thing it is re-reading.  (Measured,
     * not theorised: the first version of this file did exactly that and
     * failed ExitBootServices on every attempt under AAVMF.)
     *
     * So: allocate ONCE, with slack for the few descriptors that
     * AllocatePool's own bookkeeping may add, then loop GetMemoryMap ->
     * ExitBootServices with NO allocation inside the loop.
     */
    rc = bs->get_memory_map(&map_size, NULL, &map_key, &desc_size,
                            &desc_version);
    if (rc != EFI_BUFFER_TOO_SMALL) {
        stub_puts(st, "osv-efi: GetMemoryMap(size) failed\n");
        return EFI_SUCCESS;
    }
    /* Slack for descriptors created by the AllocatePool below, plus room for
     * the map to grow between iterations of the loop. */
    map_size += 16 * desc_size;
    if (bs->allocate_pool(EFI_LOADER_DATA, map_size, &map) != EFI_SUCCESS) {
        stub_puts(st, "osv-efi: AllocatePool for the memory map failed\n");
        return EFI_SUCCESS;
    }

    stub_puts(st, "osv-efi: exiting boot services\n");
    for (attempt = 0; attempt < 4; attempt++) {
        u64 this_size = map_size;

        rc = bs->get_memory_map(&this_size, map, &map_key, &desc_size,
                                &desc_version);
        if (rc != EFI_SUCCESS)
            break;
        rc = bs->exit_boot_services(image_handle, map_key);
        if (rc == EFI_SUCCESS)
            break;
    }
    if (rc != EFI_SUCCESS) {
        stub_puts(st, "osv-efi: ExitBootServices failed, status ");
        stub_puthex(st, rc);
        stub_puts(st, "\n");
        return rc;
    }

    /* No EFI service may be called from here on. */
    osv_efi_enter_kernel(kernel_base, dtb_phys, image_size);
    return EFI_SUCCESS;   /* not reached */
}
