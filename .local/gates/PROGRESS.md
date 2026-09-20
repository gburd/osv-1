# Gates run — live progress (Owner=agent-gates, hotdog 585335547908, us-east-2a)

## BOX IDs
- METAL i-07cd70356cef08c3a  m5d.metal (Debian 12) — OSv + Ubuntu guests + host + instr
- DRV   i-0d81859ea71589291  c5.4xlarge (Ubuntu 24.04) — HammerDB 6.0 driver

## Pre-flight (DONE)
- bench-base-gate PASS all 9 markers on bank/sched-adaptive-idle-spin @ 1685b6511 (worktree). Adaptive
  fix markers present: idle_spin_max=4, OSV_IDLE_SPIN_ADAPTIVE=2 (getenv+comment), idle_spin_window(hh)=1.
- Base built: OSV_SHA=1685b6511, APPS_SHA=3f93f43, SEEDCOPY_MKDIR_FIX=1, PHONY_COUNT=1.
- io_uring: base build had with_liburing=no. REBUILT musl liburing 2.5 (--use-libc + -idirafter
  /usr/include for uapi headers) + PG --with-liburing (22 io_uring symbols, WITH_LIBURING=1,
  "checking whether to build with liburing support... yes"). liburing.so.2.5 shipped, image 119209984 B.
- CONFIRMED io_method=io_uring ACCEPTED at boot: OSv PG "database system is ready to accept connections"
  with -c io_method=io_uring; driver `show io_method` => io_uring. Both sides io_uring.
- SG: added self-referencing 5432 rule (SG->SG, intra-VPC only), 22 stays 73.4.58.126/32. NO 0.0.0.0/0.
- Adaptive A/B knob wired into boot-osv.sh: ADAPT=1 => OSV_IDLE_SPIN_ADAPTIVE=1 (adaptive-v2);
  ADAPT=0 => OSV_IDLE_SPIN_ADAPTIVE=0 + OSV_IDLE_SPIN=10000 (historical fixed baseline).

## In progress
- HammerDB 200wh schema build on OSv PG (ZFS pool /dev/nvme1n1, persists across fresh boots).
