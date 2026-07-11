import ../chunk

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
