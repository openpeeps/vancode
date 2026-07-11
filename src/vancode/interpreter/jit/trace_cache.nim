import std/tables
import ../chunk
import ./trace_types

type
  TraceEntry* = object
    code*: pointer
    codeSize*: int
    anchorPc*: int
    numLocals*: int

  TraceCache* = ref object
    entries*: Table[int, TraceEntry]

proc newTraceCache*(): TraceCache =
  TraceCache(entries: initTable[int, TraceEntry]())

proc have*(cache: TraceCache, pc: int): bool =
  cache.entries.hasKey(pc)

proc get*(cache: TraceCache, pc: int): TraceEntry =
  cache.entries[pc]

proc add*(cache: TraceCache, entry: TraceEntry) =
  cache.entries[entry.anchorPc] = entry
