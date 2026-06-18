# NVMe-over-TCP (NVMe/TCP) initiator block device driver
# Build with: ./scripts/build conf_drivers_profile=nvmeof
include conf/profiles/$(arch)/all.mk
conf_drivers_nvmeof?=1
