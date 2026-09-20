# --env=/getenv audit RESULT (2026-09-19) - the caveat is REAL but MUCH NARROWER than feared

## THE MECHANISM (I found the "unexplained half"):
loader.cc:373  debugf("Setting in environment: %s\n", ...)  <- debugf is VERBOSE-GATED (core/debug.cc:167)
loader.cc:374  putenv(strdup(t.c_str()));                   <- STILL EXECUTES
=> The MISSING "Setting in environment" line is JUST the silenced debugf. putenv DOES run.
=> ENV INSTALLATION IS NOT BROKEN. The agent saw silence and reasonably inferred failure, but the only
   proven failure mode is: *a consumer that latches its static BEFORE parse_options*.
ORDERING (loader.cc): fork_arena::init() 759  ->  parse_options()/putenv 818  ->  smp_launch() 825.
So: latch BEFORE 818 = reads nothing (broken). Latch AFTER 818 (incl. anything on smp_launch threads or
lazily on first use) = binds correctly.

## PER-KNOB VERDICT:
- OSV_FORK_RANGE_BS (core/mmu.cc): lazy `static atomic cached{-1}` resolved on FIRST USE. First real fork
  is long after boot (PG forking a backend) => AFTER 818 => **VALID**. The footprint agent saw "unset,
  default" because ITS PROBE ran at fork_arena::init time (759, before 818) - that is the PROBE's timing,
  not proof the knob fails for real forks.
- OSV_IDLE_SPIN / adaptive (core/sched.cc): `static unsigned n = []{getenv}()` latched on the first
  do_idle, i.e. on an idle thread started by smp_launch (825) => AFTER 818 => **VALID**. Already documented
  in the #1501 body ("--env works: parse_options runs before smp_launch; a leading VAR= on the APP command
  line does NOT"), and the gates agent console-verified the lever per arm. #1511's numbers STAND.
- OSV_WAKE_PULL (core/sched.cc init_detached_threads_reaper): reads the env then `printf("WAKE_PULL %s")`.
  printf (NOT debugf) DOES reach the console - which is why runs could report "WAKE_PULL armed" from the
  boot log. **SELF-VERIFYING BY DESIGN and verified in practice => VALID.** #1472's +238% delta stands.
- OSV_BLK_MQ_COMPLETE (drivers/virtio-blk.cc): read in the driver ctor at device probe, and the code
  deliberately PRINTS the queue count at boot "so a dropped env cannot read as success" => self-verifying
  => **VALID**. (#1509's isolate +33-38% and HammerDB-null both stand.)
- OSV_ZFS_ARC_MAX (#1506): **NOT PRESENT on the a2a base.** It exists only on gh-fork/bench/zil-hires-ab
  (commits b7dff520d / 98b5e58c4). bank/fork-arena-real-reclaim and bench/leakhunt do NOT carry it.
  => the a2a's "matched 32GiB ARC both sides" was NOT enforced by this knob on the OSv side. HOWEVER the
  cwwake MEMPROBE measured arc_c=2047MB (far below BOTH the intended 32GiB cap and OSv's ~63GiB default),
  so OSv's ARC was in fact bounded - by memory pressure from the footprint bug, not by the knob. NET EFFECT
  on the a2a parity numbers: OSv ran with a ~2GB ARC while Linux had its matched cap, i.e. OSv was
  DISADVANTAGED on cache, not advantaged. So the a2a's OSv-vs-Linux ratios are conservative for OSv, not
  inflated. Worth restating in any writeup; does not invalidate the direction of the result.
- OSV_ZIL_HIRES_CV (#1505): knob not on the current bench bases either (same family as ARC_MAX, on the
  zil-hires-ab branch). Its "A/B null" was measured on THAT branch - the knob exists there, so the A/B
  arms could differ. The #1505 fix stands on correctness grounds regardless.

## BOTTOM LINE: no campaign result is invalidated by a dropped env. The genuinely affected cases are
## EARLY-BOOT consumers (fork_arena::init at 759) - which is exactly the footprint probe, and that is why
## the prior probe was silent (compounded by debugf's verbose gate). Several knobs are self-verifying by
## design (printf of the resolved value), which is what saved the campaign here.

## STANDING RULES (adopted):
1. An A/B is valid only if the lever's RESOLVED value is printed to the console and verified PER ARM
   (the #1509/#1472 printf pattern, and the gates agent's practice). Never infer binding from the cmdline.
2. Use printf or debug_early for boot-time proof lines - NOT debugf (verbose-gated, silent by default).
3. A knob consumed in EARLY BOOT (before parse_options at loader.cc:818) cannot use --env at all - it needs
   a compile-time switch or a different plumbing. fork_arena is in this class.
4. Prefer compile-time switches for bench A/Bs that touch early-boot code paths.
