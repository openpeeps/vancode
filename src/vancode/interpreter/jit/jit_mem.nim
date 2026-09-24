# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Low-level JIT code memory allocator. Provides `allocJitCode` and
## `freeJitCode` backed by platform-specific routines (e.g. mmap with
## PROT_EXEC) declared in `vc_jit_mem.h`.
import std/os
{.passC: "-I" & currentSourcePath().parentDir.}

proc allocJitCode*(size: int): pointer {.importc: "vc_alloc_jit_code", header: "vc_jit_mem.h".}
proc makeJitCodeWritable*(p: pointer) {.importc: "vc_jit_code_make_writable", header: "vc_jit_mem.h".}
proc makeJitCodeExecutable*(p: pointer) {.importc: "vc_jit_code_make_executable", header: "vc_jit_mem.h".}
proc freeJitCode*(p: pointer, size: int) {.importc: "vc_free_jit_code", header: "vc_jit_mem.h".}
