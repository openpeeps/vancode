/*
** This file has been pre-processed with DynASM.
** https://luajit.org/dynasm.html
** DynASM version 1.5.0, DynASM x64 version 1.5.0
** DO NOT EDIT! The original file is in "vancode_jit.dasc".
*/

#line 1 "vancode_jit.dasc"
//|.arch x64
#if DASM_VERSION != 10500
#error "Version mismatch between DynASM and included encoding engine"
#endif
#line 2 "vancode_jit.dasc"

//|.section code
#define DASM_SECTION_CODE	0
#define DASM_MAXSECTION		1
#line 4 "vancode_jit.dasc"

//|.actionlist vancode_actions
static const unsigned char vancode_actions[523] = {
  254,0,85,72,137,229,83,65,84,72,137,252,251,255,252,255,179,233,255,72,199,
  192,237,80,255,106,1,255,106,0,255,88,72,137,131,233,255,72,252,255,131,233,
  255,72,252,255,139,233,255,88,65,92,76,1,224,80,255,65,92,88,76,41,224,80,
  255,88,65,92,73,15,175,196,80,255,65,92,88,72,153,73,252,247,252,252,80,255,
  65,92,88,72,153,73,252,247,252,252,82,255,88,72,252,247,216,80,255,88,65,
  92,76,57,224,15,148,208,72,15,182,192,80,255,88,65,92,73,57,196,15,156,208,
  72,15,182,192,80,255,88,65,92,73,57,196,15,159,208,72,15,182,192,80,255,88,
  72,133,192,15,148,208,72,15,182,192,80,255,72,129,196,239,255,252,233,245,
  255,88,72,133,192,15,132,245,80,255,88,72,133,192,15,133,245,80,255,249,255,
  88,65,92,91,93,195,255,49,192,65,92,91,93,195,255,65,92,91,93,49,192,195,
  255,72,139,7,72,133,192,15,132,244,247,72,131,252,248,1,15,142,244,247,69,
  49,192,65,185,1,0,0,0,72,137,193,72,252,255,201,248,2,77,137,202,77,1,193,
  77,137,208,72,252,255,201,15,133,244,2,76,137,200,195,248,1,195,255,83,72,
  137,227,72,131,228,252,240,72,191,237,237,72,184,237,237,252,255,208,72,137,
  220,91,80,255,94,72,191,237,237,186,2,0,0,0,72,184,237,237,252,255,208,255,
  94,83,72,137,227,72,131,228,252,240,72,191,237,237,72,184,237,237,252,255,
  208,72,137,220,91,255,94,95,83,72,137,227,72,131,228,252,240,72,184,237,237,
  252,255,208,72,137,220,91,80,255,89,94,95,83,72,137,227,72,131,228,252,240,
  72,184,237,237,252,255,208,72,137,220,91,255,89,94,95,83,72,137,227,72,131,
  228,252,240,72,184,237,237,252,255,208,72,137,220,91,80,255,89,90,94,95,83,
  72,137,227,72,131,228,252,240,72,184,237,237,252,255,208,72,137,220,91,80,
  255,72,129,252,236,239,255,72,139,132,253,36,233,72,137,132,253,36,233,255,
  88,72,137,132,253,36,233,255,83,72,137,227,72,131,228,252,240,72,141,115,
  8,186,237,49,201,191,237,72,184,237,237,252,255,208,72,137,220,91,255,72,
  129,196,239,80,255,72,137,231,190,237,72,184,237,237,252,255,208,255
};

#line 6 "vancode_jit.dasc"

//|.globals lbl_
enum {
  lbl__MAX
};
#line 8 "vancode_jit.dasc"

// ---------------------------------------------------------------
// Emitter functions. Each function emits one instruction sequence.
// Called from Nim code during JIT compilation.
// Register usage (x64 System V ABI):
//   rdi = arg0: flatArgs (ptr int64)
//   rsi = arg1: argc (int)
//   rax = return value
//   rbx = args pointer (saved from rdi)
//   r12 = scratch
//   Native stack = operand stack (push = pushI, pop = popI)
// ---------------------------------------------------------------

void vancode_prologue(dasm_State** Dst) {
  //|.code
  dasm_put(Dst, 0);
#line 23 "vancode_jit.dasc"
  //| push rbp
  //| mov rbp, rsp
  //| push rbx
  //| push r12
  //| mov rbx, rdi
  dasm_put(Dst, 2);
#line 28 "vancode_jit.dasc"
}

void vancode_load_param(dasm_State** Dst, int slot) {
  //| push qword [rbx + slot*8]
  dasm_put(Dst, 14, slot*8);
#line 32 "vancode_jit.dasc"
}

void vancode_push_i(dasm_State** Dst, int value) {
  //| mov rax, value
  //| push rax
  dasm_put(Dst, 19, value);
#line 37 "vancode_jit.dasc"
}

void vancode_push_true(dasm_State** Dst) {
  //| push 1
  dasm_put(Dst, 25);
#line 41 "vancode_jit.dasc"
}

void vancode_push_false(dasm_State** Dst) {
  //| push 0
  dasm_put(Dst, 28);
#line 45 "vancode_jit.dasc"
}

void vancode_push_nil(dasm_State** Dst) {
  //| push 0
  dasm_put(Dst, 28);
#line 49 "vancode_jit.dasc"
}

void vancode_push_l(dasm_State** Dst, int slot) {
  //| push qword [rbx + slot*8]
  dasm_put(Dst, 14, slot*8);
#line 53 "vancode_jit.dasc"
}

void vancode_pop_l(dasm_State** Dst, int slot) {
  //| pop rax
  //| mov [rbx + slot*8], rax
  dasm_put(Dst, 31, slot*8);
#line 58 "vancode_jit.dasc"
}

void vancode_inc_l(dasm_State** Dst, int slot) {
  //| inc qword [rbx + slot*8]
  dasm_put(Dst, 37, slot*8);
#line 62 "vancode_jit.dasc"
}

void vancode_dec_l(dasm_State** Dst, int slot) {
  //| dec qword [rbx + slot*8]
  dasm_put(Dst, 43, slot*8);
#line 66 "vancode_jit.dasc"
}

void vancode_add_i(dasm_State** Dst) {
  //| pop rax
  //| pop r12
  //| add rax, r12
  //| push rax
  dasm_put(Dst, 49);
#line 73 "vancode_jit.dasc"
}

void vancode_sub_i(dasm_State** Dst) {
  //| pop r12
  //| pop rax
  //| sub rax, r12
  //| push rax
  dasm_put(Dst, 57);
#line 80 "vancode_jit.dasc"
}

void vancode_mul_i(dasm_State** Dst) {
  //| pop rax
  //| pop r12
  //| imul rax, r12
  //| push rax
  dasm_put(Dst, 65);
#line 87 "vancode_jit.dasc"
}

void vancode_div_i(dasm_State** Dst) {
  //| pop r12
  //| pop rax
  //| cqo
  //| idiv r12
  //| push rax
  dasm_put(Dst, 74);
#line 95 "vancode_jit.dasc"
}

// NOTE: mirrors div_i — idiv by zero raises SIGFPE (native crash), while
// the interpreter arm raises a catchable DivByZeroDefect. Same pre-existing
// asymmetry as div_i; a zero divisor in JITed code is fatal either way.
void vancode_mod_i(dasm_State** Dst) {
  //| pop r12
  //| pop rax
  //| cqo
  //| idiv r12
  //| push rdx
  dasm_put(Dst, 86);
#line 106 "vancode_jit.dasc"
}

void vancode_neg_i(dasm_State** Dst) {
  //| pop rax
  //| neg rax
  //| push rax
  dasm_put(Dst, 98);
#line 112 "vancode_jit.dasc"
}

void vancode_eq_i(dasm_State** Dst) {
  //| pop rax
  //| pop r12
  //| cmp rax, r12
  //| sete al
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 105);
#line 121 "vancode_jit.dasc"
}

void vancode_less_i(dasm_State** Dst) {
  //| pop rax        // b (second push)
  //| pop r12        // a (first push)
  //| cmp r12, rax   // a - b
  //| setl al        // 1 if a < b
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 120);
#line 130 "vancode_jit.dasc"
}

void vancode_greater_i(dasm_State** Dst) {
  //| pop rax        // b (second push)
  //| pop r12        // a (first push)
  //| cmp r12, rax   // a - b
  //| setg al        // 1 if a > b
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 135);
#line 139 "vancode_jit.dasc"
}

void vancode_inv_b(dasm_State** Dst) {
  //| pop rax
  //| test rax, rax
  //| sete al
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 150);
#line 147 "vancode_jit.dasc"
}

void vancode_discard(dasm_State** Dst, int n) {
  //| add rsp, n*8
  dasm_put(Dst, 163, n*8);
#line 151 "vancode_jit.dasc"
}

void vancode_jump_fwd(dasm_State** Dst, int label) {
  //| jmp =>label
  dasm_put(Dst, 168, label);
#line 155 "vancode_jit.dasc"
}

void vancode_jump_back(dasm_State** Dst, int label) {
  //| jmp =>label
  dasm_put(Dst, 168, label);
#line 159 "vancode_jit.dasc"
}

void vancode_jump_fwd_f(dasm_State** Dst, int label) {
  //| pop rax
  //| test rax, rax
  //| jz =>label      // if false (condition failed), jump to target (bool consumed)
  //| push rax        // if true, put bool back for discard
  dasm_put(Dst, 172, label);
#line 166 "vancode_jit.dasc"
}

void vancode_jump_fwd_t(dasm_State** Dst, int label) {
  //| pop rax
  //| test rax, rax
  //| jnz =>label     // if true, jump to target (bool consumed)
  //| push rax        // if false, put bool back for discard
  dasm_put(Dst, 181, label);
#line 173 "vancode_jit.dasc"
}

void vancode_define_label(dasm_State** Dst, int label) {
  //|=>label:
  dasm_put(Dst, 190, label);
#line 177 "vancode_jit.dasc"
}

void vancode_return_val(dasm_State** Dst) {
  //| pop rax
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 192);
#line 185 "vancode_jit.dasc"
}

void vancode_return_void(dasm_State** Dst) {
  //| xor eax, eax
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 199);
#line 193 "vancode_jit.dasc"
}

// guard_false/guard_true are no longer used — use jump_fwd_f/jump_fwd_t instead

void vancode_trace_exit(dasm_State** Dst) {
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| xor eax, eax
  //| ret
  dasm_put(Dst, 207);
#line 203 "vancode_jit.dasc"
}

// Fib iterative: compute fib(n) where n = [locals_ptr], result in rax
// Uses same calling convention as trace fn: rdi = flatLocals ptr, rsi = count
void vancode_fib(dasm_State** Dst) {
  //|.code
  dasm_put(Dst, 0);
#line 209 "vancode_jit.dasc"
  //| mov rax, [rdi]     // rax = n (read from flatLocals[0])
  //| test rax, rax
  //| jz >1              // if n == 0, return 0
  //| cmp rax, 1
  //| jle >1             // if n <= 1, return n
  //| xor r8d, r8d       // fib_n_2 = 0 (F(n-2))
  //| mov r9d, 1         // fib_n_1 = 1 (F(n-1))
  //| mov rcx, rax       // counter = n
  //| dec rcx            // adjust counter
  //|2:
  //| mov r10, r9
  //| add r9, r8         // fib_n_1 = fib_n_1 + fib_n_2
  //| mov r8, r10        // fib_n_2 = old fib_n_1
  //| dec rcx
  //| jnz <2
  //| mov rax, r9        // result
  //| ret
  //|1:
  //| ret                // n is already in rax (0 or 1)
  dasm_put(Dst, 215);
#line 228 "vancode_jit.dasc"
}

void vancode_halt(dasm_State** Dst) {
  //| xor eax, eax
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 199);
#line 236 "vancode_jit.dasc"
}

// PushG: push global value by name string pointer
//
// SysV requires rsp%16==0 before `call`, but the operand stack has
// arbitrary parity (one push = 8 bytes). Align dynamically around every
// outbound call: rbx is callee-saved, pushed/popped symmetrically so the
// operand stack itself is untouched.
void vancode_pushg(dasm_State** Dst, unsigned long long namePtr, unsigned long long bridgeFn) {
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| mov64 rdi, namePtr
  //| mov64 rax, bridgeFn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  //| push rax
  dasm_put(Dst, 277, (unsigned int)(namePtr), (unsigned int)((namePtr)>>32), (unsigned int)(bridgeFn), (unsigned int)((bridgeFn)>>32));
#line 254 "vancode_jit.dasc"
}

// PopG: pop int64 val from stack, store to global by name
void vancode_popg(dasm_State** Dst, unsigned long long namePtr, unsigned long long bridgeFn) {
  //| pop rsi        // val (from operand stack)
  //| mov64 rdi, namePtr
  //| mov edx, 2     // typeId = tyInt
  //| mov64 rax, bridgeFn
  //| call rax
  dasm_put(Dst, 303, (unsigned int)(namePtr), (unsigned int)((namePtr)>>32), (unsigned int)(bridgeFn), (unsigned int)((bridgeFn)>>32));
#line 263 "vancode_jit.dasc"
}

// PopHost: pop one native-stack slot and hand it to a host bridge as
// (namePtr, slot). Unlike popg the slot keeps its convention (raw int or
// tagged ring index) for the host to unpack; nothing is pushed back.
void vancode_pop_host(dasm_State** Dst, unsigned long long namePtr, unsigned long long bridgeFn) {
  //| pop rsi        // slot (from operand stack)
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| mov64 rdi, namePtr
  //| mov64 rax, bridgeFn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  dasm_put(Dst, 321, (unsigned int)(namePtr), (unsigned int)((namePtr)>>32), (unsigned int)(bridgeFn), (unsigned int)((bridgeFn)>>32));
#line 278 "vancode_jit.dasc"
}

void vancode_bridge_2(dasm_State** Dst, unsigned long long fn) {
  //| pop rsi
  //| pop rdi
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| mov64 rax, fn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  //| push rax
  dasm_put(Dst, 347, (unsigned int)(fn), (unsigned int)((fn)>>32));
#line 291 "vancode_jit.dasc"
}

void vancode_bridge_3_void(dasm_State** Dst, unsigned long long fn) {
  //| pop rcx
  //| pop rsi
  //| pop rdi
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| mov64 rax, fn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  dasm_put(Dst, 371, (unsigned int)(fn), (unsigned int)((fn)>>32));
#line 304 "vancode_jit.dasc"
}

void vancode_bridge_3(dasm_State** Dst, unsigned long long fn) {
  //| pop rcx
  //| pop rsi
  //| pop rdi
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| mov64 rax, fn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  //| push rax
  dasm_put(Dst, 395, (unsigned int)(fn), (unsigned int)((fn)>>32));
#line 318 "vancode_jit.dasc"
}

void vancode_bridge_4(dasm_State** Dst, unsigned long long fn) {
  //| pop rcx
  //| pop rdx
  //| pop rsi
  //| pop rdi
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| mov64 rax, fn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  //| push rax
  dasm_put(Dst, 420, (unsigned int)(fn), (unsigned int)((fn)>>32));
#line 333 "vancode_jit.dasc"
}

// Reserve a flatArgs array of nArgs int64s below the N stack operands:
// operands live at [rsp, rsp+nArgs*8); the array at [rsp-nArgs*8, rsp).
void vancode_call_alloc(dasm_State** Dst, int nArgs) {
  //| sub rsp, nArgs*8
  dasm_put(Dst, 446, nArgs*8);
#line 339 "vancode_jit.dasc"
}

// Move one operand down into the reserved array: operands shifted to
// [rsp+nArgs*8, rsp+2nArgs*8) by call_alloc, array at [rsp, rsp+nArgs*8).
// Unrolled per operand from the Nim side (no labels, safe for any arity).
void vancode_call_move_one(dasm_State** Dst, int srcDisp, int dstDisp) {
  //| mov rax, [rsp + srcDisp]
  //| mov [rsp + dstDisp], rax
  dasm_put(Dst, 452, srcDisp, dstDisp);
#line 347 "vancode_jit.dasc"
}

// Pop rax, store at [rsp + slot*8] (legacy; superseded by call_move_one)
void vancode_call_pop_slot(dasm_State** Dst, int slot) {
  //| pop rax
  //| mov [rsp + slot*8], rax
  dasm_put(Dst, 465, slot*8);
#line 353 "vancode_jit.dasc"
}

// Invoke bridge: bridge(procId, flatArgs, argc, argTypes)
// x64 System V: rdi=procId, rsi=flatArgs(rsp), edx=argc, rcx=null
void vancode_call_invoke(dasm_State** Dst, int nArgs, int procId, unsigned long long bridgeFn) {
  //| push rbx
  //| mov rbx, rsp
  //| and rsp, -16
  //| lea rsi, [rbx+8]   // flatArgs base = pre-push rsp (rbx is 8 low)
  //| mov edx, nArgs
  //| xor ecx, ecx
  //| mov edi, procId
  //| mov64 rax, bridgeFn
  //| call rax
  //| mov rsp, rbx
  //| pop rbx
  dasm_put(Dst, 473, nArgs, procId, (unsigned int)(bridgeFn), (unsigned int)((bridgeFn)>>32));
#line 369 "vancode_jit.dasc"
}

// Drop the flatArgs array plus the (stale) operand slots above it
// (dropBytes = 2*nArgs*8, passed from the Nim side) and push the result.
void vancode_call_finish(dasm_State** Dst, int dropBytes) {
  //| add rsp, dropBytes
  //| push rax
  dasm_put(Dst, 504, dropBytes);
#line 376 "vancode_jit.dasc"
}

// Self-recursion: call the current function directly.
// The flatArgs array of nArgs int64s is live at [rsp, rsp+nArgs*8),
// prepared by call_alloc + call_move_one; selfAddr is the JIT buffer.
// Post-call cleanup is done by call_finish (drops array + operands).
void vancode_call_self(dasm_State** Dst, int nArgs, unsigned long long selfAddr) {
  //| mov rdi, rsp
  //| mov esi, nArgs
  //| mov64 rax, selfAddr
  //| call rax
  dasm_put(Dst, 510, nArgs, (unsigned int)(selfAddr), (unsigned int)((selfAddr)>>32));
#line 387 "vancode_jit.dasc"
}
