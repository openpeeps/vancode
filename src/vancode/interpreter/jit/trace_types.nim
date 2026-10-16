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
    selfHasResult*: bool  # whether a self-call leaves a result behind
    initLocalKinds*: seq[int32]  # steady-state local types sampled at
      ## recording completion (loop-top): seeds the compilers' type
      ## analysis so loop-carried locals (e.g. floats holding raw bits
      ## from the previous lap) compile with precise kinds instead of
      ## `unknown`, which cannot resolve bit-cast slots. Stored as
      ## `TypeId`s (`tyAny` = unknown).
    failKind*: TraceFailKind  # set by compileTrace on failure (tfNone = ok)

  TraceExitReason* = enum
    terNormal
    terGuardFail

  TraceFailKind* = enum
    ## Why a trace compile failed. Opcode/resource failures are stable
    ## across recordings of the same loop (same body), so the VM may
    ## permanently stop retrying them. Shape failures depend on which
    ## branch paths a recording window happened to capture, so a later
    ## window may still compile: never mark those.
    tfNone
    tfOpcode
    tfShape
    tfResource
