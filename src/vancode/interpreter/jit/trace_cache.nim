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

const maxTraceWork* = 100_000
  ## Bounds total recorded-but-uncompilable operations per anchor. A loop
  ## whose windows never compile (one-sided branches, nesting) stops being
  ## re-recorded after this much futile work — while phased loops (rare
  ## paths every N laps) accumulate far less and still compile on their
  ## diamond window. Attempt counts alone cannot tell these apart.

type
  TraceCache* = ref object
    entries*: Table[(int, pointer), TraceEntry]
    traceWork*: Table[(int, pointer), int]

proc newTraceCache*(): TraceCache =
  TraceCache(entries: initTable[(int, pointer), TraceEntry](),
    traceWork: initTable[(int, pointer), int]())

proc have*(cache: TraceCache, pc: int, chunk: pointer): bool =
  ## Runnable entry only: failed-loop markers (`code == nil`, see
  ## `addFailed`) are invisible here so the execute path never sees them.
  cache.entries.hasKey((pc, chunk)) and
    cache.entries[(pc, chunk)].code != nil

proc haveFailed*(cache: TraceCache, pc: int, chunk: pointer): bool =
  cache.entries.hasKey((pc, chunk)) and
    cache.entries[(pc, chunk)].code == nil

proc probe*(cache: TraceCache, pc: int, chunk: pointer): int =
  ## Single-lookup gate probe for the hot back-edge path: 1 = runnable
  ## entry, 2 = marked failed, 0 = unknown. Missing keys and failed
  ## markers both read `code == nil`; they are told apart by the stored
  ## anchor (failed markers echo the queried anchor back).
  let e = cache.entries.getOrDefault((pc, chunk),
    TraceEntry(code: nil, codeSize: 0, anchorPc: -1, numLocals: 0,
      chunk: nil))
  if e.code != nil: 1
  elif e.anchorPc == pc and e.chunk == chunk: 2
  else: 0

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

proc noteTraceWork*(cache: TraceCache, anchorPc: int, chunk: pointer,
    pcs: int): bool =
  ## Add one failed window's operation count; returns true when the anchor
  ## just exceeded the futile-work budget and should be marked failed.
  let k = (anchorPc, chunk)
  let n = cache.traceWork.getOrDefault(k, 0) + pcs
  cache.traceWork[k] = n
  result = n >= maxTraceWork
