# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import std/tables
import ../[chunk, vm, value]
import ./compiler

type
  JitCacheEntry* = object
    fnPtr: ForeignProc

  JitCache* = ref object
    procs: Table[string, JitCacheEntry]

proc newJitCache*(): JitCache =
  JitCache(procs: initTable[string, JitCacheEntry]())

proc getOrCompile*(cache: JitCache, vm: Vm, theProc: Proc): ForeignProc =
  if theProc == nil:
    return nil
  if cache.procs.hasKey(theProc.name):
    return cache.procs[theProc.name].fnPtr
  let compiled = compileProc(vm, theProc)
  if compiled != nil:
    cache.procs[theProc.name] = JitCacheEntry(fnPtr: compiled)
  result = compiled
