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

import std/[strutils, json]
import pkg/openparser/json

## This module defines the Value type, which represents a value in the
## interpreter. This represents all the possible values that can be
## manipulated by the interpreter, including primitive types like bools and
## ints, as well as complex types like objects and arrays.
## 
## It also includes utilities for initializing and converting values, as well as a
## foreign proc system for handling native code in the standard library and
## user-defined foreign procs in general.

const
  ValueSize* = max([
    sizeof(bool),
    sizeof(float),
    sizeof(string)
  ])

const
  tyNil* = 0
  tyBool* = 1
  tyInt* = 2
  tyFloat* = 3
  tyString* = 4
  tyFirstObject* = 10
  tyJsonStorage* = 11
  tyArrayObject* = 12
  tyPointer* = 15
  tyAny* = 16
  tyCoroutine* = 17

type
  TypeId* = range[0..32766]  # max amount of case object branches

  ForeignData* {.acyclic.} = object
    data*: pointer
    libpath*: string
    destructor*: proc (data: pointer) {.nimcall.}

  Object* {.acyclic.} = ref object
    ## Represents an object value, which can be either a native
    ## object with fields or a foreign object with a data pointer and library path
    case isForeign*: bool
    of true:
      foreign*: ForeignData
    of false:
      keys*: seq[string]
        ## the field names of this object
        ## stored in the same order as `fields`
      fields*: seq[Value]
        ## the fields of this object, stored
        ## in the same order as `keys`

  Value* {.acyclic.} = ref object
    case typeId*: TypeId  ## the type ID, used for dynamic dispatch
    of tyBool:
      boolVal*: bool
    of tyInt:
      intVal*: int64
    of tyFloat:
      floatVal*: float64
    of tyString:
      stringVal*: ref string
    of tyJsonStorage:
      jsonVal*: JsonNode
    # of tyAny:
      # anyVal*: Value
    else:
      objectVal*: Object

  # ValuePtr* = Value
  #  ## A pointer to a value.

  Stack* = seq[Value]
    ## A runtime stack of values, used in the VM.

  StackView* = ptr UncheckedArray[Value]
    ## An unsafe view into a Stack.

  ForeignProc* = proc (args: StackView, argc: int): Value
    ## A foreign proc implementation, used for native code in
    ## the standard library and user-defined foreign procs in general

proc `=destroy`*(fd: ForeignData) =
  if fd.destructor != nil and fd.data != nil:
    fd.destructor(fd.data)

proc dumpHook*(s: var string, val: Value) =
  ## OpenParser JSON dumping hook for Values
  case val.typeId
  of tyNil: s.add("nil")
  of tyBool: s.add($val.boolVal)
  of tyInt: s.add($val.intVal)
  of tyFloat: s.add($val.floatVal)
  of tyString: s.add(val.stringVal[])
  of tyJsonStorage: 
    dumpHook(s, val.jsonVal)
  of tyArrayObject: 
    for i in 0..<val.objectVal.fields.len:
      if i > 0: s.add(", ")
      case val.objectVal.fields[i].typeId
      of tyString:
        s.add("\"" & val.objectVal.fields[i].stringVal[] & "\"")
      else:
        dumpHook(s, val.objectVal.fields[i])
  of tyPointer:
    case val.objectVal.isForeign:
    of true:
      if val.objectVal == nil or val.objectVal.foreign.data == nil:
        s.add("pointer<nil>")
      else:
        s.add("pointer<0x" & $cast[uint](val.objectVal.foreign.data) & " at " & val.objectVal.foreign.libpath & ">")
    else: s.add("")
  else: s.add("<object>")

proc `$`*(value: Value): string =
  ## Returns a value's string representation.
  result = 
    case value.typeId
    of tyNil: "nil"
    of tyBool: $value.boolVal
    of tyInt: $value.intVal
    of tyFloat: $value.floatVal
    of tyString: value.stringVal[]
    of tyJsonStorage: toJson(value.jsonVal)
    of tyArrayObject: toJson(value.objectVal.fields)
    of tyPointer:
      case value.objectVal.isForeign:
      of true:
        if value.objectVal == nil or value.objectVal.foreign.data == nil:
          "pointer<nil>"
        else:
          "pointer<0x" & $cast[uint](value.objectVal.foreign.data) & ">"
      else: ""
    else: "<object>"

proc toString*(value: JsonNode): string =
  ## Converts a JSON node to a string.
  case value.kind
  of JNull: "null"
  of JBool: $value.bVal
  of JInt: $value.num
  of JFloat: $value.fnum
  of JString: value.str
  of JArray: toJson(value)
  of JObject: toJson(value)

proc initValue*(v: bool): Value =
  ## Initializes a bool value.
  result = Value(typeId: tyBool, boolVal: v)

proc initValue*(v: int64): Value =
  ## Initializes a float value.
  result = Value(typeId: tyInt, intVal: v)

proc initValue*(v: float64): Value =
  ## Initializes a float value.
  result = Value(typeId: tyFloat, floatVal: v)

proc initValue*(v: string): Value =
  ## Initializes a string value.
  result = Value(typeId: tyString)
  new(result.stringVal)
  result.stringVal[] = v

proc initValue*(v: JsonNode): Value =
  ## Initializes a JSON value.
  result = Value(typeId: tyJsonStorage)
  result.jsonVal = v

proc initValue*(nptr: pointer, libpath: string): Value =
  ## Initializes a pointer value.
  result = Value(typeId: tyPointer)
  result.objectVal = Object(isForeign: true,
    foreign: ForeignData(data: nptr, libpath: libpath))

proc initValue*[T: tuple | object | ref](id: TypeId, value: T): Value =
  ## Safely initializes a foreign object value.
  ## This copies the value onto the heap for ordinary objects and tuples,
  ## and GC_refs the value for refs.
  result = Value(typeId: id)
  when T is tuple | object:
    let data = cast[ptr T](alloc(sizeof(T)))
    data[] = value
    result.objectVal = Object(isForeign: true,
      foreign: ForeignData(
        data: data,
        destructor: proc (data: pointer) {.nimcall.} = dealloc(data)
      ))
  elif T is ref:
    GC_ref(value)
    result.objectVal = Object(isForeign: true,
      foreign: ForeignData(
        data: cast[pointer](value),
        destructor: proc (data: pointer) {.nimcall.} = GC_unref(cast[T](data))
      ))

proc foreign*(value: Value, T: typedesc): T =
  ## Get an object value. This is a *mostly* safe operation, but attempting to
  ## get a foreign type different from the value's is undefined behavior.
  result = cast[ptr T](value.objectVal.foreign.data)[]

const nilObject* = -1 ## The field count used for initializing a nil object.

proc initObject*(id: TypeId, fieldCount: int): Value =
  ## Initializes a native object value, with ``fieldCount`` fields.
  result = Value(typeId: id)
  if fieldCount == nilObject:
    result.objectVal = nil
  else:
    result.objectVal =
      Object(isForeign: false, fields: newSeq[Value](fieldCount))

proc initArray*(length: int): Value =
  ## Initializes an array value.
  result = initObject(tyArrayObject, 0)
  result.objectVal =
    Object(isForeign: false, fields: newSeq[Value](length))

type
  JitHooks* = object
    ## JIT hooks installed into the VM.
    ## Uses raw pointer to avoid circular deps between vm and jit modules.
    getForeign*: proc (procPtr: pointer): ForeignProc
      ## Given a Proc pointer, returns its JIT-compiled ForeignProc if available.
    queueCompile*: proc (theProc: pointer)
      ## Queue a proc for async JIT compilation.
      ## Called from markHotProc. theProc is cast(pointer, Proc).