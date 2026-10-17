## TEMPORARY ARM execution bisect 3b: the method-compiled self
## recursion shape from test_jit_comprehensive ("jit self recursion
## executes patched countdown"), the first test with no [OK] there.
## Delete after diagnosis (with test_zz_arm_bisect3a.nim).
import unittest
import std/tables
import ../src/vancode/interpreter/[chunk, value, vm]

when defined(vancodeJitNim):
  import ../src/vancode/interpreter/jit/compiler_nim as cnim

when defined(vancodeJitNim):
  test "bisect3b self recursion patched countdown":
    stderr.writeLine("[bisect3b] build chunk")
    stderr.flushFile()
    var main = newChunk("count")
    let s = newScript(main)
    s.mainChunk.file = "count"
    var pc = newChunk("count")
    pc.file = "count"
    let selfName = pc.getString("count")
    pc.emit(opcPushL); pc.emit(0u8)
    pc.emit(opcPushI); pc.emit(0i64)
    pc.emit(opcEqI)
    pc.emit(opcJumpFwdF); pc.emit(17u16)
    pc.emit(opcDiscard); pc.emit(1u8)
    pc.emit(opcPushI); pc.emit(0i64)
    pc.emit(opcJumpFwd); pc.emit(22u16)
    pc.emit(opcDiscard); pc.emit(1u8)
    pc.emit(opcPushL); pc.emit(0u8)
    pc.emit(opcPushI); pc.emit(1i64)
    pc.emit(opcSubI)
    pc.emit(opcCallD); pc.emit(selfName); pc.emit(0u16)
    pc.emit(opcReturnVal)
    let p = Proc(name: "count", kind: pkNative, chunk: pc,
      paramCount: 1, hasResult: true)
    p.procId = 0
    s.procs.add(p)
    let vm = newVm()
    vm.importedModules["count"] = s
    stderr.writeLine("[bisect3b] compile")
    stderr.flushFile()
    let fn = cnim.compileProcNim(vm, p)
    check fn != nil
    stderr.writeLine("[bisect3b] call(5)")
    stderr.flushFile()
    var five = [initValue(5i64)]
    check fn(cast[StackView](addr five[0]), 1).intVal == 0
    stderr.writeLine("[bisect3b] returned ok")
    stderr.flushFile()
    var zero = [initValue(0i64)]
    check fn(cast[StackView](addr zero[0]), 1).intVal == 0
else:
  test "nim jit disabled":
    skip()
