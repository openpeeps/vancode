# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Native-stack value convention shared by the VM and the JIT compilers.
##
## The JIT native stack is a plain int64 stack, invisible to the GC:
## - ints/bools travel raw (int64 / 0-or-1),
## - every other `Value` travels as a tagged ring index (high 32 bits =
##   epoch, low 12 = ring slot) into a GC-rooted global ring.
## Epoch tagging lets consumers tell raw ints apart from indices
## (`jitTryUnroot`) instead of guessing. This module is a leaf (imports
## only `value`) so both `vm` and `jit/compiler_bridge` can use it
## without import cycles.
import ../value

const jitValueRingSize* = 4096
var jitValueRing: array[jitValueRingSize, Value]
var jitRingEpoch: array[jitValueRingSize, uint32]
var jitValueRingPos = 0
var jitEpoch: uint32 = 0

proc jitRootValue*(v: Value): int64 {.cdecl, exportc.} =
  ## Root a `Value` for native-stack transit and return its tagged index.
  ## Epoch 0 is never issued (it means "untagged raw int").
  inc jitEpoch
  if jitEpoch == 0: inc jitEpoch
  result = ((jitEpoch.uint64 shl 32) or jitValueRingPos.uint64).int64
  jitValueRing[jitValueRingPos] = v
  jitRingEpoch[jitValueRingPos] = jitEpoch
  jitValueRingPos = (jitValueRingPos + 1) mod jitValueRingSize

proc jitUnrootValue*(idx: int64): Value {.cdecl, exportc.} =
  ## Trusted resolve (the producer guaranteed a tagged index).
  result = jitValueRing[(idx.uint64 and 0xFFF).int]

proc jitTryUnroot*(slot: int64): tuple[v: Value, ok: bool] =
  ## Validated resolve: ok is true iff `slot` is a live tagged index.
  ## Untagged raw ints/bools (and stale slots) report ok == false, in
  ## which case the caller must treat the slot as a raw int64.
  let epoch = (slot.uint64 shr 32).uint32
  let pos = (slot.uint64 and 0xFFF).int
  if epoch != 0 and epoch == jitRingEpoch[pos]:
    result = (jitValueRing[pos], true)
  else:
    result = (nil, false)

proc jitUnpackArg*(slot: int64): Value =
  ## Bridge argument convention: tagged slots resolve to their `Value`,
  ## untagged raw int64s box as `tyInt`. Total (never raises, never nil).
  let (v, ok) = jitTryUnroot(slot)
  if ok: result = v
  else: result = initValue(slot)

proc jitPackResult*(callResult: Value): int64 =
  ## Native-stack result convention: raw int64 for ints/bools, tagged
  ## ring index for everything else. Never a raw pointer, never 0-loss.
  if callResult == nil: return 0
  case callResult.typeId
  of tyInt: result = callResult.intVal
  of tyBool: result = callResult.boolVal.ord.int64
  else: result = jitRootValue(callResult)
