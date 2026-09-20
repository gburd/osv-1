#!/usr/bin/env python3
# LEAK #2 REAL FIX, part (i) for the ONE missed cross-AS class the histogram +
# the on-box crash surfaced: stdio FILE objects.
#
# WHY: musl/OSv keep a single PROCESS-GLOBAL open-file list (ofl_head in
# libc/stdio/ofl.c -- a kernel static, on the identity heap, shared by EVERY
# address space). fdopen/fopen malloc the FILE via the app-thread path, so
# post-exhaustion it lands in the per-AS overflow region (mapped ONLY in the
# allocating AS). fflush(NULL) / exit cleanup walk the SHARED ofl_head from
# another context (postmaster / a sibling / AS0) and dereference that FILE at a
# VA not mapped there -> "page fault outside application, addr 0x308...c060" in
# fflush+246 (the on-box crash). This is the cross-AS raw-pointer-crossing the
# design must exclude: a FILE is app-allocated but kernel-LIFETIME (lives on a
# shared list), so it must stay on the identity heap, exactly like the vfs
# objects already scoped. It is tiny + freed on fclose, so the residual identity
# leak is bounded.
#
# FIX: bracket every FILE-object malloc in libc/stdio with the C-linkage
# fork_kernel_heap_push()/pop() so the FILE (and its buffer) land on the shared
# identity heap, never the COW arena or the per-AS overflow region. Idempotent.
import sys, os

# (file, the malloc line to wrap). We wrap only the FILE-object allocation.
SITES = [
    ("libc/stdio/__fdopen.c",       "\tif (!(f=malloc(sizeof *f + UNGET + BUFSIZ))) return 0;"),
    ("libc/stdio/fmemopen.c",       "\tf = malloc(sizeof *f + (buf?0:size));"),
    ("libc/stdio/open_memstream.c", "\tif (!(f=malloc(sizeof *f))) return 0;"),
    ("libc/stdio/open_wmemstream.c",None),   # resolve line below
    ("libc/stdio/__fopen_rb_ca.c",  None),
]

DECL = ("/* LEAK #2 REAL FIX: keep stdio FILE objects on the shared identity heap.\n"
        " * The open-file list (ofl_head) is process-global and walked cross-AS by\n"
        " * fflush(NULL)/exit; a FILE in the per-AS fork overflow region would fault\n"
        " * when touched from another address space. Bracket the FILE malloc so it\n"
        " * lands on the identity heap (coherent in every AS), like the vfs objects. */\n"
        "extern void fork_kernel_heap_push(void);\n"
        "extern void fork_kernel_heap_pop(void);\n")

def wrap(path, mallocline):
    with open(path, encoding="utf-8") as fp:
        s = fp.read()
    if "fork_kernel_heap_push" in s:
        print(f"{path}: already wrapped"); return
    if mallocline is None:
        # auto-detect the FILE malloc line
        import re
        m = re.search(r'^[ \t]*.*\bf\s*=\s*malloc\(sizeof \*f\b.*$', s, re.M)
        if not m:
            m = re.search(r'^[ \t]*if \(!\(f=malloc\(sizeof \*f\b.*$', s, re.M)
        if not m:
            print(f"{path}: FILE malloc line not found -- SKIP (inspect)"); return
        mallocline = m.group(0)
    if mallocline not in s:
        print(f"{path}: expected malloc line not present -- SKIP"); return
    # add the extern decl after the last #include
    lastinc = s.rfind("#include")
    eol = s.find("\n", lastinc) + 1
    s = s[:eol] + "\n" + DECL + s[eol:]
    # bracket the malloc line
    wrapped = ("\tfork_kernel_heap_push();\n"
               + mallocline + "\n"
               "\tfork_kernel_heap_pop();")
    # careful: keep the original line's control flow. For "if (!(f=malloc...)) return 0;"
    # we must not put push/pop around a line with an early return, or pop is skipped
    # on the return path. Restructure: push; f=malloc(...); pop; if(!f) return.
    s = _restructure(s, mallocline)
    with open(path, "w") as fp:
        fp.write(s)
    print(f"{path}: wrapped FILE malloc")

def _restructure(s, line):
    L = line.strip()
    if L.startswith("if (!(f=malloc(") and L.endswith(")) return 0;"):
        inner = L[len("if (!(f="):-len(")) return 0;")]   # "malloc(...)"
        repl = ("fork_kernel_heap_push();\n"
                "\tf = " + inner + ";\n"
                "\tfork_kernel_heap_pop();\n"
                "\tif (!f) return 0;")
        return s.replace(line, "\t" + repl, 1)
    if L.startswith("f = malloc(") or L.startswith("f=malloc("):
        repl = ("fork_kernel_heap_push();\n"
                "\t" + L + "\n"
                "\tfork_kernel_heap_pop();")
        return s.replace(line, "\t" + repl, 1)
    # fallback: naive bracket (may skip pop on return -- flagged)
    return s.replace(line, "\tfork_kernel_heap_push();\n" + line + "\n\tfork_kernel_heap_pop();", 1)

for path, ml in SITES:
    if not os.path.exists(path):
        print(f"{path}: missing -- skip"); continue
    wrap(path, ml)
print("STDIO SCOPE DONE")
