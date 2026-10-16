# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Memory-layout constants for the JIT fast paths (GetI/SetI/GetF/SetF,
## float bit-casts). The native emitters chase `Value`/`Object`/seq pointers
## directly, so every offset here is computed from the actual types with
## `offsetof`/`sizeof` — never magic numbers. If a Nim upgrade changes a
## layout, `tests/test_jit_layout.nim` fails loudly instead of miscompiling.
##
## Verified against live objects on Nim 2.3.1/x86_64 (see the test):
## - `TypeId` occupies 8 bytes; tag at +0 in both `Value` and `ValueStorage`.
## - `Value.objectVal` / `intVal` payload at +8 (variant union).
## - `Object.isForeign` byte at +0, `Object.fields` seq VALUE at +24.
## - Seq values are 16 bytes: length inline at +0, heap block pointer at +8
##   (this is why consecutive seq fields sit 16 apart). Elements start 8
##   past the block pointer.
## - `ValueStorage` is 16 bytes: tag at +0, int/bool/float/ref payload at +8.
import ../[value]

const
  offValType* = offsetof(Value, typeId)
    ## Offset of the type tag inside a `Value` (0).
  valTagBytes* = sizeof(TypeId)
    ## Width of the tag field (8: full-word compares).
  offValObj* = offsetof(Value, objectVal)
    ## Offset of the `Object` pointer / int payload inside a `Value` (8).
  offObjForeign* = offsetof(Object, isForeign)
    ## Offset of the `isForeign` flag inside an `Object` (0, single byte).
  offObjFields* = offsetof(Object, fields)
    ## Offset of the `fields` seq value inside an `Object` (24).
  offObjFieldsPtr* = offObjFields + 8
    ## Offset of the heap block pointer inside the `fields` seq value (32).
  seqLenOff* = 0
    ## Offset of the inline length inside a seq value (verified live: the
    ## slot itself holds the length, which is why `len` never dereferences).
  seqPtrOff* = 8
    ## Offset of the heap block pointer inside a seq value (verified live).
  blockDataOff* = 8
    ## Offset of element 0 from the heap block pointer (verified live:
    ## `addr(fields[0]) == blockPtr + 8`).
  sizeVs* = sizeof(ValueStorage)
    ## Stride of one array/object slot (16).
  offVsType* = offsetof(ValueStorage, typeId)
    ## Offset of the slot tag (0).
  offVsInt* = offsetof(ValueStorage, intVal)
    ## Offset of the slot int/bool/float payload (8).

static:
  assert offValType == 0
  assert valTagBytes == 8
  assert offValObj == 8
  assert offObjForeign == 0
  assert offObjFields == 24
  assert offObjFieldsPtr == 32
  assert sizeVs == 16
  assert offVsType == 0
  assert offVsInt == 8
  assert offVsInt == 8
