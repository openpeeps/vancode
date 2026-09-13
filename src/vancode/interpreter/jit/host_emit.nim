# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Host emit helpers for JIT-compiling host-defined opcodes. Hosts admit their own opcodes via `extendCaseStmt` on the
## `vmJitDynasmAllowCase` / `vmJit*EmitCase` anchors; the injected emit
## branches are one-liner calls into these helpers so all machine-code
## knowledge stays vancode-owned. Host behavior arrives as registered
## bridges (`registerJitHostBridge`); a missing bridge makes the helper
## return false and the caller must reject compilation (interpreter
## fallback) — never emit a call to nil.
import std/strutils
import pkg/voodoo/extensibles

import ./dynasm/wrapper
import ./compiler_bridge
import ../[vm, value, chunk]

## Re-exported from `compiler_bridge`, which owns the table so the
## shared `resetJitState` can clear it without an import cycle.
export JitHostMeta, registerJitHostMeta, resetJitHostMeta, getJitHostMeta

injectExtendedModule() # extra code injected via voodoo

proc constrKeysMeta*(cached: CachedOps, pc: int, ch: Chunk): int32 =
  ## Copy ConstrObj key indices to owned strings (the chunk string table
  ## must not be referenced from machine code).
  var keys: seq[string] = @[]
  for k in cached.strKeys[pc]:
    keys.add(ch.strings[k])
  registerJitHostMeta(JitHostMeta(strs: keys))

proc emitRawMeta*(cached: CachedOps, pc: int, ch: Chunk): int32 =
  ## Pack an EmitRaw site: source line, col, chunk file.
  registerJitHostMeta(JitHostMeta(
    ints: @[cached.getArg1Int(pc).int64, cached.arg2[pc]],
    strs: @[ch.file]))

proc emitConstPush*(d: ptr ptr dasm_State, cached: CachedOps, pc: int,
    ch: Chunk, bridgeName: string): bool =
  ## Push a chunk string constant as a tagged ring index: immortalize the
  ## chars, then pushg through the host bridge (which roots a fresh Value).
  let fn = findJitHostBridge(bridgeName)
  if fn == nil: return false
  vancode_pushg(d, jitImmortalStr(cached.getArg1Str(pc, ch)), fn)
  true

proc emitFloatPush*(d: ptr ptr dasm_State, cached: CachedOps, pc: int,
    ch: Chunk, bridgeName: string): bool =
  ## Push a chunk float constant as a tagged ring index (floats never
  ## travel raw: no float arithmetic exists on the native stack).
  let fn = findJitHostBridge(bridgeName)
  if fn == nil: return false
  vancode_pushg(d, jitImmortalFloat(cached.getArg1Float(pc)), fn)
  true

proc emitGlobalPush*(d: ptr ptr dasm_State, cached: CachedOps, pc: int,
    ch: Chunk, bridgeName: string): bool =
  ## Push a global by name through the host bridge (ints/bools travel
  ## raw, everything else as a tagged index — decided by the bridge).
  let fn = findJitHostBridge(bridgeName)
  if fn == nil: return false
  vancode_pushg(d, jitImmortalStr(cached.getArg1Str(pc, ch)), fn)
  true

proc emitGlobalPop*(d: ptr ptr dasm_State, cached: CachedOps, pc: int,
    ch: Chunk, bridgeName: string): bool =
  ## Pop one slot into a global through the host bridge (no push back:
  ## net -1, matching the interpreter).
  let fn = findJitHostBridge(bridgeName)
  if fn == nil: return false
  vancode_pop_host(d, jitImmortalStr(cached.getArg1Str(pc, ch)), fn)
  true

proc emitHostCallValue*(d: ptr ptr dasm_State, nArgs: int,
    bridgeName: string, metaId: int32): bool =
  ## Call a host bridge with the top `nArgs` slots as flatArgs (ints raw,
  ## Values tagged) and push its int64 result. Net -(nArgs-1), matching a
  ## CallD-shaped op. `metaId` rides the procId slot for site metadata.
  let fn = findJitHostBridge(bridgeName)
  if fn == nil: return false
  emitCallArgs(d, nArgs)
  vancode_call_invoke(d, nArgs.cint, metaId, fn)
  vancode_call_finish(d, (2 * nArgs * 8).cint)
  true

proc emitHostCallVoid*(d: ptr ptr dasm_State, nArgs: int,
    bridgeName: string, metaId: int32): bool =
  ## Like `emitHostCallValue` but the bridge returns nothing meaningful:
  ## drop its dummy push. Net -nArgs, matching a pop-only op.
  let fn = findJitHostBridge(bridgeName)
  if fn == nil: return false
  emitCallArgs(d, nArgs)
  vancode_call_invoke(d, nArgs.cint, metaId, fn)
  vancode_call_finish(d, (2 * nArgs * 8).cint)
  vancode_discard(d, 1)
  true
