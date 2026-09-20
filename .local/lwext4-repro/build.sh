set -e
L=/tmp/maint4-lwext4
DEFS="-DCONFIG_DEBUG_PRINTF=0 -DCONFIG_DEBUG_ASSERT=0 -DCONFIG_HAVE_OWN_OFLAGS=0 -DCONFIG_HAVE_OWN_ERRNO=0 -DCONFIG_BLOCK_DEV_CACHE_SIZE=16 -DCONFIG_JOURNALING_ENABLE=0 -DCONFIG_USE_DEFAULT_CFG=1"
cc -std=gnu99 -O2 -g $DEFS -I $L/include -I $L/blockdev -I $L/blockdev/linux \
   -o /tmp/maint4-repro/repro /tmp/maint4-repro/lwext4-create-durability.c \
   $L/src/*.c $L/blockdev/linux/file_dev.c $L/blockdev/blockdev.c 2>&1 | grep -vE 'warning|^ |~|\^' | head -20
