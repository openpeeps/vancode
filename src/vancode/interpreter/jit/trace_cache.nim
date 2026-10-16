# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Cache for compiled trace entries. Maps `(anchorPc, chunk)` pairs to their
## native code buffer, enabling fast lookup and reuse of previously compiled
## hot loop traces.
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
  ## Runnable entry only: failed-loop markers (`code == nil`, see
  ## `addFailed`) are invisible here so the execute path never sees them.
  cache.entries.hasKey((pc, chunk)) and
    cache.entries[(pc, chunk)].code != nil

proc haveFailed*(cache: TraceCache, pc: int, chunk: pointer): bool =
  cache.entries.hasKey((pc, chunk)) and
    cache.entries[(pc, chunk)].code == nil

proc get*(cache: TraceCache, pc: int, chunk: pointer): TraceEntry =
  cache.entries[(pc, chunk)]

proc add*(cache: TraceCache, entry: TraceEntry) =
  cache.entries[(entry.anchorPc, entry.chunk)] = entry

proc addFailed*(cache: TraceCache, anchorPc: int, chunk: pointer) =
  ## Negative marker for a loop whose compile failure is stable across
  ## recordings (unsupported opcode, resource exhaustion). Stored in the
  ## same table so the hot-loop gate skips re-recording it; `code == nil`
  ## marks failure. Shape failures are never marked (see TraceFailKind).
  cache.entries[(anchorPc, chunk)] = TraceEntry(code: nil, codeSize: 0,
    anchorPc: anchorPc, numLocals: 0, chunk: chunk)
