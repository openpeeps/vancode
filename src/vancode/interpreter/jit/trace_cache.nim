import std/tables
import ../chunk
import ./trace_types

type
  TraceEntry* = object
    code*: pointer
    codeSize*: int
    anchorPc*: int
    numLocals*: int
    chunk*: pointer

  TraceCache* = ref object
    entries*: Table[(int, pointer), TraceEntry]

proc newTraceCache*(): TraceCache =
  TraceCache(entries: initTable[(int, pointer), TraceEntry]())

proc have*(cache: TraceCache, pc: int, chunk: pointer): bool =
  cache.entries.hasKey((pc, chunk))

proc get*(cache: TraceCache, pc: int, chunk: pointer): TraceEntry =
  cache.entries[(pc, chunk)]

proc add*(cache: TraceCache, entry: TraceEntry) =
  cache.entries[(entry.anchorPc, entry.chunk)] = entry
