# REFRAMED (2026-09-07, second agent): it is NOT a q35 bug, and not machine-type-dependent

Agent 8bd9e217 independently reached the same AHCI/ATAPI root cause as agent 924205f9
(two independent confirmations of the mechanism), but its A/B matrix isolates the actual
variable, which BOTH my framing and the other agent's got wrong:

    q35 default                -> HANGS
    q35 -nodefaults            -> BOOTS
    q35 + ich9-ahci, no CD     -> BOOTS
    q35 + ich9-ahci + ide-cd   -> HANGS
    pc  default                -> BOOTS
    pc  + ich9-ahci + ide-cd   -> HANGS      <-- i440fx hangs TOO

**The last cell kills the machine-type story.** The correct statement is: **OSv's AHCI probe
hangs forever whenever any AHCI port presents an ATAPI device.** q35 merely makes it
universal, because q35 implies ich9-ahci plus QEMU's default empty ide-cd. "OSv does not
boot under -M q35" is a symptom, not the bug.

## The defect is THREE-fold, each part independently wrong (verified by me)

    drivers/ahci.cc  wait_cmd_poll(), in execution order:
      1. port_writel(PORT_IS, is)     ACKS interrupt status FIRST, destroying the TFES
                                      error record before anything examines it
      2. wait_ci_ready(slot)          waits on PxCI, which AHCI 1.3 6.2.2 guarantees never
                                      clears after a task-file error
      3. if (is & 0x02) / (is & 0x01) only DHRS/PSS are ever tested

    drivers/ahci.hh:107  defines  PORT_IS_TFES = 1U << 30
    grep -c PORT_IS_TFES drivers/ahci.cc  ->  0      DEFINED, NEVER CHECKED

Also `assert(!error)` on both paths means even a detected error aborts rather than
propagates (noted, deliberately out of scope).

Registers at the hang, port 2: `PxSIG=0xEB140101` (ATAPI; a SATA disk is `0x00000101`),
`PxTFD=0x00000441` (ERR 0x04=ABRT, status 0x41=DRDY|ERR), `PxCI=0x00000001` (slot never
retires), `PxIS=0x00000000` (already acked, error record gone).

## Fix directed: three separable parts
1. Check `PxIS.TFES` in `wait_cmd_poll` and fail the command; read error state BEFORE acking.
2. Bound `wait_ci_ready`/`wait_device_ready` with a deadline + TFD.ERR check. This turns any
   future device error from "hangs boot forever" into "fails one command".
3. Read `PxSIG` and skip non-ATA ports, so IDENTIFY DEVICE is never sent to ATAPI. Narrow
   skip preferred over implementing ATAPI.
1+2 are the general robustness fix; 3 is the specific cause.

## Ownership resolved to avoid duplicate PRs
**8bd9e217 owns the PR** (more complete differential diagnosis). 924205f9 instructed NOT to
open a competing PR, to hand over its register dump/backtrace, and to pursue instead the
separate pre-existing bug it found with a real disk attached - which is now its unique
contribution and may warrant its own PR.

924205f9's premise correction survives into the PR body as the blast radius:
`conf/profiles/x64/base.mk:30` has `export conf_drivers_ahci?=0`, so AHCI is OFF by default,
but the tests/native-example image enables it (`CONF_drivers_ahci 1`) - which is why stock
test builds hang. Neither the other agent nor I had that detail.

## Required PR evidence
Full 6-cell matrix (reproduction AND differential diagnosis); `q35 default` booting after
the fix; **`pc + ich9-ahci + ide-cd` booting after the fix** (proves the BUG was fixed, not
the machine type); `pc default` still working; register dump; gdb backtrace; AHCI 1.3 6.2.2
citation; blast-radius note. Stakes: distros are dropping i440fx (AL2023 qemu 11 ships only
q35, where `-M pc` is `unsupported machine type`), so in practice this is "OSv does not boot
on current hosts".


# ROOT CAUSE MEASURED (2026-09-07): AHCI ATAPI IDENTIFY hang, not a virtio bug

Agent 924205f9 found it with gdb + register reads rather than inference. **It is an OSv
bug, not a qemu bug.** My "downstream of virtio-blk" inference was correct; all three of my
mechanism hypotheses (PCI bridge enumeration, MSI-X, INTx routing) are DEAD.

## Backtrace at the hang
    #4  ahci::port::wait_ci_ready   (drivers/ahci.cc:162)
    #5  ahci::port::wait_cmd_poll   (drivers/ahci.cc:219)
    #6  ahci::port::disk_identify   (drivers/ahci.cc:381)
    #7  ahci::port::port (ctor) -> #8 hba::scan -> #9 hba::hba -> #10 ahci::hba::probe
    #19 arch_init_drivers (arch/x64/arch-setup.cc:402) -> #20 do_main_thread (loader.cc:547)

## Registers at the hang (ABAR 0xfebd3000)
    CAP  = 0xc0141f05 (6 ports)      PI = 0x3f
    port2: SSTS = 0x00000113  (DET=3, link up)
           SIG  = 0xeb140101  (ATAPI signature)
           TFD  = 0x00000441  (ERR|DRDY, error byte 0x04 = ABRT)
           CI   = 0x00000001  (never retires)

## Mechanism
q35's built-in ICH9 AHCI (00:1f.2) always presents an **empty ATAPI CD-ROM** on port 2
(qemu "ide2-cd0: [not inserted]"). i440fx has PIIX3 IDE and **no AHCI at all**, so
`ahci::hba::probe` never runs there - which is the entire machine-type dependence.

OSv sees DET=3, `linkup()` returns true, and issues **ATA IDENTIFY DEVICE (0xEC)
unconditionally**. ATAPI devices abort 0xEC (they require IDENTIFY PACKET DEVICE, 0xA1).
The abort is a task-file error, so per **AHCI 1.3 s6.2.2** the HBA halts the command engine
and does **NOT** clear PxCI. `wait_ci_ready()` is an unbounded `for (;;)` waiting for
exactly that bit -> boot hangs forever.

## Verified independently by me
- `drivers/ahci.cc:158-166`: `wait_ci_ready()` is a bare `for (;;)` on `PORT_CI`, with **no
  deadline and no task-file error check**.
- **`PORT_SIG` is defined at `drivers/ahci.hh:67` and read ZERO times in `drivers/ahci.cc`**
  (`grep -c` = 0). OSv never inspects the device signature; it gates only on `linkup()`
  (:65, :521). That is the defect in one line.
- The only `PORT_TFD` read is at `:152-153`, in a different wait (BSY/DRQ).
- Premise correction accepted: `conf/profiles/x64/base.mk:30` has
  `export conf_drivers_ahci?=0`, so AHCI is OFF by default, but the tests/native-example
  image enables it (`CONF_drivers_ahci 1`), which is why those builds hang. My brief implied
  stock builds always probe AHCI.

## Why the console line fooled three people
`ahci::hba::probe` is registered immediately after `virtio_blk::probe` in
`arch_init_drivers()`, so virtio-blk's message is simply the last thing printed before the
AHCI probe spins. The hang was never in virtio-blk.

## Fix directed: BOTH halves, they fix different bugs
1. **Correctness**: read `PxSIG` and skip non-ATA devices (`0xeb140101` = ATAPI vs
   `0x00000101` = ATA disk). Narrow skip rather than implementing ATAPI - OSv has no use for
   a CD-ROM and a skip is far more reviewable than a new device class.
2. **Robustness**: bound `wait_ci_ready` (and siblings) with a timeout plus a `PxTFD.ERR`
   check, returning an error instead of spinning. Justified from AHCI 1.3 s6.2.2: ANY future
   device error would hang boot identically.
Half 1 fixes q35; half 2 stops the next variant. Marked separable for the reviewer.

## Stakes for the PR
**Distros are dropping i440fx.** AL2023's qemu 11 already ships only q35 (`-M pc` ->
`unsupported machine type`), so this is not a config nicety: it is "OSv does not boot on
current hosts". Blast radius: any image built with AHCI enabled, on any q35 host.

A separate pre-existing bug (real disk attached, not q35-specific) was found and
deliberately EXCLUDED to keep the PR single-purpose.

# OSv x86 does not boot under QEMU -M q35

Agent 924205f9 dispatched 2026-09-07 to root-cause and fix, then open an upstream PR.

## The measurement (agent 0d31376d, bare-metal EC2)

4-way matrix, SAME qemu 8.1.3 build, same kernel, same image:

    -M q35 + KVM  -> HANGS at "virtio-blk: Add blk device instances 0 as vblk0"
    -M q35 , TCG  -> HANGS at the identical line
    -M pc  + KVM  -> BOOTS, ZFS banner, clean poweroff
    -M pc  , TCG  -> BOOTS, ZFS banner, clean poweroff

The failure follows the **machine type**, not the accelerator, not the qemu version. An
earlier agent's hang under forced q35 was one line earlier ("vga: Add VGA device
instance"), so the console position is approximate.

## Why this is now urgent rather than cosmetic

AL2023's qemu 11 ships **only q35**: `-machine help` lists pc-q35-9.2 ... pc-q35-6.1,
i440fx is compiled out, and `-M pc` returns `unsupported machine type: "pc"`. So on that
host OSv is simply unbootable. **Distros are dropping i440fx**, which makes this a
growing availability problem for OSv on stock hosts rather than a niche configuration.

This also retroactively explains the "qemu 11 cannot boot OSv" conclusion: it was q35,
forced, with no alternative machine available. One root cause, two symptoms.

## Grounding facts I established from source (for the agent to verify, not trust)

- Hang message is `drivers/virtio-blk.cc:254` and it is the **LAST statement of the blk
  constructor**.
- `read_partition_table(dev)` is at **line 252**, so real block I/O completes BEFORE that
  print.
- **Inference (explicitly flagged as an inference, not a measurement): virtio-blk works
  and the hang is DOWNSTREAM.** The agent is told to kill this if evidence disagrees.
- MSI-X path: `:155` reserve_msix_vectors, `:205` easy_register, `:208` abort() on
  failure. We hang rather than abort, so registration presumably succeeded.
- **No PIIX3/ICH9-specific code and no ACPI `_PRT` IRQ routing exists in the tree**
  (grep for piix|ich9|pirq|_PRT is empty). q35's interrupt topology and PCIe bridge
  layout differ from i440fx, so missing bridge/secondary-bus enumeration or INTx routing
  are the prime suspects.

## Hypotheses, in test order
1. PCI enumeration does not recurse through PCIe root ports / bridges (q35 puts devices
   behind them; i440fx does not).
2. The first ASYNCHRONOUS interrupt never arrives, so the next I/O wait hangs forever
   (note `read_partition_table` succeeded, which may be a polled/serviced path).
3. Find the true hang point empirically first - the last console line is where OSv
   stopped PRINTING, not necessarily where it stopped executing.
4. ACPI/MCFG ECAM differences (probably benign if config space is via CF8/CFC).

## Method and honesty constraints given
- Find the hang point empirically (debug prints, or gdb stub `-s -S` with a backtrace)
  and state which thread/wait/lock is stuck BEFORE proposing a fix.
- Cheap box preferred: **the bug reproduces under TCG**, so no metal/KVM is required.
- Minimal image for iteration; do NOT build the PG/ZFS stack.
- Base on **upstream/master**, not our fork branches: this is a clean standalone fix.
- **No "fixed" without a pasted successful `-M q35` boot AND a pasted still-working
  `-M pc` boot** (no-regression A/B).
- **If the root cause is a QEMU bug rather than an OSv bug, say so and do NOT paper over
  it in OSv.** No PR in that case. Valid outcome.
- If the root cause is not found, report the narrowed hang point with evidence rather
  than guessing at a patch.
