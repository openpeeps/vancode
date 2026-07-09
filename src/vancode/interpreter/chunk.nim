# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) iLiquid, 2019-2020
#     https://github.com/liquidev/
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import std/[tables, hashes, dynlib, strutils, atomics]
import pkg/voodoo/extensibles
import ./value

## This module defines the Chunk type, which represents a chunk of bytecode. It also
## defines the Script type, which represents a script being executed by the interpreter.
## 
## This module provides utilities for emitting bytecode into a chunk, as well as for
## managing line information for error reporting

type
  Opcode* {.extensible.} = enum
    ## An opcode, used for execution.

    opcNoop = "noop"

    # stack
    opcPushTrue = "pushTrue"
    opcPushFalse = "pushFalse"
    opcPushNil = "pushNil"
    opcPushJNil = "pushJNil"      ## push a JSON nil
    
    opcPushI = "pushI"            ## push int
    opcPushF = "pushF"            ## push float
    opcPushS = "pushS"            ## push string
    opcPushG = "pushG"            ## push global
    opcPopG = "popG"              ## pop global
    opcPushL = "pushL"            ## push local
    opcPopL = "popL"              ## pop local
    opcIncL = "incL"              ## increment local by 1 in-place
    opcDecL = "decL"              ## decrement local by 1 in-place

    opcFFIGetProc = "ffiGetProc"     ## get a symbol from a dynamic library
    opcPushPointer = "pushPointer"   # push a pointer value onto the stack
    opcPopPointer = "popPointer"     # pop a pointer value from the stack
    
    opcConstrObj = "constrObj"    ## construct object

    opcGetF = "getF"              ## push field
    opcSetF = "setF"              ## pop field
    
    opcConstrArray = "constrArray"  ## construct array
    opcGetI = "getI"                ## get array item
    opcSetI = "setI"                ## set array item

    opcDiscard = "discard"        ## discard values

    # json operations
    opcGetJ = "getJ"              ## get JSON value
    opcSetJ = "setJ"              ## set JSON value

    # string operations
    opcConcatStr = "concatStr"    ## concatenate two strings

    # arithmetic operations
    opcNegI = "negI"              ## negate int
    opcAddI = "addI"              ## add ints
    opcSubI = "subI"              ## subtract ints
    opcMultI = "multI"            ## multiply ints
    opcDivI = "divI"              ## divide ints
    opcNegF = "negF"              ## negate float
    opcAddF = "addF"              ## add floats
    opcSubF = "subF"              ## subtract floats
    opcMultF = "multF"            ## multiply floats
    opcDivF = "divF"              ## divide floats

    # logic operations
    opcInvB = "invB"              ## invert bool

    # relational operations
    opcEqB = "eqB"                ## equal bools
    opcEqI = "eqI"                ## equal ints
    opcLessI = "lessI"            ## int less than
    opcGreaterI = "greaterI"      ## int greater than
    opcEqF = "eqF"                ## equal floats
    opcEqS = "eqS"                ## string equality
    opcLessF = "lessF"            ## float less than
    opcGreaterF = "greaterF"      ## float greater than

    # execution
    opcJumpFwd = "jumpFwd"        ## jump forward
    opcJumpFwdT = "jumpFwdT"      ## jump forward if true
    opcJumpFwdF = "jumpFwdF"      ## jump forward if false
    opcJumpBack = "jumpBack"      ## jump backward
    opcCallD = "callD"            ## call direct
    opcCallI = "callI"            ## call indirect
    opcPushProc = "pushProc"      ## push a proc reference
    opcReturnVal = "returnVal"    ## return value from proc
    opcReturnVoid = "returnVoid"  ## return void from proc

    opcImportModule = "importModule"  ## import a module

    opcHalt = "halt"              ## halt the VM

    # coroutines
    opcCreateCoro = "createCoro"  ## create a coroutine from a proc
    opcCoroResume = "coroResume"  ## resume a coroutine
    opcCoroYield = "coroYield"    ## yield from a coroutine

  Script* {.acyclic.} = ref object
    stdpos*: int
    libs*: Table[string, LibHandle]
      ## a table of dynamic libraries loaded by this script
    procs*: seq[Proc]
      ## all procs declared in this script
    procsExport*: seq[Proc]
      ## the public procs declared in this script
      ## these are the procs that can be called from
      ## other scripts
    mainChunk*: Chunk  ## the main chunk of this script
    mainProc*: Proc    ## synthetic Proc wrapping mainChunk (for JIT)
    scripts*: Table[string, Script]
      ## a table of scripts, basically reprresenting the
      ## modules the script imports
    jsOutput*: string

  LineInfo* = tuple
    ## Line information.
    file: string  # very inefficient! it would probably be wiser to use
                  # an int ID for this
    ln, col: int
    runLength: int

  Chunk* {.acyclic.} = ref object
    ## A chunk of bytecode
    id*: int
    file*: string
      # the filename of the module this chunk belongs to
    code*: seq[uint8]
      ## the raw bytecode
    ln*: int = 1
      ## the current line number, used when emitting ## bytecode
    col*: int
      ## the current column number, used when emitting bytecode
    lineInfo: seq[LineInfo]
      ## a list of run-length encoded line info
    hotLoopCount*: int
      ## backward jump counter for hot loop detection
    hotLoopCompiled*: bool
      ## whether this chunk has been attempted for JIT compilation
    hotLoopQueued*: bool
      ## whether JIT compilation has been queued for this chunk
    hotLoopOwner*: Proc
      ## cached owning Proc for this chunk (used by async JIT)
    strings*: seq[string] = newSeqOfCap[string](64)
      ## seq of strings used in this chunk (for string literals, global names, etc.)
    stringIds: Table[string, uint16] = initTable[string, uint16](64)
      ## a table mapping strings to their IDs in `strings`

  ProcKind* = enum
    ## The kind of a procedure. This is used to determine how the procedure should be called.
    pkNative   ## a native (bytecode) proc
    pkForeign  ## a foreign (Nim) proc defined at compile-time

  Proc* {.acyclic.} = ref object
    ## A runtime procedure.
    name*: string
    procId*: int
    jitCodePtr*: pointer  ## JIT-compiled function pointer, set atomically
    jitMaxLocal*: int     ## Max local slots used by JIT code
    jitReturnBool*: bool   ## Whether the JIT-compiled proc returns bool
    jitReturnString*: bool ## Whether the JIT-compiled proc returns string
    case kind*: ProcKind
    of pkNative:
      chunk*: Chunk          ## the chunk of bytecode of this procedure
    of pkForeign:
      foreign*: ForeignProc  ## the foreign implementation of this procedure
    paramCount*: int
      ## the number of parameters this procedure takes
    hasResult*: bool
      ## flag signifying whether the proc returns a value
    jitForeign*: ForeignProc
      ## JIT-compiled version of this proc (nil if not compiled or native)
    jitCallCount*: int
      ## call counter for profile-guided recompilation
    jitRecompiled*: bool
      ## whether this proc has been recompiled at -O3

var nextChunkId {.global.}: int = 0

proc addLineInfo*(chunk: var Chunk, n: int) =
  ## Add ``n`` line info entries to the chunk.
  if chunk.lineInfo.len > 0:
    if chunk.lineInfo[^1].ln == chunk.ln and
       chunk.lineInfo[^1].col == chunk.col:
      inc(chunk.lineInfo[^1].runLength, n)
      return
  chunk.lineInfo.add((chunk.file, chunk.ln, chunk.col, n))

const MaxIds = int(high(uint16)) + 1

proc getString*(chunk: var Chunk, str: sink string): uint16 =
  ## O(1) string interning with a hash index; returns existing id or inserts.
  ## Guards against uint16 overflow and avoids extra string copy via move.
  if chunk.stringIds.hasKey(str):
    return chunk.stringIds[str]

  # this should never happen in practice
  if unlikely(chunk.strings.len >= MaxIds):
    raise newException(RangeDefect,
      "chunk string table overflow (uint16 id space exhausted)")

  let nextId = chunk.strings.len.uint16
  discard chunk.stringIds.hasKeyOrPut(str, nextId)  # puts nextId if missing
  chunk.strings.add(ensureMove(str))  # transfer ownership, avoid extra refcount/copy
  result = nextId

proc emit*(chunk: var Chunk, opc: Opcode) =
  ## Emit an opcode. This ignores noop opcodes.
  if opc != opcNoop:
    chunk.addLineInfo(1)
    chunk.code.add(opc.uint8)

proc emit*(chunk: var Chunk, u8: uint8) =
  ## Emit a `uint8`.
  chunk.addLineInfo(sizeof(uint8))
  chunk.code.add(u8)

proc emit*(chunk: var Chunk, u16: uint16) =
  ## Emit a `uint16`.
  chunk.addLineInfo(sizeof(uint16))
  chunk.code.add(cast[array[sizeof(uint16), uint8]](u16))
  # append as little-endian bytes explicitly to avoid UB from cast-to-array
  # chunk.code.add(uint8(u16 and 0x00ff))
  # chunk.code.add(uint8((u16 shr 8) and 0x00ff))

proc emit*(chunk: var Chunk, val: int64) =
  ## Emit an `int`.
  chunk.addLineInfo(ValueSize)
  chunk.code.add(cast[array[sizeof(int64), uint8]](val))
  # append int64 as little-endian bytes
  # let uval = cast[uint64](val)
  # for b in 0..<sizeof(int64):
  #   chunk.code.add(uint8((uval shr (8 * b)) and 0xff))

proc emit*(chunk: var Chunk, val: float64) =
  ## Emit a `float`.
  chunk.addLineInfo(ValueSize)
  chunk.code.add(cast[array[sizeof(float64), uint8]](val))
  # reinterpret float bits and append as little-endian bytes
  # let uval = cast[uint64](val)
  # for b in 0..<sizeof(float64):
  #   chunk.code.add(uint8((uval shr (8 * b)) and 0xff))

proc emit*(chunk: var Chunk, xptr: pointer) =
  ## Emit a `pointer`.
  chunk.addLineInfo(sizeof(pointer))
  chunk.code.add(cast[array[sizeof(pointer), uint8]](xptr))
  # let pval = cast[uint64](cast[pointer](xptr))
  # for b in 0..<sizeof(pointer):
  #   chunk.code.add(uint8((pval shr (8 * b)) and 0xff))

proc emitHole*(chunk: var Chunk, size: int): int =
  ## Emit a hole, to be filled later by ``fillHole``.
  result = chunk.code.len
  chunk.addLineInfo(size)
  for i in 1..size:
    chunk.code.add(0x00)

proc fillHole*(chunk: var Chunk, hole: int, val: uint8) =
  ## Fill a hole with an 8-bit value.
  chunk.code[hole] = val

proc fillHole*(chunk: var Chunk, hole: int, val: uint16) =
  ## Fill a hole with a 16-bit value.
  chunk.code[hole] = uint8(val and 0x00ff)
  chunk.code[hole + 1] = uint8((val and 0xff00) shr 8)

proc patchHole*(chunk: var Chunk, hole: int) =
  ## Fill a 16-bit hole with the current chunk's length + 1.

  chunk.fillHole(hole, uint16(chunk.code.len - hole + 1))

proc getOpcode*(chunk: Chunk, i: int): Opcode =
  ## Get the opcode at position ``i``.
  result = chunk.code[i].Opcode

proc getU8*(chunk: Chunk, i: int): uint8 =
  ## Gets the ``uint8`` at position ``i``.
  result = chunk.code[i]

proc getU16*(chunk: Chunk, i: int): uint16 =
  ## Get the ``uint16`` at position ``i``.
  result = chunk.code[i].uint16 or chunk.code[i + 1].uint16 shl 8

proc getInt*(chunk: Chunk, i: int): int64 =
  ## Get a constant int at position ``i``.
  var
    bytes: array[sizeof(int64), uint8]
    raw = cast[ptr UncheckedArray[uint8]](chunk.code[i].unsafeAddr)
  for i in low(bytes)..high(bytes):
    bytes[i] = raw[i]
  result = cast[int64](bytes)

proc getFloat*(chunk: Chunk, i: int): float64 =
  ## Get a constant float at position ``i``.
  var
    bytes: array[sizeof(float64), uint8]
    raw = cast[ptr UncheckedArray[uint8]](chunk.code[i].unsafeAddr)
  for i in low(bytes)..high(bytes):
    bytes[i] = raw[i]
  result = cast[float64](bytes)

proc getLineInfo*(chunk: Chunk, i: int): LineInfo =
  ## Get the line info at position ``i``. **Warning:** This is very slow,
  ## because it has to walk the entire chunk decoding the run length encoded
  ## line info!
  var n = 0
  for li in chunk.lineInfo:
    for r in 1..li.runLength:
      if n == i: return li
      inc(n)

proc getLineInfoTable*(chunk: Chunk): seq[LineInfo] =
  ## Get the line info table for this chunk,
  ## expanding the run-length encoding.
  chunk.lineInfo

proc setLineInfoTable*(chunk: var Chunk, info: seq[LineInfo]) =
  ## Set the line info table for this chunk,
  ## compressing it with run-length encoding.
  chunk.lineInfo = info

proc rebuildStringIds*(chunk: var Chunk) =
  ## Rebuild the string ID table from the strings sequence.
  ## This is necessary after deserializing a chunk, because the string IDs are not
  ## stored in the serialized form of the chunk.
  chunk.stringIds.clear()
  for i, s in chunk.strings:
    if i > int(high(uint16)):
      raise newException(RangeDefect, "chunk string table overflow while rebuilding")
    chunk.stringIds[s] = uint16(i)

proc newChunk*(file: string): Chunk =
  ## Create a new chunk.
  result = Chunk(file: file, col: 0)
  result.id = atomicInc(nextChunkId)

proc newScript*(main: Chunk): Script =
  ## Create a new script, with the given main chunk.
  result = Script(mainChunk: main)

proc hash*(x: Chunk): Hash =
  ## Hashes a Chunk by its unique ID
  hash(x.id)

proc `==`*(a, b: Chunk): bool =
  ## Compares two Chunks by unique ID
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  a.id == b.id

proc `$`*(c: Chunk): string =
  result = "<chunk: $1>" % $(c.id)

proc hash*(x: Script): Hash =
  hash(cast[pointer](x))

proc hash*(x: Proc): Hash =
  hash(cast[pointer](x))

proc `==`*(a, b: Proc): bool {.inline.} =
  if a.isNil and b.isNil: return true
  if a.isNil or b.isNil: return false
  cast[pointer](a) == cast[pointer](b)

proc `$`*(s: Script): string =
  result = "<script: $1>" % $hash(s)
