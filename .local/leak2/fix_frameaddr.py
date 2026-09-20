#!/usr/bin/env python3
# Suppress -Werror=frame-address around the __builtin_return_address(n>0) chain
# capture (instrumentation only; frame pointers are kept so n>0 is well-defined
# here despite GCC's blanket warning). Idempotent.
f = "core/mempool.cc"
s = open(f, encoding="utf-8").read()

old = ("        fb_took_fallback = true;\n"
       "        // RA(0)==malloc; the real caller chain is RA(1)/RA(2)/RA(3)\n"
       "        // (frame pointers are kept: -fno-omit-frame-pointer).\n"
       "        fb_caller  = reinterpret_cast<uintptr_t>(__builtin_return_address(1));\n"
       "        fb_caller2 = reinterpret_cast<uintptr_t>(__builtin_return_address(2));\n"
       "        fb_caller3 = reinterpret_cast<uintptr_t>(__builtin_return_address(3));")
new = ("        fb_took_fallback = true;\n"
       "        // RA(0)==malloc; the real caller chain is RA(1)/RA(2)/RA(3)\n"
       "        // (frame pointers are kept: -fno-omit-frame-pointer, so n>0 is\n"
       "        // well-defined; silence GCC's blanket -Wframe-address here).\n"
       "        _Pragma(\"GCC diagnostic push\")\n"
       "        _Pragma(\"GCC diagnostic ignored \\\"-Wframe-address\\\"\")\n"
       "        fb_caller  = reinterpret_cast<uintptr_t>(__builtin_return_address(1));\n"
       "        fb_caller2 = reinterpret_cast<uintptr_t>(__builtin_return_address(2));\n"
       "        fb_caller3 = reinterpret_cast<uintptr_t>(__builtin_return_address(3));\n"
       "        _Pragma(\"GCC diagnostic pop\")")
assert old in s, "frame-address capture anchor not found"
s = s.replace(old, new, 1)
open(f, "w").write(s)
print("frame-address pragma applied")
