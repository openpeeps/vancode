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
  cache.entries.hasKey((pc, chunk))

proc get*(cache: TraceCache, pc: int, chunk: pointer): TraceEntry =
  cache.entries[(pc, chunk)]

proc add*(cache: TraceCache, entry: TraceEntry) =
  cache.entries[(entry.anchorPc, entry.chunk)] = entry
