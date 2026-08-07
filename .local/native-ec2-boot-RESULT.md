# OSv+PG18+ZFS — NATIVE EC2 BOOT: CONFIRMED (2026-08-05, beef acct 840154381708 us-east-2)

Parity-matrix cell (a) UNLOCKED: OSv+PostgreSQL serving NATIVELY on a Nitro EC2 instance
(Nitro boots the AMI directly — real ENA networking + NVMe storage — NO QEMU).

## RESULT: YES, it boots + serves natively.

Console output captured from native instance i-0510a8393ca946821 (m5.large, Nitro):

```
OSv v0.57.0-440-g6dd041b7
ZFS: OpenZFS 5000 initialized
[ZFS] Pool 'osv' is up-to-date at version 5000
ZFS: root mounted ok, z_root=34
eth0: 172.31.16.10                 <-- ENA UP, got VPC private IP
Booted up in 831.21 ms             <-- native Nitro boot (NO QEMU)
Cmdline: /zpool.so import -f -N pgdata ; ... postgres -D /data -c listen_addresses=* ...
[ZFS] Pool 'pgdata' is up-to-date at version 5000   <-- NVMe data disk imported
LOG:  starting PostgreSQL 18.0 on x86_64-pc-linux-musl
LOG:  listening on IPv4 address "0.0.0.0", port 5432
LOG:  database system is ready to accept connections   <-- PG serving over ENA
... (2 min later) FATAL: role "postgres" does not exist
    FATAL: dsa_area could not attach to a segment that has been freed
    exception nested too deeply [backtrace]   <-- KNOWN W2 wall (not native-EC2)
```

`psql "select 1" -> 1` SUCCEEDED over ENA (external: laptop -> public IP -> Nitro ENA -> OSv+PG),
reproduced on TWO independent clean boots. It works on the FIRST connection after "ready to accept
connections"; once a backend forks it hits the pre-existing W2 wall (dsa/catalog corruption across
forked backends — a PG-on-OSv correctness item in ROADMAP, orthogonal to native EC2).

## The 4 unknowns — all answered YES
1. Nitro boot chain launches OSv loader from the AMI?  YES — legacy-bios/MBR (arch/x64/boot16.S).
2. ENA up + network?  YES — `eth0: 172.31.16.10`, PG listened + served over it.
3. NVMe root + data?  YES — root 'osv' pool + data 'pgdata' pool both imported from NVMe EBS.
4. Guest IP config?  YES — eth0 got the VPC private IP automatically.

## Working AMI-build recipe (delta from scripts/ec2-make-ami.py)
- STEP 1 (KEY native delta): bake the OSv boot cmdline into the raw image at OFFSET 512 (max 1024 bytes).
  Native EC2 has no QEMU `-append`; OSv reads its cmdline from disk offset 512.
  Serve cmdline imports the data pool BY NAME (`zpool import -f pgdata`) so it works on NVMe or virtio.
  Must include `-c shared_memory_type=sysv` (W1 workaround) + TCP-only (`unix_socket_directories=`).
- STEP 2 (data): seed the pgdata ZFS pool once on any KVM host (boot OSv from the raw disk + a blank
  2nd disk, cmdline `zpool create ... -m /data pgdata /dev/vblk1 ; cpiod.so --prefix /data/ --port N ;
  zpool export pgdata`, cpiod-push a host-initdb'd cluster). initdb runs natively under Alpine musl
  (OSv stubs popen). dd the seeded disk onto a 2nd EBS volume.
- STEP 3: ec2-make-ami.py flow — create-volume -> attach to builder -> dd raw usr.img -> detach ->
  create-snapshot -> register-image.
- STEP 4 (register-image deltas): hvm + EnaSupport (already in ec2-make-ami.py); ADD
  `--boot-mode legacy-bios` (OSv boots via MBR, NOT UEFI — default UEFI would fail). RootDeviceName
  /dev/xvda, gp3, keep AMI PRIVATE.
- STEP 5 (launch): run-instances on a Nitro type (m5.large) with ENA; attach the seeded pgdata EBS as
  a 2nd device to the STOPPED instance (present at boot), then start.

### ec2-make-ami.py changes needed
1. Add `BootMode='legacy-bios'` to `register_image()`.
2. New step: bake boot cmdline at offset 512 before dd.
3. Optional: 2nd data-disk block-device mapping for the pgdata pool.
