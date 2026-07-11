# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Type definitions for the trace-based JIT subsystem. Defines the trace
## lifecycle states (`tsIdle`, `tsPending`, `tsRecording`, `tsPaused`,
## `tsCompiled`), the `TraceBuffer` for recording instruction sequences, and
## `Snapshot` for capturing local variable state at guard points.

type
  TraceState* = enum
    tsIdle
    tsPending
    tsRecording
    tsPaused
    tsCompiled

  Snapshot* = object
    pc*: int
    localsOff*: int
    numLocals*: int

  TraceBuffer* = ref object
    pcs*: seq[int]
    anchorPc*: int
    numLocals*: int
    snapshots*: seq[Snapshot]
    cached*: pointer    # raw CachedOps pointer
    chunk*: pointer     # raw Chunk pointer (for string table access)
    selfProcId*: int    # procId for self-recursive call detection (-1 = none)
    selfParamCount*: int  # param count for self-recursive calls

  TraceExitReason* = enum
    terNormal
    terGuardFail
