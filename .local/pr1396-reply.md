Pushed an amended `pr/musl` (now `8e5b093c`) that folds the rename into the single musl commit, so the submodule is `musl_1.2.1` from the start of the history rather than a follow-up:

- Renamed the submodule `musl_1.1.24` -> `musl_1.2.1` end-to-end: the `.gitmodules` stanza (name + path), the `.git/config` section, the `.git/modules/` dir, and the gitlink path. The top-level `musl` symlink now points at `musl_1.2.1/`. The Makefile only ever references `musl/`, so the dir rename is transparent to the build.
- Renamed both dirent symlinks: `include/api/aarch64/bits/dirent.h` and `include/api/x64/bits/dirent.h` now target `musl_1.2.1/arch/generic/bits/dirent.h`.
- `libc/README.md`: fixed the remaining `1.1.24` references (State section + symlink target), bumped the Upgrades note to `> 1.2.1`, and added the upgrade-history line you asked for:

  ```
  Upgraded from 0.9.12 to 1.1.24.

  Upgraded from 1.1.24 to 1.2.1.
  ```

The tree now has zero `musl_1.1.24` paths (`git ls-tree -r 8e5b093c | grep -c musl_1.1.24` -> 0).

One README reference to `1.1.24` is intentionally retained, under the time module:

> time (all but `__tz.c`) that comes from musl 1.1.24 and has been adapted

That line is accurate and not a stale leftover. OSv does not compile the musl submodule's `src/time/__tz.c`; it is absent from the `musl +=` list. Instead OSv builds an adapted copy at `libc/time/__tz.c` (Makefile, `libc/time/__tz.o`), which derives from the 1.1.24 `__tz.c` and was hand-modified to use OSv mutexes and the local-function syscall shim. I confirmed this on the build host: dropping the submodule's 1.2.1 `__tz.c` into the build fails to compile against OSv internals (lock-type mismatch, missing return, unused `index`), while the adapted `libc/time/__tz.c` builds clean. So the provenance note stays at 1.1.24 by design; bumping it to 1.2.1 would be wrong.

On impact: I agree with your read. I went through the subset of changed files OSv actually compiles (your `grep ^musl\ + Makefile` list intersected with the 1.1.24->1.2.1 diff). Every delta is an upstream correctness/bug fix, not a behavioral redesign:

- math (`cosh`/`sinh`/`__expo2*`/`__rem_pio2*`): accuracy and signed-shift UB fixes (casts to unsigned), no API/ABI change.
- `network/lookup_name.c`, `res_mkquery.c`: DNS rcode handling and query-id fixes.
- `stdio/vfscanf.c`, `ungetc.c`: scanf buffer priming / pushback correctness.
- `string/memmem.c`, `strstr.c`, `memccpy.c`, `strsignal.c`: substring-search and signal-string fixes.
- `ctype/towctrans.c`, `wcwidth.c`, `errno/strerror.c`: table/lookup fixes.
- `misc/nftw.c`, `time/__map_file.c`, `stdio/tempnam.c`/`tmpnam.c`: the handful that needed OSv-side touch-ups, already called out in the PR notes (nftw field init no longer relying on 1.1.x malloc zeroing; the tempnam/tmpnam/__map_file shim warning suppressions).

No struct layout or symbol-visibility changes reach the OSv ABI; this is deliberately the last within-1.x bump before musl's 1.2.x internal re-architecture. The in-tree libc tests (the unit-test bar) pass.

Re: the `osvunikernel/musl` remote -- yes, still pointing there since it carries the v1.2.1 tag. Nothing else changed about the remote.
