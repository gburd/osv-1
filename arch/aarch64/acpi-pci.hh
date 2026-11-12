/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef ARCH_AARCH64_ACPI_PCI_HH
#define ARCH_AARCH64_ACPI_PCI_HH

#include <osv/types.h>

namespace acpi_pci {

// Configure PCI (config space, windows, INTx routing) from the MCFG, the root
// bridge's _CRS/_PRT and the IORT.  Returns false, changing nothing, when the
// machine has no ACPI or no PCI host bridge in it.
bool setup();

// True after a successful setup().
bool active();

// One line per PCI function: BDF, IDs, class and the BARs firmware assigned.
void print_devices();

// The GIC ITS DeviceID of the PCI requester ID rid, from the IORT root
// complex ID mapping (identity when there is none).
u32 msi_device_id(u32 rid);

}

#endif
