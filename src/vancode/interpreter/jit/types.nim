# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import pkg/gccjit
import ../value

type
  JitTypes* = object
    i64Type*: ptr gcc_jit_type
    f64Type*: ptr gcc_jit_type
    boolType*: ptr gcc_jit_type
    voidType*: ptr gcc_jit_type
    cstringType*: ptr gcc_jit_type
    voidPtrType*: ptr gcc_jit_type
    valueStruct*: ptr gcc_jit_struct
    valueStructType*: ptr gcc_jit_type
    typeIdField*: ptr gcc_jit_field
    intValField*: ptr gcc_jit_field
    floatValField*: ptr gcc_jit_field
    ptrValField*: ptr gcc_jit_field
    returnStruct*: ptr gcc_jit_struct
    returnStructType*: ptr gcc_jit_type

  JitReturn* = object
    typeId*: int64
    intVal*: int64
    floatVal*: float64
    ptrVal*: pointer

proc initJitTypes*(ctx: ptr gcc_jit_context): JitTypes =
  result.i64Type     = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_INT64_T)
  result.f64Type     = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_DOUBLE)
  result.boolType    = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_BOOL)
  result.voidType    = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_VOID)
  result.cstringType = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_CONST_CHAR_PTR)
  result.voidPtrType = gcc_jit_type_get_pointer(
    gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_VOID))

  var valFields: array[4, ptr gcc_jit_field]
  valFields[0] = gcc_jit_context_new_field(ctx, nil, result.i64Type, "typeId")
  valFields[1] = gcc_jit_context_new_field(ctx, nil, result.i64Type, "intVal")
  valFields[2] = gcc_jit_context_new_field(ctx, nil, result.f64Type, "floatVal")
  valFields[3] = gcc_jit_context_new_field(ctx, nil, result.voidPtrType, "ptrVal")
  result.typeIdField = valFields[0]
  result.intValField = valFields[1]
  result.floatValField = valFields[2]
  result.ptrValField = valFields[3]
  result.valueStruct = gcc_jit_context_new_struct_type(ctx, nil, "JitValue", 4, addr valFields[0])
  result.valueStructType = gcc_jit_struct_as_type(result.valueStruct)

  var retFields: array[4, ptr gcc_jit_field]
  retFields[0] = gcc_jit_context_new_field(ctx, nil, result.i64Type, "typeId")
  retFields[1] = gcc_jit_context_new_field(ctx, nil, result.i64Type, "intVal")
  retFields[2] = gcc_jit_context_new_field(ctx, nil, result.f64Type, "floatVal")
  retFields[3] = gcc_jit_context_new_field(ctx, nil, result.voidPtrType, "ptrVal")
  result.returnStruct = gcc_jit_context_new_struct_type(ctx, nil, "JitReturn", 4, addr retFields[0])
  result.returnStructType = gcc_jit_struct_as_type(result.returnStruct)
