## Pure-Nim JIT emitter backend for VanCode.
##
## Assembly routines for the method, trace and fib compilers below,
## written against the dynasm-nim DSL. Semantics: same registers, same
## stack discipline, same calling convention on both architectures
## (rdi=flatArgs, rsi=argc, rax=result, rbx=args-ptr, r12=scratch on
## x64; x0=flatArgs, x1=argc, x0=result, x19=args, x20=scratch on
## arm64 with 16-byte operand slots).
##
## Sessions: one NimJit per compiled function. `nFib` needs a fresh
## session (it is a standalone entry point, like vancode_fib).
## Jump targets use VanCode's label numbering ("L" & $n); each number
## is defined exactly once per session.

when not defined(amd64) and not defined(arm64):
  {.error: "vancode Nim JIT needs amd64 or arm64".}

import dynasm
import ../value
import ./jit_layout
import ./jit_values

type
  NimJit* = object
    a*: Assembler

proc initNimJit*(): NimJit =
  when defined(amd64):
    result.a = newAssembler(akX64)
  else:
    result.a = newAssembler(akAarch64)

proc nimJitFinish*(s: var NimJit): ExecutableBuffer =
  s.a.finalize()

proc ndefLabel*(a: var Assembler, n: int) =
  ## Bind jump-target label number n (VanCode numbering).
  a.localLabel("L" & $n)

proc nprologue*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Frame setup: save rbp/rbx/r12, point rbx at the flatArgs base
      push rbp
      mov rbp, rsp
      push rbx
      push r12
      mov rbx, rdi
  else:
    dynasm a:
      arch aarch64
      # Frame setup: save fp/lr plus x19/x20, point x19 at flatArgs
      stp x29, x30, [sp, -48], pre
      mov x29, sp
      str x19, [sp, 16]
      str x20, [sp, 24]
      mov x19, x0

proc nloadParam*(a: var Assembler, slot: int) =
  let disp = slot * 8
  when defined(amd64):
    dynasm a:
      arch x64
      # Push flatArgs[slot] (caller-provided argument) onto the operand stack
      push qword [rbx + disp]
  else:
    dynasm a:
      arch aarch64
      # Same, using a 16-byte operand slot on arm64
      ldr x9, [x19, disp]
      str x9, [sp, -16], pre

proc npushI*(a: var Assembler, value: int) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Push a signed 64-bit constant (movabs covers the full range)
      mov rax, value
      push rax
  else:
    let lo = value and 0xFFFF
    let hi = (value shr 16) and 0xFFFF
    dynasm a:
      arch aarch64
      # Build a 32-bit constant from two halfwords, then sign-extend it
      movz x9, lo
      movk x9, hi, lsl, 16
      # sxtw x9, w9 via shifts (standalone sxtw not in the ISA yet)
      lsl x9, x9, 32
      asr x9, x9, 32
      str x9, [sp, -16], pre

proc npushTrue*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Booleans travel raw as 0/1, just like ints
      push 1
  else:
    dynasm a:
      arch aarch64
      mov x9, 1
      str x9, [sp, -16], pre

proc npushFalse*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # False and nil share the zero slot encoding on the native stack
      push 0
  else:
    dynasm a:
      arch aarch64
      str xzr, [sp, -16], pre

proc npushNil*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Nil is also a zero slot; bridges re-box it on the way out
      push 0
  else:
    dynasm a:
      arch aarch64
      str xzr, [sp, -16], pre

proc npushL*(a: var Assembler, slot: int) =
  let disp = slot * 8
  when defined(amd64):
    dynasm a:
      arch x64
      # Push local slot (flatArgs area addressed through rbx)
      push qword [rbx + disp]
  else:
    dynasm a:
      arch aarch64
      ldr x9, [x19, disp]
      str x9, [sp, -16], pre

proc npopL*(a: var Assembler, slot: int) =
  let disp = slot * 8
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop the top operand back into a local slot
      pop rax
      mov [rbx + disp], rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      str x9, [x19, disp]

proc nincL*(a: var Assembler, slot: int) =
  let disp = slot * 8
  when defined(amd64):
    dynasm a:
      arch x64
      # In-place counter bump, no stack traffic at all
      inc qword [rbx + disp]
  else:
    dynasm a:
      arch aarch64
      ldr x9, [x19, disp]
      add x9, x9, 1
      str x9, [x19, disp]

proc ndecL*(a: var Assembler, slot: int) =
  let disp = slot * 8
  when defined(amd64):
    dynasm a:
      arch x64
      # In-place counter drop, mirrors nincL
      dec qword [rbx + disp]
  else:
    dynasm a:
      arch aarch64
      ldr x9, [x19, disp]
      sub x9, x9, 1
      str x9, [x19, disp]

proc naddI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop b, a (a was pushed first so it sits deeper); push a + b
      pop rax
      pop r12
      add rax, r12
      push rax
  else:
    dynasm a:
      arch aarch64
      # Same shape with 16-byte slots: x9 = b, x10 = a
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      add x10, x10, x9
      str x10, [sp, -16], pre

proc nsubI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Order matters here: pop divisor-side first so rax holds a
      pop r12
      pop rax
      sub rax, r12
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      sub x10, x10, x9
      str x10, [sp, -16], pre

proc nmulI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Signed 64-bit multiply, low half kept (wraps like the interpreter)
      pop rax
      pop r12
      imul rax, r12
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      mul x10, x10, x9
      str x10, [sp, -16], pre

proc ndivI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Signed divide: sign-extend rax into rdx:rax, quotient lands in rax
      pop r12
      pop rax
      cqo
      idiv r12
      push rax
  else:
    dynasm a:
      arch aarch64
      # sdiv truncates toward zero, matching idiv/Nim div on ints
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      sdiv x10, x10, x9
      str x10, [sp, -16], pre

proc nmodI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Same divide setup, but the remainder in rdx is the result
      pop r12
      pop rax
      cqo
      idiv r12
      push rdx
  else:
    # sdiv truncates like x64 idiv, so msub yields the C-style
    # remainder, matching Nim `mod` on ints.
    dynasm a:
      arch aarch64
      # No remainder instruction: quotient via sdiv, then x10 - q*x9
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      sdiv x11, x10, x9
      msub x10, x11, x9, x10
      str x10, [sp, -16], pre

proc nnegI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Unary minus in place: pop, negate, push back
      pop rax
      neg rax
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      neg x9, x9
      str x9, [sp, -16], pre

proc neqI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Compare and push 0/1: sete sets the low byte, movzx widens it
      pop rax
      pop r12
      cmp rax, r12
      sete al
      movzx rax, al
      push rax
  else:
    dynasm a:
      arch aarch64
      # cset writes 0/1 directly from the condition flags
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      cmp x10, x9
      cset w9, eq
      str x9, [sp, -16], pre

proc nlessI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Signed less-than: compare second-popped against top, push 0/1
      pop rax
      pop r12
      cmp r12, rax
      setl al
      movzx rax, al
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      cmp x10, x9
      cset w9, lt
      str x9, [sp, -16], pre

proc ngreaterI*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Signed greater-than, same 0/1 push discipline as the other tests
      pop rax
      pop r12
      cmp r12, rax
      setg al
      movzx rax, al
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      cmp x10, x9
      cset w9, gt
      str x9, [sp, -16], pre

proc ninvB*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Logical not: 0 becomes 1, anything else becomes 0
      pop rax
      test rax, rax
      sete al
      movzx rax, al
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      cmp x9, 0
      cset w9, eq
      str x9, [sp, -16], pre

proc ndiscard*(a: var Assembler, n: int) =
  when defined(amd64):
    let bytes = n * 8
    dynasm a:
      arch x64
      # Drop n operand slots by rewinding rsp (8 bytes each on x64)
      add rsp, bytes
  else:
    let bytes = n * 16
    dynasm a:
      arch aarch64
      # Same, but arm64 slots are 16 bytes wide
      mov x9, bytes
      add sp, sp, x9

proc njumpFwd*(a: var Assembler, target: int) =
  let lbl = "L" & $target
  when defined(amd64):
    dynasm a:
      arch x64
      # Unconditional forward jump to a VanCode-numbered label
      jmp fwd(lbl)
  else:
    dynasm a:
      arch aarch64
      b fwd(lbl)

proc njumpBack*(a: var Assembler, target: int) =
  let lbl = "L" & $target
  when defined(amd64):
    dynasm a:
      arch x64
      # Unconditional backward jump (loop back-edge)
      jmp bwd(lbl)
  else:
    dynasm a:
      arch aarch64
      b bwd(lbl)

proc njumpFwdF*(a: var Assembler, target: int) =
  let lbl = "L" & $target
  when defined(amd64):
    dynasm a:
      arch x64
      # Jump-if-false: consume the condition; taken path leaves the stack
      # popped, fallthrough pushes the value back for the trailing Discard
      pop rax
      test rax, rax
      jz fwd(lbl)
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      cmp x9, 0
      b.eq fwd(lbl)
      str x9, [sp, -16], pre

proc njumpFwdT*(a: var Assembler, target: int) =
  let lbl = "L" & $target
  when defined(amd64):
    dynasm a:
      arch x64
      # Jump-if-true: mirror of the false case, branching on nonzero
      pop rax
      test rax, rax
      jnz fwd(lbl)
      push rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      cmp x9, 0
      b.ne fwd(lbl)
      str x9, [sp, -16], pre

proc nreturnVal*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Return the top operand in rax, then tear down the frame
      pop rax
      pop r12
      pop rbx
      pop rbp
      ret()
  else:
    dynasm a:
      arch aarch64
      # Same: result to x0, restore saved regs and frame in reverse order
      ldr x0, [sp], 16
      ldp x19, x20, [sp, 16]
      ldp x29, x30, [sp], 48
      ret()

proc nreturnVoid*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Void return reports 0; frame teardown identical to nreturnVal
      `xor` eax, eax
      pop r12
      pop rbx
      pop rbp
      ret()
  else:
    dynasm a:
      arch aarch64
      mov x0, 0
      ldp x19, x20, [sp, 16]
      ldp x29, x30, [sp], 48
      ret()

proc ntraceExit*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Trace side-exit: same teardown as a void return; the VM resumes
      # the interpreter past the loop instead of returning a value
      pop r12
      pop rbx
      pop rbp
      `xor` eax, eax
      ret()
  else:
    dynasm a:
      arch aarch64
      mov x0, 0
      ldp x19, x20, [sp, 16]
      ldp x29, x30, [sp], 48
      ret()

proc nfib*(a: var Assembler) =
  ## Iterative fib(n) with n = [flatLocals], result in rax/x0.
  ## Needs a fresh session (standalone entry point).
  when defined(amd64):
    dynasm a:
      arch x64
      # Fast path for n <= 1: fib(0) = 0, fib(1) = 1, return as-is
      mov rax, [rdi]
      test rax, rax
      jz fwd("fib_done")
      cmp rax, 1
      jle fwd("fib_done")
      # Iterative walk: r8 = prev, r9 = current, rcx = steps left
      `xor` r8d, r8d
      mov r9d, 1
      mov rcx, rax
      dec rcx
      label fib_loop
      mov r10, r9
      add r9, r8
      mov r8, r10
      dec rcx
      jnz bwd("fib_loop")
      mov rax, r9
      ret()
      label fib_done
      ret()
  else:
    dynasm a:
      arch aarch64
      # Same shape: x8 = prev, x9 = current, x10 = steps left
      ldr x0, [x0]
      cmp x0, 0
      b.le fwd("fib_done")
      mov x8, xzr
      mov x9, 1
      mov x10, x0
      sub x10, x10, 1
      label fib_loop
      mov x11, x9
      add x9, x9, x8
      mov x8, x11
      sub x10, x10, 1
      b.ne bwd("fib_loop")
      mov x0, x9
      ret()
      label fib_done
      ret()

proc nhalt*(a: var Assembler) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Halt the chunk: report 0 and tear down like a void return
      `xor` eax, eax
      pop r12
      pop rbx
      pop rbp
      ret()
  else:
    dynasm a:
      arch aarch64
      mov x0, 0
      ldp x19, x20, [sp, 16]
      ldp x29, x30, [sp], 48
      ret()

proc npushG*(a: var Assembler, namePtr: pointer, bridgeFn: pointer) =
  let nameAddr = cast[int64](namePtr)
  let bridgeAddr = cast[int64](bridgeFn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Call the host bridge with the immortalized global name in rdi;
      # rbx is parked so the 16-byte stack alignment survives the call.
      # The bridge result (raw int or tagged ring index) is pushed.
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rdi, nameAddr
      movabs rax, bridgeAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
  else:
    let p0 = int(cast[uint64](namePtr) and 0xFFFF'u64)
    let p1 = int((cast[uint64](namePtr) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](namePtr) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](namePtr) shr 48) and 0xFFFF'u64)
    let r0 = int(cast[uint64](bridgeFn) and 0xFFFF'u64)
    let r1 = int((cast[uint64](bridgeFn) shr 16) and 0xFFFF'u64)
    let r2 = int((cast[uint64](bridgeFn) shr 32) and 0xFFFF'u64)
    let r3 = int((cast[uint64](bridgeFn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      # Same call through x0/x16; 64-bit addresses need four movz/movk
      # halfwords each because arm64 has no movabs
      movz x0, p0
      movk x0, p1, lsl, 16
      movk x0, p2, lsl, 32
      movk x0, p3, lsl, 48
      movz x16, r0
      movk x16, r1, lsl, 16
      movk x16, r2, lsl, 32
      movk x16, r3, lsl, 48
      blr x16
      str x0, [sp, -16], pre

proc npopG*(a: var Assembler, namePtr: pointer, bridgeFn: pointer,
    kind: int32) =
  let nameAddr = cast[int64](namePtr)
  let bridgeAddr = cast[int64](bridgeFn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop the value into rsi, pass name + baked slot kind so the bridge
      # boxes raw slots exactly; nothing is pushed back (net -1)
      pop rsi
      movabs rdi, nameAddr
      mov edx, kind
      movabs rax, bridgeAddr
      call rax
  else:
    let p0 = int(cast[uint64](namePtr) and 0xFFFF'u64)
    let p1 = int((cast[uint64](namePtr) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](namePtr) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](namePtr) shr 48) and 0xFFFF'u64)
    let r0 = int(cast[uint64](bridgeFn) and 0xFFFF'u64)
    let r1 = int((cast[uint64](bridgeFn) shr 16) and 0xFFFF'u64)
    let r2 = int((cast[uint64](bridgeFn) shr 32) and 0xFFFF'u64)
    let r3 = int((cast[uint64](bridgeFn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      # Same triple (name in x0, value in x1, kind in x2), no push back
      ldr x1, [sp], 16
      movz x0, p0
      movk x0, p1, lsl, 16
      movk x0, p2, lsl, 32
      movk x0, p3, lsl, 48
      mov x2, kind
      movz x16, r0
      movk x16, r1, lsl, 16
      movk x16, r2, lsl, 32
      movk x16, r3, lsl, 48
      blr x16

proc npopHost*(a: var Assembler, namePtr: pointer, bridgeFn: pointer) =
  let nameAddr = cast[int64](namePtr)
  let bridgeAddr = cast[int64](bridgeFn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop-and-store variant of npushG: value in rsi, name in rdi,
      # no result is pushed back
      pop rsi
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rdi, nameAddr
      movabs rax, bridgeAddr
      call rax
      mov rsp, rbx
      pop rbx
  else:
    let p0 = int(cast[uint64](namePtr) and 0xFFFF'u64)
    let p1 = int((cast[uint64](namePtr) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](namePtr) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](namePtr) shr 48) and 0xFFFF'u64)
    let r0 = int(cast[uint64](bridgeFn) and 0xFFFF'u64)
    let r1 = int((cast[uint64](bridgeFn) shr 16) and 0xFFFF'u64)
    let r2 = int((cast[uint64](bridgeFn) shr 32) and 0xFFFF'u64)
    let r3 = int((cast[uint64](bridgeFn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      ldr x1, [sp], 16
      movz x0, p0
      movk x0, p1, lsl, 16
      movk x0, p2, lsl, 32
      movk x0, p3, lsl, 48
      movz x16, r0
      movk x16, r1, lsl, 16
      movk x16, r2, lsl, 32
      movk x16, r3, lsl, 48
      blr x16

proc nbridge2*(a: var Assembler, fn: pointer) =
  let fnAddr = cast[int64](fn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Two stack slots become rdi/rsi for a host call; result is pushed
      pop rsi
      pop rdi
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, fnAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
  else:
    let p0 = int(cast[uint64](fn) and 0xFFFF'u64)
    let p1 = int((cast[uint64](fn) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](fn) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](fn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      ldr x1, [sp], 16
      ldr x0, [sp], 16
      movz x16, p0
      movk x16, p1, lsl, 16
      movk x16, p2, lsl, 32
      movk x16, p3, lsl, 48
      blr x16
      str x0, [sp, -16], pre

proc nbridge3Void*(a: var Assembler, fn: pointer) =
  let fnAddr = cast[int64](fn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Three slots into rdi/rsi/rcx, result discarded (void host call)
      pop rcx
      pop rsi
      pop rdi
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, fnAddr
      call rax
      mov rsp, rbx
      pop rbx
  else:
    let p0 = int(cast[uint64](fn) and 0xFFFF'u64)
    let p1 = int((cast[uint64](fn) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](fn) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](fn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      ldr x2, [sp], 16
      ldr x1, [sp], 16
      ldr x0, [sp], 16
      movz x16, p0
      movk x16, p1, lsl, 16
      movk x16, p2, lsl, 32
      movk x16, p3, lsl, 48
      blr x16

proc nbridge3*(a: var Assembler, fn: pointer) =
  let fnAddr = cast[int64](fn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Three slots into rdi/rsi/rcx, result pushed back
      pop rcx
      pop rsi
      pop rdi
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, fnAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
  else:
    let p0 = int(cast[uint64](fn) and 0xFFFF'u64)
    let p1 = int((cast[uint64](fn) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](fn) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](fn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      ldr x2, [sp], 16
      ldr x1, [sp], 16
      ldr x0, [sp], 16
      movz x16, p0
      movk x16, p1, lsl, 16
      movk x16, p2, lsl, 32
      movk x16, p3, lsl, 48
      blr x16
      str x0, [sp, -16], pre

proc nbridge4*(a: var Assembler, fn: pointer) =
  let fnAddr = cast[int64](fn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Four slots into rdi/rsi/rdx/rcx, result pushed back
      pop rcx
      pop rdx
      pop rsi
      pop rdi
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, fnAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
  else:
    let p0 = int(cast[uint64](fn) and 0xFFFF'u64)
    let p1 = int((cast[uint64](fn) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](fn) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](fn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      ldr x3, [sp], 16
      ldr x2, [sp], 16
      ldr x1, [sp], 16
      ldr x0, [sp], 16
      movz x16, p0
      movk x16, p1, lsl, 16
      movk x16, p2, lsl, 32
      movk x16, p3, lsl, 48
      blr x16
      str x0, [sp, -16], pre

proc ncallAlloc*(a: var Assembler, nArgs: int) =
  when defined(amd64):
    let bytes = nArgs * 8
    dynasm a:
      arch x64
      # Reserve room below the operands for the flatArgs array the bridge reads
      sub rsp, bytes
  else:
    # Round up to 16 bytes (Apple Silicon faults on misaligned
    # sp at blr, which nArgs*8 caused for odd arities).
    let bytes = ((nArgs * 8 + 15) div 16) * 16
    dynasm a:
      arch aarch64
      mov x9, bytes
      sub sp, sp, x9

proc ncallMoveOne*(a: var Assembler, srcDisp: int, dstDisp: int) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Shuffle one operand down into its flatArgs slot (deepest first)
      mov rax, [rsp + srcDisp]
      mov [rsp + dstDisp], rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp, srcDisp]
      str x9, [sp, dstDisp]

proc ncallPopSlot*(a: var Assembler, slot: int) =
  let disp = slot * 8
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop the top operand into a reserved frame slot below it
      pop rax
      mov [rsp + disp], rax
  else:
    dynasm a:
      arch aarch64
      ldr x9, [sp], 16
      str x9, [sp, disp]

proc ncallInvoke*(a: var Assembler, nArgs: int, procId: int,
    bridgeFn: pointer) =
  let bridgeAddr = cast[int64](bridgeFn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Bridge ABI: procId in edi, flatArgs base in rsi, argc in edx,
      # arg-types nil (untyped call: everything boxes as int or unpacks)
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      lea rsi, [rbx + 8]
      mov edx, nArgs
      `xor` ecx, ecx
      mov edi, procId
      movabs rax, bridgeAddr
      call rax
      mov rsp, rbx
      pop rbx
  else:
    let r0 = int(cast[uint64](bridgeFn) and 0xFFFF'u64)
    let r1 = int((cast[uint64](bridgeFn) shr 16) and 0xFFFF'u64)
    let r2 = int((cast[uint64](bridgeFn) shr 32) and 0xFFFF'u64)
    let r3 = int((cast[uint64](bridgeFn) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      # Same ABI through x0-x3: procId, flatArgs, argc, nil types.
      # x20 snapshots sp because blr needs the array base in x1.
      mov x20, sp
      mov x2, nArgs
      mov x3, 0
      mov x0, procId
      mov x1, x20
      movz x16, r0
      movk x16, r1, lsl, 16
      movk x16, r2, lsl, 32
      movk x16, r3, lsl, 48
      blr x16

proc ncallFinish*(a: var Assembler, dropBytes: int) =
  when defined(amd64):
    dynasm a:
      arch x64
      # Drop the flatArgs array plus the stale operand slots above it,
      # then push the bridge result sitting in rax
      add rsp, dropBytes
      push rax
  else:
    dynasm a:
      arch aarch64
      mov x9, dropBytes
      add sp, sp, x9
      str x0, [sp, -16], pre

proc ncallFinishVoid*(a: var Assembler, dropBytes: int) =
  ## Like `ncallFinish` but pushes nothing: for `CallD` to a `void` callee
  ## (e.g. `array.add`), where the interpreter leaves no result behind.
  ## Emitting the pushing variant here would leak one phantom slot per
  ## call and corrupt the native operand stack.
  when defined(amd64):
    dynasm a:
      arch x64
      # Same cleanup, but the bridge result in rax is simply dropped
      add rsp, dropBytes
  else:
    dynasm a:
      arch aarch64
      mov x9, dropBytes
      add sp, sp, x9

proc ncallSelf*(a: var Assembler, nArgs: int, selfAddr: int64) =
  ## selfAddr is the final JIT buffer address. When it is not known
  ## yet, pass 0 and patch the movabs afterwards (see Phase 3).
  when defined(amd64):
    dynasm a:
      arch x64
      # Direct self-call: rsp-relative frame plus arg count, no bridge.
      # Reuses the caller's operand area as the callee frame.
      mov rdi, rsp
      mov esi, nArgs
      movabs rax, selfAddr
      call rax
  else:
    let p0 = int(cast[uint64](selfAddr) and 0xFFFF'u64)
    let p1 = int((cast[uint64](selfAddr) shr 16) and 0xFFFF'u64)
    let p2 = int((cast[uint64](selfAddr) shr 32) and 0xFFFF'u64)
    let p3 = int((cast[uint64](selfAddr) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      mov x0, sp
      mov x1, nArgs
      movz x16, p0
      movk x16, p1, lsl, 16
      movk x16, p2, lsl, 32
      movk x16, p3, lsl, 48
      blr x16

when defined(amd64):
  proc ncallSelfHole*(a: var Assembler, nArgs: int): int =
    ## Emit a self-call with a zero address; returns the final-buffer
    ## offset of the 8-byte address field for `ncallSelfPatch`.
    ncallSelf(a, nArgs, 0)
    # movabs is 10 bytes and `call rax` follows it: the imm64 field
    # starts 10 bytes before the end.
    result = int(a.offset()) - 10
    # movabs rax is REX.W + B8 + imm64; assert the shape so a future
    # encoder change fails loudly instead of patching the wrong bytes.
    assert a.staging[result - 2] == 0x48'u8
    assert a.staging[result - 1] == 0xB8'u8

  proc ncallSelfPatch*(base: pointer, hole: int, selfAddr: pointer) =
    ## Write the self address into a hole recorded by `ncallSelfHole`.
    ## Applies to the final buffer; the caller owns the RW/RX transitions.
    let u = cast[uint64](selfAddr)
    let dst = cast[ptr UncheckedArray[byte]](cast[int](base) + hole)
    for i in 0 ..< 8:
      dst[i] = cast[byte]((u shr (i * 8)) and 0xFF'u64)
else:
  proc ncallSelfHole*(a: var Assembler, nArgs: int): int =
    ## Emit a self-call with a zero address; returns the final-buffer
    ## offset of the 16-byte movz/movk sequence for `ncallSelfPatch`.
    ncallSelf(a, nArgs, 0)
    # The movz/movk sequence is 16 bytes and `blr x16` follows it:
    # the sequence starts 20 bytes before the end.
    result = int(a.offset()) - 20
    # movz x16 followed by 3x movk x16; op halfwords are fixed.
    assert a.staging[result + 2] == 0x80'u8
    assert a.staging[result + 3] == 0xD2'u8
    for k in 1 ..< 4:
      assert a.staging[result + k * 4 + 2] == 0x80'u8
      assert a.staging[result + k * 4 + 3] == 0xF2'u8

  proc ncallSelfPatch*(base: pointer, hole: int, selfAddr: pointer) =
    ## Write the self address into a hole recorded by `ncallSelfHole`.
    let u = cast[uint64](selfAddr)
    let dst = cast[ptr UncheckedArray[byte]](cast[int](base) + hole)
    for k in 0 ..< 4:
      let chunk = (u shr (k * 16)) and 0xFFFF'u64
      dst[k * 4] = cast[byte](chunk and 0xFF'u64)
      dst[k * 4 + 1] = cast[byte]((chunk shr 8) and 0xFF'u64)

proc ngetI*(a: var Assembler, slowFn: pointer, kinds: int32, pc: int) =
  ## Indexed load `a[i]`: inline tagged-array/int-index/int-element fast
  ## path, slow bridge otherwise. Net stack effect -1. Labels are
  ## pc-suffixed (`pc` is unique per session). `kinds` packs the
  ## compiler-baked slot kinds (arr in bits 0-7, idx in bits 8-15) for
  ## the slow bridge, which reproduces `opcGetI` semantics exactly.
  let slowLbl = "giS" & $pc
  let doneLbl = "giD" & $pc
  let slowAddr = cast[int64](slowFn)
  let ringBase = jitRingBase()
  let epochBase = jitRingEpochBase()
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop index (r12) and container slot (rsi, kept for the slow path)
      pop r12
      pop rsi
      # Stage 1: split the tagged slot; epoch 0 means a raw int, not a ref
      mov rax, rsi
      `shr` rax, 32
      test eax, eax
      jz fwd(slowLbl)
      # Stage 2: resolve the ring slot and validate its epoch inline
      mov ecx, esi
      `and` ecx, jitRingMask
      `shl` rcx, 3
      movabs r8, ringBase
      add r8, rcx
      mov r9, [r8]
      `shr` rcx, 1
      movabs r8, epochBase
      add r8, rcx
      cmp [r8], eax
      jne fwd(slowLbl)
      # Stage 3: container must be a live non-foreign array object
      mov rax, [r9]
      cmp rax, tyArrayObject
      jne fwd(slowLbl)
      mov r8, [r9 + offValObj]
      test r8, r8
      jz fwd(slowLbl)
      cmp byte [r8], 0
      jne fwd(slowLbl)
      # Stage 4: bounds check against the inline length (no seq deref yet)
      mov r10, [r8 + offObjFields]
      cmp r12, 0
      jl fwd(slowLbl)
      cmp r12, r10
      jge fwd(slowLbl)
      # Stage 5: element address = block + idx * 16 + data offset;
      # fast path only serves int elements, rest goes to the bridge
      mov r8, [r8 + offObjFieldsPtr]
      test r8, r8
      jz fwd(slowLbl)
      mov r10, r12
      `shl` r10, 4
      add r10, r8
      add r10, blockDataOff
      mov rax, [r10]
      cmp rax, tyInt
      jne fwd(slowLbl)
      mov rax, [r10 + offVsInt]
      push rax
      jmp fwd(doneLbl)
    a.localLabel(slowLbl)
    dynasm a:
      arch x64
      # Slow path: full opcGetI semantics (incl. raised defects) via bridge
      mov rdi, rsi
      mov rsi, r12
      mov edx, kinds
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, slowAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
    a.localLabel(doneLbl)
  else:
    let rb0 = int(cast[uint64](ringBase) and 0xFFFF'u64)
    let rb1 = int((cast[uint64](ringBase) shr 16) and 0xFFFF'u64)
    let rb2 = int((cast[uint64](ringBase) shr 32) and 0xFFFF'u64)
    let rb3 = int((cast[uint64](ringBase) shr 48) and 0xFFFF'u64)
    let eb0 = int(cast[uint64](epochBase) and 0xFFFF'u64)
    let eb1 = int((cast[uint64](epochBase) shr 16) and 0xFFFF'u64)
    let eb2 = int((cast[uint64](epochBase) shr 32) and 0xFFFF'u64)
    let eb3 = int((cast[uint64](epochBase) shr 48) and 0xFFFF'u64)
    let sb0 = int(cast[uint64](slowAddr) and 0xFFFF'u64)
    let sb1 = int((cast[uint64](slowAddr) shr 16) and 0xFFFF'u64)
    let sb2 = int((cast[uint64](slowAddr) shr 32) and 0xFFFF'u64)
    let sb3 = int((cast[uint64](slowAddr) shr 48) and 0xFFFF'u64)
    let kk0 = int(kinds and 0xFFFF)
    dynasm a:
      arch aarch64
      # Same five stages as x64: pop idx (x9) and slot (x10), epoch check,
      # ring resolve, container checks, bounds, element load
      ldr x9, [sp], 16
      ldr x10, [sp], 16
      lsr x11, x10, 32
      cbz x11, fwd(slowLbl)
      `and` x12, x10, jitRingMask
      lsl x12, x12, 3
      movz x13, rb0
      movk x13, rb1, lsl, 16
      movk x13, rb2, lsl, 32
      movk x13, rb3, lsl, 48
      add x13, x13, x12
      ldr x14, [x13]
      lsr x12, x12, 1
      movz x13, eb0
      movk x13, eb1, lsl, 16
      movk x13, eb2, lsl, 32
      movk x13, eb3, lsl, 48
      add x13, x13, x12
      ldr w14, [x13]
      cmp w14, w11
      b.ne fwd(slowLbl)
      ldr x13, [x14]
      cmp x13, tyArrayObject
      b.ne fwd(slowLbl)
      ldr x13, [x14, offValObj]
      cbz x13, fwd(slowLbl)
      ldr w14, [x13]
      `and` w14, w14, 0xFF
      cbnz w14, fwd(slowLbl)
      ldr x14, [x13, offObjFields]
      cmp x9, 0
      b.lt fwd(slowLbl)
      cmp x9, x14
      b.ge fwd(slowLbl)
      ldr x15, [x13, offObjFieldsPtr]
      cbz x15, fwd(slowLbl)
      lsl x14, x9, 4
      add x14, x14, x15
      add x14, x14, blockDataOff
      ldr x11, [x14]
      cmp x11, tyInt
      b.ne fwd(slowLbl)
      ldr x11, [x14, offVsInt]
      str x11, [sp, -16], pre
      b fwd(doneLbl)
    a.localLabel(slowLbl)
    dynasm a:
      arch aarch64
      # Slow path: object slot in x0, index in x1, packed kinds in x2
      mov x0, x10
      mov x1, x9
      movz x2, kk0
      movz x16, sb0
      movk x16, sb1, lsl, 16
      movk x16, sb2, lsl, 32
      movk x16, sb3, lsl, 48
      blr x16
      str x0, [sp, -16], pre
    a.localLabel(doneLbl)

proc nsetI*(a: var Assembler, slowFn: pointer, kinds: int32, pc: int) =
  ## Indexed store `a[i] = v`: inline fast path when the compiler proves
  ## the stored value is int/bool (raw slot stored with the matching tag),
  ## slow bridge otherwise. Net stack effect -3 (pops val+idx+arr).
  ## Guard chain (container resolve, bounds) is identical to `ngetI`.
  let slowLbl = "siS" & $pc
  let doneLbl = "siD" & $pc
  let slowAddr = cast[int64](slowFn)
  let valKind = ((kinds shr 16) and 0xFF).int32
  let ringBase = jitRingBase()
  let epochBase = jitRingEpochBase()
  when defined(amd64):
    if valKind == tyInt.int32 or valKind == tyBool.int32:
      dynasm a:
        arch x64
        # Pop value (r11), index (r12), container (rsi); same resolve +
        # bounds chain as ngetI, then store tag + payload inline
        pop r11
        pop r12
        pop rsi
        mov rax, rsi
        `shr` rax, 32
        test eax, eax
        jz fwd(slowLbl)
        mov ecx, esi
        `and` ecx, jitRingMask
        `shl` rcx, 3
        movabs r8, ringBase
        add r8, rcx
        mov r9, [r8]
        `shr` rcx, 1
        movabs r8, epochBase
        add r8, rcx
        cmp [r8], eax
        jne fwd(slowLbl)
        mov rax, [r9]
        cmp rax, tyArrayObject
        jne fwd(slowLbl)
        mov r8, [r9 + offValObj]
        test r8, r8
        jz fwd(slowLbl)
        cmp byte [r8], 0
        jne fwd(slowLbl)
        mov r10, [r8 + offObjFields]
        cmp r12, 0
        jl fwd(slowLbl)
        cmp r12, r10
        jge fwd(slowLbl)
        mov r8, [r8 + offObjFieldsPtr]
        test r8, r8
        jz fwd(slowLbl)
        mov r10, r12
        `shl` r10, 4
        add r10, r8
        add r10, blockDataOff
        # Store the compiler-proven tag plus the raw payload, no boxing
        mov rax, valKind
        mov [r10], rax
        mov [r10 + offVsInt], r11
        jmp fwd(doneLbl)
      a.localLabel(slowLbl)
      dynasm a:
        arch x64
        # Slow path: container, index, value plus packed kinds to bridge
        mov rdi, rsi
        mov rsi, r12
        mov rdx, r11
        mov ecx, kinds
        push rbx
        mov rbx, rsp
        `and` rsp, -16
        movabs rax, slowAddr
        call rax
        mov rsp, rbx
        pop rbx
      a.localLabel(doneLbl)
    else:
      dynasm a:
        arch x64
        # Non-int/bool values always go through the bridge (needs rooting)
        pop r11
        pop r12
        pop rsi
        mov rdi, rsi
        mov rsi, r12
        mov rdx, r11
        mov ecx, kinds
        push rbx
        mov rbx, rsp
        `and` rsp, -16
        movabs rax, slowAddr
        call rax
        mov rsp, rbx
        pop rbx
  else:
    let rb0 = int(cast[uint64](ringBase) and 0xFFFF'u64)
    let rb1 = int((cast[uint64](ringBase) shr 16) and 0xFFFF'u64)
    let rb2 = int((cast[uint64](ringBase) shr 32) and 0xFFFF'u64)
    let rb3 = int((cast[uint64](ringBase) shr 48) and 0xFFFF'u64)
    let eb0 = int(cast[uint64](epochBase) and 0xFFFF'u64)
    let eb1 = int((cast[uint64](epochBase) shr 16) and 0xFFFF'u64)
    let eb2 = int((cast[uint64](epochBase) shr 32) and 0xFFFF'u64)
    let eb3 = int((cast[uint64](epochBase) shr 48) and 0xFFFF'u64)
    let sb0 = int(cast[uint64](slowAddr) and 0xFFFF'u64)
    let sb1 = int((cast[uint64](slowAddr) shr 16) and 0xFFFF'u64)
    let sb2 = int((cast[uint64](slowAddr) shr 32) and 0xFFFF'u64)
    let sb3 = int((cast[uint64](slowAddr) shr 48) and 0xFFFF'u64)
    let kk0 = int(kinds and 0xFFFF)
    let kk1 = int((kinds shr 16) and 0xFFFF)
    if valKind == tyInt.int32 or valKind == tyBool.int32:
      dynasm a:
        arch aarch64
        # Pops: value x9, index x10, container x11; then the ngetI-style
        # resolve + bounds chain, ending with an inline tag + payload store
        ldr x9, [sp], 16
        ldr x10, [sp], 16
        ldr x11, [sp], 16
        lsr x12, x11, 32
        cbz x12, fwd(slowLbl)
        `and` x13, x11, jitRingMask
        lsl x13, x13, 3
        movz x14, rb0
        movk x14, rb1, lsl, 16
        movk x14, rb2, lsl, 32
        movk x14, rb3, lsl, 48
        add x14, x14, x13
        ldr x15, [x14]
        lsr x13, x13, 1
        movz x14, eb0
        movk x14, eb1, lsl, 16
        movk x14, eb2, lsl, 32
        movk x14, eb3, lsl, 48
        add x14, x14, x13
        ldr w14, [x14]
        cmp w14, w12
        b.ne fwd(slowLbl)
        ldr x14, [x15]
        cmp x14, tyArrayObject
        b.ne fwd(slowLbl)
        ldr x14, [x15, offValObj]
        cbz x14, fwd(slowLbl)
        ldr w15, [x14]
        `and` w15, w15, 0xFF
        cbnz w15, fwd(slowLbl)
        ldr x15, [x14, offObjFields]
        cmp x10, 0
        b.lt fwd(slowLbl)
        cmp x10, x15
        b.ge fwd(slowLbl)
        ldr x14, [x14, offObjFieldsPtr]
        cbz x14, fwd(slowLbl)
        lsl x15, x10, 4
        add x15, x15, x14
        add x15, x15, blockDataOff
        mov x14, valKind
        str x14, [x15]
        str x9, [x15, offVsInt]
        b fwd(doneLbl)
      a.localLabel(slowLbl)
      dynasm a:
        arch aarch64
        # Slow path: container x0, index x1, value x2, kinds x3
        mov x0, x11
        mov x1, x10
        mov x2, x9
        movz x3, kk0
        movk x3, kk1, lsl, 16
        movz x16, sb0
        movk x16, sb1, lsl, 16
        movk x16, sb2, lsl, 32
        movk x16, sb3, lsl, 48
        blr x16
      a.localLabel(doneLbl)
    else:
      dynasm a:
        arch aarch64
        # Non-int/bool values always go through the bridge (needs rooting)
        ldr x9, [sp], 16
        ldr x10, [sp], 16
        ldr x11, [sp], 16
        mov x0, x11
        mov x1, x10
        mov x2, x9
        movz x3, kk0
        movk x3, kk1, lsl, 16
        movz x16, sb0
        movk x16, sb1, lsl, 16
        movk x16, sb2, lsl, 32
        movk x16, sb3, lsl, 48
        blr x16

proc ngetF*(a: var Assembler, slowFn: pointer, objKind: int32,
    fieldId: int, pc: int) =
  ## Field load `o.f`: inline tagged-object/int-element fast path, slow
  ## bridge otherwise. Net stack effect 0 (pops obj, pushes value). Same
  ## container layout as arrays; the guard requires `tyObjectStorage`
  ## while the bridge reproduces `opcGetF` exactly (arrays included).
  let slowLbl = "gfS" & $pc
  let doneLbl = "gfD" & $pc
  let slowAddr = cast[int64](slowFn)
  let ringBase = jitRingBase()
  let epochBase = jitRingEpochBase()
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop the container (kept in rsi for the slow path); no index slot
      # here, the field id is baked in as an immediate below
      pop rsi
      # Stage 1: split the tag; epoch 0 means a raw int, not a ref
      mov rax, rsi
      `shr` rax, 32
      test eax, eax
      jz fwd(slowLbl)
      # Stage 2: resolve the ring slot and validate its epoch inline
      mov ecx, esi
      `and` ecx, jitRingMask
      `shl` rcx, 3
      movabs r8, ringBase
      add r8, rcx
      mov r9, [r8]
      `shr` rcx, 1
      movabs r8, epochBase
      add r8, rcx
      cmp [r8], eax
      jne fwd(slowLbl)
      # Stage 3: field access needs an object (arrays go to the bridge,
      # which reproduces opcGetF on them exactly)
      mov rax, [r9]
      cmp rax, tyObjectStorage
      jne fwd(slowLbl)
      mov r8, [r9 + offValObj]
      test r8, r8
      jz fwd(slowLbl)
      cmp byte [r8], 0
      jne fwd(slowLbl)
      # Stage 4: field id against the inline length (always >= 0,
      # it comes from a uint8 operand)
      mov r10, [r8 + offObjFields]
      cmp r10, fieldId
      jle fwd(slowLbl)
      # Stage 5: static element offset (fieldId * 16 + data); fast path
      # only serves int fields
      mov r8, [r8 + offObjFieldsPtr]
      test r8, r8
      jz fwd(slowLbl)
      mov r10, fieldId
      `shl` r10, 4
      add r10, r8
      add r10, blockDataOff
      mov rax, [r10]
      cmp rax, tyInt
      jne fwd(slowLbl)
      mov rax, [r10 + offVsInt]
      push rax
      jmp fwd(doneLbl)
    a.localLabel(slowLbl)
    dynasm a:
      arch x64
      # Slow path: container, field id, and baked obj kind to the bridge
      mov rdi, rsi
      mov esi, fieldId
      mov edx, objKind
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, slowAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
    a.localLabel(doneLbl)
  else:
    let rb0 = int(cast[uint64](ringBase) and 0xFFFF'u64)
    let rb1 = int((cast[uint64](ringBase) shr 16) and 0xFFFF'u64)
    let rb2 = int((cast[uint64](ringBase) shr 32) and 0xFFFF'u64)
    let rb3 = int((cast[uint64](ringBase) shr 48) and 0xFFFF'u64)
    let eb0 = int(cast[uint64](epochBase) and 0xFFFF'u64)
    let eb1 = int((cast[uint64](epochBase) shr 16) and 0xFFFF'u64)
    let eb2 = int((cast[uint64](epochBase) shr 32) and 0xFFFF'u64)
    let eb3 = int((cast[uint64](epochBase) shr 48) and 0xFFFF'u64)
    let sb0 = int(cast[uint64](slowAddr) and 0xFFFF'u64)
    let sb1 = int((cast[uint64](slowAddr) shr 16) and 0xFFFF'u64)
    let sb2 = int((cast[uint64](slowAddr) shr 32) and 0xFFFF'u64)
    let sb3 = int((cast[uint64](slowAddr) shr 48) and 0xFFFF'u64)
    let elemOff = blockDataOff + fieldId * sizeVs
    dynasm a:
      arch aarch64
      # Same five stages as x64: container in x10, baked field id,
      # object guard, inline length check, static element offset
      ldr x10, [sp], 16
      lsr x11, x10, 32
      cbz x11, fwd(slowLbl)
      `and` x12, x10, jitRingMask
      lsl x12, x12, 3
      movz x13, rb0
      movk x13, rb1, lsl, 16
      movk x13, rb2, lsl, 32
      movk x13, rb3, lsl, 48
      add x13, x13, x12
      ldr x14, [x13]
      lsr x12, x12, 1
      movz x13, eb0
      movk x13, eb1, lsl, 16
      movk x13, eb2, lsl, 32
      movk x13, eb3, lsl, 48
      add x13, x13, x12
      ldr w14, [x13]
      cmp w14, w11
      b.ne fwd(slowLbl)
      ldr x13, [x14]
      cmp x13, tyObjectStorage
      b.ne fwd(slowLbl)
      ldr x13, [x14, offValObj]
      cbz x13, fwd(slowLbl)
      ldr w14, [x13]
      `and` w14, w14, 0xFF
      cbnz w14, fwd(slowLbl)
      ldr x14, [x13, offObjFields]
      cmp x14, fieldId
      b.le fwd(slowLbl)
      ldr x15, [x13, offObjFieldsPtr]
      cbz x15, fwd(slowLbl)
      # Static offset (fieldId * 16 + data) fits an add immediate
      add x14, x15, elemOff
      ldr x11, [x14]
      cmp x11, tyInt
      b.ne fwd(slowLbl)
      ldr x11, [x14, offVsInt]
      str x11, [sp, -16], pre
      b fwd(doneLbl)
    a.localLabel(slowLbl)
    dynasm a:
      arch aarch64
      # Slow path: container x0, field id x1, baked kind x2
      mov x0, x10
      mov x1, fieldId
      movz x2, objKind
      movz x16, sb0
      movk x16, sb1, lsl, 16
      movk x16, sb2, lsl, 32
      movk x16, sb3, lsl, 48
      blr x16
      str x0, [sp, -16], pre
    a.localLabel(doneLbl)

proc nsetF*(a: var Assembler, slowFn: pointer, kinds: int32,
    fieldId: int, pc: int) =
  ## Field store `o.f = v`: inline fast path when the compiler proves the
  ## stored value is int/bool, slow bridge otherwise. Net stack effect -2
  ## (pops val+obj). `kinds` packs obj/val slot kinds (bits 0-7/8-15).
  let slowLbl = "sfS" & $pc
  let doneLbl = "sfD" & $pc
  let slowAddr = cast[int64](slowFn)
  let valKind = ((kinds shr 8) and 0xFF).int32
  let ringBase = jitRingBase()
  let epochBase = jitRingEpochBase()
  when defined(amd64):
    if valKind == tyInt.int32 or valKind == tyBool.int32:
      dynasm a:
        arch x64
        # Pop value (r11) and container (rsi); same resolve + bounds
        # chain as ngetF, then store tag + payload inline, no boxing
        pop r11
        pop rsi
        mov rax, rsi
        `shr` rax, 32
        test eax, eax
        jz fwd(slowLbl)
        mov ecx, esi
        `and` ecx, jitRingMask
        `shl` rcx, 3
        movabs r8, ringBase
        add r8, rcx
        mov r9, [r8]
        `shr` rcx, 1
        movabs r8, epochBase
        add r8, rcx
        cmp [r8], eax
        jne fwd(slowLbl)
        mov rax, [r9]
        cmp rax, tyObjectStorage
        jne fwd(slowLbl)
        mov r8, [r9 + offValObj]
        test r8, r8
        jz fwd(slowLbl)
        cmp byte [r8], 0
        jne fwd(slowLbl)
        mov r10, [r8 + offObjFields]
        cmp r10, fieldId
        jle fwd(slowLbl)
        mov r8, [r8 + offObjFieldsPtr]
        test r8, r8
        jz fwd(slowLbl)
        mov r10, fieldId
        `shl` r10, 4
        add r10, r8
        add r10, blockDataOff
        mov rax, valKind
        mov [r10], rax
        mov [r10 + offVsInt], r11
        jmp fwd(doneLbl)
      a.localLabel(slowLbl)
      dynasm a:
        arch x64
        # Slow path: container, value, field id plus packed kinds
        mov rdi, rsi
        mov rsi, r11
        mov edx, fieldId
        mov ecx, kinds
        push rbx
        mov rbx, rsp
        `and` rsp, -16
        movabs rax, slowAddr
        call rax
        mov rsp, rbx
        pop rbx
      a.localLabel(doneLbl)
    else:
      dynasm a:
        arch x64
        # Non-int/bool values always go through the bridge (needs rooting)
        pop r11
        pop rsi
        mov rdi, rsi
        mov rsi, r11
        mov edx, fieldId
        mov ecx, kinds
        push rbx
        mov rbx, rsp
        `and` rsp, -16
        movabs rax, slowAddr
        call rax
        mov rsp, rbx
        pop rbx
  else:
    let rb0 = int(cast[uint64](ringBase) and 0xFFFF'u64)
    let rb1 = int((cast[uint64](ringBase) shr 16) and 0xFFFF'u64)
    let rb2 = int((cast[uint64](ringBase) shr 32) and 0xFFFF'u64)
    let rb3 = int((cast[uint64](ringBase) shr 48) and 0xFFFF'u64)
    let eb0 = int(cast[uint64](epochBase) and 0xFFFF'u64)
    let eb1 = int((cast[uint64](epochBase) shr 16) and 0xFFFF'u64)
    let eb2 = int((cast[uint64](epochBase) shr 32) and 0xFFFF'u64)
    let eb3 = int((cast[uint64](epochBase) shr 48) and 0xFFFF'u64)
    let sb0 = int(cast[uint64](slowAddr) and 0xFFFF'u64)
    let sb1 = int((cast[uint64](slowAddr) shr 16) and 0xFFFF'u64)
    let sb2 = int((cast[uint64](slowAddr) shr 32) and 0xFFFF'u64)
    let sb3 = int((cast[uint64](slowAddr) shr 48) and 0xFFFF'u64)
    let kk0 = int(kinds and 0xFFFF)
    let elemOffS = blockDataOff + fieldId * sizeVs
    if valKind == tyInt.int32 or valKind == tyBool.int32:
      dynasm a:
        arch aarch64
        # Pops: value x9, container x11; resolve + bounds, inline store
        ldr x9, [sp], 16
        ldr x11, [sp], 16
        lsr x12, x11, 32
        cbz x12, fwd(slowLbl)
        `and` x13, x11, jitRingMask
        lsl x13, x13, 3
        movz x14, rb0
        movk x14, rb1, lsl, 16
        movk x14, rb2, lsl, 32
        movk x14, rb3, lsl, 48
        add x14, x14, x13
        ldr x15, [x14]
        lsr x13, x13, 1
        movz x14, eb0
        movk x14, eb1, lsl, 16
        movk x14, eb2, lsl, 32
        movk x14, eb3, lsl, 48
        add x14, x14, x13
        ldr w14, [x14]
        cmp w14, w12
        b.ne fwd(slowLbl)
        ldr x14, [x15]
        cmp x14, tyObjectStorage
        b.ne fwd(slowLbl)
        ldr x14, [x15, offValObj]
        cbz x14, fwd(slowLbl)
        ldr w15, [x14]
        `and` w15, w15, 0xFF
        cbnz w15, fwd(slowLbl)
        ldr x15, [x14, offObjFields]
        cmp x15, fieldId
        b.le fwd(slowLbl)
        ldr x14, [x14, offObjFieldsPtr]
        cbz x14, fwd(slowLbl)
        # Static element offset again, then tag + payload store
        add x15, x14, elemOffS
        mov x14, valKind
        str x14, [x15]
        str x9, [x15, offVsInt]
        b fwd(doneLbl)
      a.localLabel(slowLbl)
      dynasm a:
        arch aarch64
        # Slow path: container x0, value x1, field id x2, kinds x3
        mov x0, x11
        mov x1, x9
        mov x2, fieldId
        movz x3, kk0
        movz x16, sb0
        movk x16, sb1, lsl, 16
        movk x16, sb2, lsl, 32
        movk x16, sb3, lsl, 48
        blr x16
      a.localLabel(doneLbl)
    else:
      dynasm a:
        arch aarch64
        # Non-int/bool values always go through the bridge (needs rooting)
        ldr x9, [sp], 16
        ldr x11, [sp], 16
        mov x0, x11
        mov x1, x9
        mov x2, fieldId
        movz x3, kk0
        movz x16, sb0
        movk x16, sb1, lsl, 16
        movk x16, sb2, lsl, 32
        movk x16, sb3, lsl, 48
        blr x16

proc ncallInvokeTyped*(a: var Assembler, nArgs: int, procId: int,
    bridgeFn: pointer, typesPtr: pointer) =
  ## Like `ncallInvoke` but passes a baked arg-kind array (`jitImmortalTypes`)
  ## so the bridge boxes raw slots with exact types (int/bool/float) instead
  ## of defaulting everything to `tyInt`. Nil `typesPtr` == `ncallInvoke`.
  let bridgeAddr = cast[int64](bridgeFn)
  let typesAddr = cast[int64](typesPtr)
  when defined(amd64):
    dynasm a:
      arch x64
      # Same shape as ncallInvoke, but rcx carries the kinds array
      # instead of nil so the bridge can box each slot exactly
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      lea rsi, [rbx + 8]
      mov edx, nArgs
      movabs rcx, typesAddr
      mov edi, procId
      movabs rax, bridgeAddr
      call rax
      mov rsp, rbx
      pop rbx
  else:
    let r0 = int(cast[uint64](bridgeFn) and 0xFFFF'u64)
    let r1 = int((cast[uint64](bridgeFn) shr 16) and 0xFFFF'u64)
    let r2 = int((cast[uint64](bridgeFn) shr 32) and 0xFFFF'u64)
    let r3 = int((cast[uint64](bridgeFn) shr 48) and 0xFFFF'u64)
    let t0 = int(cast[uint64](typesAddr) and 0xFFFF'u64)
    let t1 = int((cast[uint64](typesAddr) shr 16) and 0xFFFF'u64)
    let t2 = int((cast[uint64](typesAddr) shr 32) and 0xFFFF'u64)
    let t3 = int((cast[uint64](typesAddr) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      # Same triple as ncallInvoke, but x3 carries the kinds array
      mov x20, sp
      mov x2, nArgs
      movz x3, t0
      movk x3, t1, lsl, 16
      movk x3, t2, lsl, 32
      movk x3, t3, lsl, 48
      mov x0, procId
      mov x1, x20
      movz x16, r0
      movk x16, r1, lsl, 16
      movk x16, r2, lsl, 32
      movk x16, r3, lsl, 48
      blr x16

proc npushF*(a: var Assembler, bits: int64) =
  ## Push a float constant as raw bits (bit-cast doubles travel on the
  ## int64 native stack; arithmetic happens in float bridges or, later,
  ## native SSE). Net stack effect +1.
  when defined(amd64):
    dynasm a:
      arch x64
      # Any 64-bit pattern embeds directly, NaNs included
      movabs rax, bits
      push rax
  else:
    # NOTE: named fb* on purpose — b0..b3 are ARM FP registers and the
    # DSL would read them as such instead of our immediates.
    let fbu = cast[uint64](bits)
    let fb0 = int(fbu and 0xFFFF'u64)
    let fb1 = int((fbu shr 16) and 0xFFFF'u64)
    let fb2 = int((fbu shr 32) and 0xFFFF'u64)
    let fb3 = int((fbu shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      # Same four-halfword build as any other baked 64-bit address
      movz x9, fb0
      movk x9, fb1, lsl, 16
      movk x9, fb2, lsl, 32
      movk x9, fb3, lsl, 48
      str x9, [sp, -16], pre

proc nfloatBinop*(a: var Assembler, fn: pointer, kinds: int32) =
  ## Float binary op through a bridge (`jitFloatAdd/Sub/Mul/Div/Eq/Less/
  ## Greater`): pops b, a; calls fn(a, b, kinds); pushes the bit-cast
  ## result (0/1 for comparisons). Net stack effect -1. `kinds` packs the
  ## compiler-baked operand kinds (a in bits 0-7, b in bits 8-15) so
  ## mixed int/float operands convert exactly like the interpreter.
  let fnAddr = cast[int64](fn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Pop b (rsi) then a (rdi) for the (a, b, kinds) bridge; the bit-cast
      # result comes back in rax and is pushed
      pop rsi
      pop rdi
      mov edx, kinds
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, fnAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
  else:
    let f0 = int(cast[uint64](fnAddr) and 0xFFFF'u64)
    let f1 = int((cast[uint64](fnAddr) shr 16) and 0xFFFF'u64)
    let f2 = int((cast[uint64](fnAddr) shr 32) and 0xFFFF'u64)
    let f3 = int((cast[uint64](fnAddr) shr 48) and 0xFFFF'u64)
    let kk0 = int(kinds and 0xFFFF)
    dynasm a:
      arch aarch64
      # Same triple through x0/x1/x2: a, b, then packed kinds
      ldr x1, [sp], 16
      ldr x0, [sp], 16
      movz x2, kk0
      movz x16, f0
      movk x16, f1, lsl, 16
      movk x16, f2, lsl, 32
      movk x16, f3, lsl, 48
      blr x16
      str x0, [sp, -16], pre

proc nfloatNeg*(a: var Assembler, fn: pointer, kind: int32) =
  ## Float negation through `jitFloatNeg`: pops a; calls fn(a, kind);
  ## pushes the bit-cast result. Net stack effect 0.
  let fnAddr = cast[int64](fn)
  when defined(amd64):
    dynasm a:
      arch x64
      # Unary variant: popped slot in rdi, baked kind in esi
      pop rdi
      mov esi, kind
      push rbx
      mov rbx, rsp
      `and` rsp, -16
      movabs rax, fnAddr
      call rax
      mov rsp, rbx
      pop rbx
      push rax
  else:
    let f0 = int(cast[uint64](fnAddr) and 0xFFFF'u64)
    let f1 = int((cast[uint64](fnAddr) shr 16) and 0xFFFF'u64)
    let f2 = int((cast[uint64](fnAddr) shr 32) and 0xFFFF'u64)
    let f3 = int((cast[uint64](fnAddr) shr 48) and 0xFFFF'u64)
    dynasm a:
      arch aarch64
      # Same pair through x0/x1: slot, then kind
      ldr x0, [sp], 16
      mov x1, kind
      movz x16, f0
      movk x16, f1, lsl, 16
      movk x16, f2, lsl, 32
      movk x16, f3, lsl, 48
      blr x16
      str x0, [sp, -16], pre
