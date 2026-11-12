/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// PCI host bridge discovery from ACPI, for aarch64 machines booted by UEFI
// firmware (for example EC2 Graviton), which describe PCI only in ACPI.
//
// The static tables give the configuration space (MCFG) and the MSI device ID
// mapping (IORT).  The bus range, the MMIO and I/O windows and the INTx
// routing are AML in the DSDT: the root bridge's _CRS and _PRT, evaluated
// here with ACPICA.  The result feeds the same pci:: setters that the device
// tree path in arch-setup.cc uses, so enumeration and the drivers above it do
// not know which firmware interface described the bridge.

#include <osv/debug.hh>
#include <osv/mmu.hh>
#include <osv/pci.hh>
#include <osv/prio.hh>
#include <algorithm>
#include <vector>

extern "C" {
#include "acpi.h"
}

#include "drivers/acpi.hh"
#include "acpi-pci.hh"
#include "arch-dtb.hh"

namespace acpi_pci {

static bool found;
static u32 iort_rid_base, iort_id_base, iort_id_count;
static bool iort_rid_map;

struct window {
    u64 cpu_base = 0;      // address the CPU uses
    u64 bus_base = 0;      // address on the PCI side
    u64 len = 0;
};

struct crs {
    int bus_min = 0, bus_max = -1;
    window io, mem32, mem64;
};

static ACPI_STATUS crs_cb(ACPI_RESOURCE *res, void *ctx)
{
    auto c = static_cast<crs*>(ctx);
    ACPI_RESOURCE_ADDRESS64 a;
    if (ACPI_FAILURE(AcpiResourceToAddress64(res, &a))) {
        return AE_OK;     // not an address descriptor
    }
    if (a.ProducerConsumer != ACPI_PRODUCER || !a.Address.AddressLength) {
        return AE_OK;
    }
    window w;
    w.bus_base = a.Address.Minimum;
    w.cpu_base = a.Address.Minimum + a.Address.TranslationOffset;
    w.len = a.Address.AddressLength;
    switch (a.ResourceType) {
    case ACPI_BUS_NUMBER_RANGE:
        c->bus_min = a.Address.Minimum;
        c->bus_max = a.Address.Minimum + a.Address.AddressLength - 1;
        break;
    case ACPI_IO_RANGE:
        if (!c->io.len) {
            c->io = w;
        }
        break;
    case ACPI_MEMORY_RANGE:
        if (w.cpu_base + w.len <= 0x100000000ull) {
            if (!c->mem32.len) {
                c->mem32 = w;
            }
        } else if (!c->mem64.len) {
            c->mem64 = w;
        }
        break;
    }
    return AE_OK;
}

static ACPI_STATUS find_root_bridge(ACPI_HANDLE h, UINT32, void *ctx, void **)
{
    *static_cast<ACPI_HANDLE*>(ctx) = h;
    return AE_CTRL_TERMINATE;     // segment 0's bridge comes first
}

// The GSI of a _PRT entry that names a link device is in the link's _CRS.
static ACPI_STATUS link_irq_cb(ACPI_RESOURCE *res, void *ctx)
{
    auto irq = static_cast<int*>(ctx);
    if (res->Type == ACPI_RESOURCE_TYPE_EXTENDED_IRQ && res->Data.ExtendedIrq.InterruptCount) {
        *irq = res->Data.ExtendedIrq.Interrupts[0];
        return AE_CTRL_TERMINATE;
    }
    if (res->Type == ACPI_RESOURCE_TYPE_IRQ && res->Data.Irq.InterruptCount) {
        *irq = res->Data.Irq.Interrupts[0];
        return AE_CTRL_TERMINATE;
    }
    return AE_OK;
}

static void read_prt(ACPI_HANDLE bridge)
{
    ACPI_BUFFER buf = { ACPI_ALLOCATE_BUFFER, nullptr };
    if (ACPI_FAILURE(AcpiGetIrqRoutingTable(bridge, &buf))) {
        return;     // MSI-only devices still work without INTx routing
    }
    std::vector<u32> bdfs;
    std::vector<int> irqs;
    for (auto p = static_cast<char*>(buf.Pointer); ; ) {
        auto e = reinterpret_cast<ACPI_PCI_ROUTING_TABLE*>(p);
        if (!e->Length) {
            break;
        }
        int gsi = e->SourceIndex;
        if (e->Source[0]) {
            ACPI_HANDLE link;
            gsi = -1;
            if (ACPI_SUCCESS(AcpiGetHandle(bridge, e->Source, &link))) {
                AcpiWalkResources(link, (char*)METHOD_NAME__CRS, link_irq_cb, &gsi);
            }
        }
        // _PRT addresses a whole device (function 0xFFFF); pins are 0-based
        // here and 1-based (INTA = 1) in the PCI config space.
        u32 dev = (e->Address >> 16) & 0x1f;
        if (gsi >= 32) {
            bdfs.push_back(dev << DTB_PHYSHI_D_SH | (e->Pin + 1));
            irqs.push_back(gsi - 32);      // pci.cc adds the SPI base back
        }
        p += e->Length;
    }
    AcpiOsFree(buf.Pointer);
    if (!bdfs.empty()) {
        // Match on device and pin; every function of a device shares its pins.
        u32 mask = (0x1f << DTB_PHYSHI_D_SH) | DTB_PIN_MASK;
        pci::set_pci_irqmap(bdfs.data(), irqs.data(), bdfs.size(), mask);
    }
    debugf("acpi-pci: _PRT %zu INTx routes\n", bdfs.size());
}

static void read_iort()
{
    ACPI_TABLE_HEADER *h;
    char sig[] = ACPI_SIG_IORT;
    if (ACPI_FAILURE(AcpiGetTable(sig, 0, &h))) {
        return;
    }
    auto t = reinterpret_cast<ACPI_TABLE_IORT*>(h);
    auto base = reinterpret_cast<char*>(t);
    auto end = base + t->Header.Length;
    auto n = base + t->NodeOffset;
    for (u32 i = 0; i < t->NodeCount && n + sizeof(ACPI_IORT_NODE) <= end; i++) {
        auto node = reinterpret_cast<ACPI_IORT_NODE*>(n);
        if (node->Length < sizeof(ACPI_IORT_NODE) || n + node->Length > end) {
            break;
        }
        if (node->Type == ACPI_IORT_NODE_PCI_ROOT_COMPLEX) {
            auto rc = reinterpret_cast<ACPI_IORT_ROOT_COMPLEX*>(node->NodeData);
            auto m = reinterpret_cast<ACPI_IORT_ID_MAPPING*>(n + node->MappingOffset);
            if (rc->PciSegmentNumber == 0 && node->MappingCount &&
                reinterpret_cast<char*>(m + 1) <= end) {
                // One mapping covers every device we know of (EC2, QEMU virt):
                // DeviceID = RID - InputBase + OutputBase.  A root complex that
                // splits its RIDs over several ITS groups would need a table.
                iort_rid_map = true;
                iort_rid_base = m->InputBase;
                iort_id_base = m->OutputBase;
                iort_id_count = m->IdCount;
                debugf("acpi-pci: IORT RID 0x%x+0x%x -> DeviceID 0x%x (%u mappings)\n",
                       m->InputBase, m->IdCount, m->OutputBase, node->MappingCount);
            }
        }
        n += node->Length;
    }
}

bool setup()
{
    if (!acpi::is_enabled()) {
        return false;
    }
    ACPI_TABLE_HEADER *h;
    char sig[] = ACPI_SIG_MCFG;
    if (ACPI_FAILURE(AcpiGetTable(sig, 0, &h)) ||
        h->Length < sizeof(ACPI_TABLE_MCFG) + sizeof(ACPI_MCFG_ALLOCATION)) {
        return false;
    }
    auto mcfg = reinterpret_cast<ACPI_MCFG_ALLOCATION*>(
        reinterpret_cast<char*>(h) + sizeof(ACPI_TABLE_MCFG));
    if (mcfg->PciSegment != 0) {
        return false;
    }

    ACPI_HANDLE bridge = nullptr;
    char hid[] = "PNP0A08";
    AcpiGetDevices(hid, find_root_bridge, &bridge, nullptr);
    if (!bridge) {
        char hid_conv[] = "PNP0A03";
        AcpiGetDevices(hid_conv, find_root_bridge, &bridge, nullptr);
    }
    if (!bridge) {
        debugf("acpi-pci: MCFG present but no PCI root bridge in the namespace\n");
        return false;
    }
    crs c;
    if (ACPI_FAILURE(AcpiWalkResources(bridge, (char*)METHOD_NAME__CRS, crs_cb, &c))) {
        debugf("acpi-pci: root bridge _CRS evaluation failed\n");
        return false;
    }
    if (c.bus_max < 0) {
        c.bus_min = mcfg->StartBusNumber;
        c.bus_max = mcfg->EndBusNumber;
    }
    // OSv's config accessors index from bus 0, so map from bus 0 up to the
    // last bus the bridge decodes, and no further than MCFG describes.
    int last_bus = std::min<int>(c.bus_max, mcfg->EndBusNumber);
    if (mcfg->StartBusNumber != 0 || last_bus < 0 || !c.mem32.len) {
        debugf("acpi-pci: unsupported bridge layout (bus %d-%d, mem32 %lx)\n",
               mcfg->StartBusNumber, last_bus, c.mem32.len);
        return false;
    }
    if (c.mem32.cpu_base != c.mem32.bus_base) {
        // pci.cc programs BARs with CPU addresses; a translated MMIO window
        // would need it to subtract the offset.
        debugf("acpi-pci: translated MMIO window not supported\n");
        return false;
    }
    size_t cfg_len = size_t(last_bus + 1) << 20;

    pci::set_pci_ecam(true);
    pci::set_pci_cfg(mcfg->Address, cfg_len);
    mmu::linear_map((void*)mcfg->Address, mcfg->Address, cfg_len, "pci_cfg",
                    mmu::page_size, mmu::mattr::dev);
    if (c.io.len) {
        pci::set_pci_io(c.io.cpu_base, c.io.len);
        mmu::linear_map((void*)c.io.cpu_base, c.io.cpu_base, c.io.len, "pci_io",
                        mmu::page_size, mmu::mattr::dev);
    }
    // The 64-bit window is not used: firmware assigns every BAR inside the
    // 32-bit one, and on EC2 the 64-bit window starts at 0x400000000000,
    // which is the base of OSv's own physical memory map and so cannot be
    // identity-mapped.
    pci::set_pci_mem(c.mem32.cpu_base, c.mem32.len);
    mmu::linear_map((void*)c.mem32.cpu_base, c.mem32.cpu_base, c.mem32.len, "pci_mem",
                    mmu::page_size, mmu::mattr::dev);

    debugf("acpi-pci: ECAM 0x%lx buses %d-%d, io 0x%lx+0x%lx (pci 0x%lx), "
           "mem32 0x%lx+0x%lx, mem64 0x%lx+0x%lx (unused)\n",
           mcfg->Address, c.bus_min, last_bus, c.io.cpu_base, c.io.len, c.io.bus_base,
           c.mem32.cpu_base, c.mem32.len, c.mem64.cpu_base, c.mem64.len);

    read_iort();
    read_prt(bridge);
    found = true;
    return true;
}

bool active()
{
    return found;
}

void print_devices()
{
    // Read straight from config space, before enumeration, so the BARs shown
    // are the ones firmware assigned.
    size_t cfg_len;
    pci::get_pci_cfg(&cfg_len);
    int buses = cfg_len >> 20;
    for (int b = 0; b < buses; b++) {
        for (int d = 0; d < 32; d++) {
            for (int f = 0; f < 8; f++) {
                u32 id = pci::read_pci_config(b, d, f, pci::PCI_VENDOR_ID);
                if ((id & 0xffff) == 0xffff) {
                    if (f == 0) {
                        break;
                    }
                    continue;
                }
                u32 cls = pci::read_pci_config(b, d, f, pci::PCI_CLASS_REVISION);
                u8 hdr = pci::read_pci_config_byte(b, d, f, pci::PCI_HEADER_TYPE);
                debugf("acpi-pci: %02x:%02x.%x %04x:%04x class %06x", b, d, f,
                       id & 0xffff, id >> 16, cls >> 8);
                int nbars = (hdr & 0x7f) == 0 ? 6 : 2;
                for (int i = 0; i < nbars; i++) {
                    u32 lo = pci::read_pci_config(b, d, f, pci::PCI_BAR0_ADDR + 4 * i);
                    if (!lo) {
                        continue;
                    }
                    if (lo & 1) {
                        debugf(" bar%d io %x", i, lo & ~3u);
                        continue;
                    }
                    u64 a = lo & ~0xfu;
                    bool is64 = (lo & 6) == 4;
                    if (is64 && i < nbars - 1) {
                        a |= (u64)pci::read_pci_config(b, d, f, pci::PCI_BAR0_ADDR + 4 * (i + 1)) << 32;
                    }
                    debugf(" bar%d %lx%s%s", i, a, is64 ? "/64" : "", lo & 8 ? "p" : "");
                    if (is64) {
                        i++;
                    }
                }
                debugf("\n");
                if (f == 0 && !(hdr & 0x80)) {
                    break;
                }
            }
        }
    }
}

u32 msi_device_id(u32 rid)
{
    // IORT "Number of IDs" is the size of the range minus one.
    if (iort_rid_map && rid - iort_rid_base <= iort_id_count) {
        return rid - iort_rid_base + iort_id_base;
    }
    return rid;
}

}
