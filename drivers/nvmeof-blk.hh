/*
 * NVMe-over-TCP (NVMe/TCP) initiator block device driver for OSv
 *
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * This is a host-side NVMe/TCP initiator: a network block device with no
 * PCI probe.  It connects over TCP to a Linux nvmet-tcp target, performs
 * the NVMe/TCP handshake and Fabrics Connect, identifies the namespace,
 * and exposes it as /dev/nvmeofN.  It is NOT part of the default build
 * profile.
 *
 * To build OSv with NVMe/TCP support:
 *   ./scripts/build conf_drivers_profile=nvmeof
 * or:
 *   make conf_drivers_nvmeof=1
 */

#ifndef NVMEOF_BLK_HH
#define NVMEOF_BLK_HH

#include <osv/device.h>
#include <string>
#include <cstdint>

namespace nvmeof {

/**
 * Initialize one NVMe/TCP initiator block device.
 *
 * Connects to the target, identifies namespace 1, and creates
 * /dev/nvmeof<device_index>.  If the connection or identify fails, a
 * warning is logged but boot continues and the device is not created.
 *
 * @param target       "host:port" of the nvmet-tcp target
 * @param subnqn       Subsystem NQN to connect to (required)
 * @param hostnqn      Host NQN to present (a default is used if empty)
 * @param device_index Device index for multi-device support (0-7)
 * @return 0 on success, error code on failure (boot continues regardless)
 */
int nvmeof_init(const std::string& target, const std::string& subnqn,
                const std::string& hostnqn, int device_index);

} // namespace nvmeof

#endif // NVMEOF_BLK_HH
