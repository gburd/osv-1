# virtio-blk shared IRQ regression

Host callback check (Python 3 and g++):

```
python3 tests/tst-virtio-blk-shared-irq.py
CXXFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' python3 tests/tst-virtio-blk-shared-irq.py
```

The fixture extracts, without rewriting, production completion-thread creation,
interrupt factory setup, `ack_irq`, and PCI/MMIO transport registration. It
compiles both architecture selections on the host. Scheduler threads, device ISR
reads, queue masking and interrupt controllers are boundary doubles, not an OSv
scheduler or DMA model. It checks queue counts 1/2/4/64, zero/nonzero status at
registration (no uninitialized completion-thread pointers), callbacks after their
setup locals have died, spurious interrupts and dedicated MSI-X isolation. It
does not claim arbitrary null thread entries are valid driver state. The driver
creates all threads before it registers any callback.

Guest read-only check (run from the source root on a build host):

```
g++ -std=c++17 -fPIC -shared -Wall -Wextra -Werror -pthread \
  tests/virtio-blk-shared-irq-guest.cc -o /tmp/shared-irq-guest.so
scripts/build -j2 arch=x64 mode=release fs=rofs image=empty
printf '/shared-irq-guest.so: /tmp/shared-irq-guest.so\n' > build/release.x64/append.manifest
scripts/build -j2 arch=x64 mode=release fs=rofs image=empty --append-manifest
python3 scripts/imgedit.py setargs build/release.x64/usr.img '--verbose /shared-irq-guest.so'
```

Check build logs for errors, not just exit status: the build script's ERR trap
can report module failures but exit zero. Use this disposable image, not a
production disk. KVM access is required below; `-enable-kvm` must not be replaced
with a fallback accelerator. A privileged host may require sudo.

PCI INTx, two queues, MSI-X explicitly disabled:

```
timeout 20 qemu-system-x86_64 -m 512M -smp 2 -nographic \
  -monitor none -serial stdio -no-reboot -nic none -enable-kvm -cpu host \
  -device virtio-blk-pci,drive=hd0,num-queues=2,vectors=0 \
  -drive file=build/release.x64/usr.img,if=none,id=hd0,format=qcow2,cache=none,aio=native
```

Repeat with `vectors=4` for the dedicated MSI-X control.

x64 MMIO, two queues:

```
timeout 20 qemu-system-x86_64 -m 512M -smp 2 -nographic \
  -kernel build/release.x64/loader-stripped.elf \
  -append '--nopci --verbose /shared-irq-guest.so' \
  -M microvm,x-option-roms=off,pit=off,pic=off,rtc=off,auto-kernel-cmdline=on,acpi=off \
  -nodefaults -no-user-config -no-reboot -global virtio-mmio.force-legacy=off \
  -device virtio-blk-device,id=blk0,drive=hd0,num-queues=2 \
  -drive file=build/release.x64/usr.img,if=none,id=hd0,format=qcow2,cache=none,aio=native \
  -nic none -enable-kvm -cpu host,+x2apic -serial stdio
```

Require the console to confirm **2 queues**, actual CPUs 0 and 1, both read
passes, and `PASS shared IRQ guest pinned reads`, followed by exit 0. The probe
uses aligned direct reads of `/dev/vblk0`, separately pinned to CPU 0 and 1;
`make_request` maps those CPUs to queues 0 and 1. On the old code both shared
transports pass CPU 0, then hang at the CPU 1 read (watchdog exit 124). This is
correctness evidence, not a performance test. AArch64 guest IRQ delivery is not
covered by the x64 host callback selection or AArch64 object cross-compilation.
