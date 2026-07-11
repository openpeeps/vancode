import std/os
{.passC: "-I" & currentSourcePath().parentDir.}

proc allocJitCode*(size: int): pointer {.importc: "vc_alloc_jit_code", header: "vc_jit_mem.h".}
proc freeJitCode*(p: pointer, size: int) {.importc: "vc_free_jit_code", header: "vc_jit_mem.h".}
