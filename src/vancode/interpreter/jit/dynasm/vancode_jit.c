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
static const unsigned char vancode_actions[430] = {
  254,0,85,72,137,229,83,65,84,72,137,252,251,255,252,255,179,233,255,72,199,
  192,237,80,255,106,1,255,106,0,255,88,72,137,131,233,255,72,252,255,131,233,
  255,72,252,255,139,233,255,88,65,92,76,1,224,80,255,65,92,88,76,41,224,80,
  255,88,65,92,73,15,175,196,80,255,65,92,88,72,153,73,252,247,252,252,80,255,
  88,72,252,247,216,80,255,88,65,92,76,57,224,15,148,208,72,15,182,192,80,255,
  88,65,92,73,57,196,15,156,208,72,15,182,192,80,255,88,65,92,73,57,196,15,
  159,208,72,15,182,192,80,255,88,72,133,192,15,148,208,72,15,182,192,80,255,
  72,129,196,239,255,252,233,245,255,88,72,133,192,15,132,245,80,255,88,72,
  133,192,15,133,245,80,255,249,255,88,65,92,91,93,195,255,49,192,65,92,91,
  93,195,255,65,92,91,93,49,192,195,255,72,139,7,72,133,192,15,132,244,247,
  72,131,252,248,1,15,142,244,247,69,49,192,65,185,1,0,0,0,72,137,193,72,252,
  255,201,248,2,77,137,202,77,1,193,77,137,208,72,252,255,201,15,133,244,2,
  76,137,200,195,248,1,195,255,72,199,199,237,72,199,192,237,252,255,208,80,
  255,94,72,199,199,237,186,2,0,0,0,72,199,192,237,252,255,208,255,94,95,72,
  199,192,237,252,255,208,80,255,89,94,95,72,199,192,237,252,255,208,255,89,
  94,95,72,199,192,237,252,255,208,80,255,89,90,94,95,72,199,192,237,252,255,
  208,80,255,72,129,252,236,239,255,88,72,137,132,253,36,233,255,72,137,230,
  69,49,192,185,237,191,237,72,199,192,237,252,255,208,255,72,129,196,239,80,
  255,72,129,252,236,239,185,237,133,201,15,132,244,248,248,1,88,72,137,132,
  253,204,233,252,255,201,15,133,244,1,248,2,72,137,231,190,237,72,199,192,
  237,252,255,208,72,129,196,239,80,255
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

void vancode_neg_i(dasm_State** Dst) {
  //| pop rax
  //| neg rax
  //| push rax
  dasm_put(Dst, 86);
#line 101 "vancode_jit.dasc"
}

void vancode_eq_i(dasm_State** Dst) {
  //| pop rax
  //| pop r12
  //| cmp rax, r12
  //| sete al
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 93);
#line 110 "vancode_jit.dasc"
}

void vancode_less_i(dasm_State** Dst) {
  //| pop rax        // b (second push)
  //| pop r12        // a (first push)
  //| cmp r12, rax   // a - b
  //| setl al        // 1 if a < b
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 108);
#line 119 "vancode_jit.dasc"
}

void vancode_greater_i(dasm_State** Dst) {
  //| pop rax        // b (second push)
  //| pop r12        // a (first push)
  //| cmp r12, rax   // a - b
  //| setg al        // 1 if a > b
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 123);
#line 128 "vancode_jit.dasc"
}

void vancode_inv_b(dasm_State** Dst) {
  //| pop rax
  //| test rax, rax
  //| sete al
  //| movzx rax, al
  //| push rax
  dasm_put(Dst, 138);
#line 136 "vancode_jit.dasc"
}

void vancode_discard(dasm_State** Dst, int n) {
  //| add rsp, n*8
  dasm_put(Dst, 151, n*8);
#line 140 "vancode_jit.dasc"
}

void vancode_jump_fwd(dasm_State** Dst, int label) {
  //| jmp =>label
  dasm_put(Dst, 156, label);
#line 144 "vancode_jit.dasc"
}

void vancode_jump_back(dasm_State** Dst, int label) {
  //| jmp =>label
  dasm_put(Dst, 156, label);
#line 148 "vancode_jit.dasc"
}

void vancode_jump_fwd_f(dasm_State** Dst, int label) {
  //| pop rax
  //| test rax, rax
  //| jz =>label      // if false (condition failed), jump to target (bool consumed)
  //| push rax        // if true, put bool back for discard
  dasm_put(Dst, 160, label);
#line 155 "vancode_jit.dasc"
}

void vancode_jump_fwd_t(dasm_State** Dst, int label) {
  //| pop rax
  //| test rax, rax
  //| jnz =>label     // if true, jump to target (bool consumed)
  //| push rax        // if false, put bool back for discard
  dasm_put(Dst, 169, label);
#line 162 "vancode_jit.dasc"
}

void vancode_define_label(dasm_State** Dst, int label) {
  //|=>label:
  dasm_put(Dst, 178, label);
#line 166 "vancode_jit.dasc"
}

void vancode_return_val(dasm_State** Dst) {
  //| pop rax
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 180);
#line 174 "vancode_jit.dasc"
}

void vancode_return_void(dasm_State** Dst) {
  //| xor eax, eax
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 187);
#line 182 "vancode_jit.dasc"
}

// guard_false/guard_true are no longer used — use jump_fwd_f/jump_fwd_t instead

void vancode_trace_exit(dasm_State** Dst) {
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| xor eax, eax
  //| ret
  dasm_put(Dst, 195);
#line 192 "vancode_jit.dasc"
}

// Fib iterative: compute fib(n) where n = [locals_ptr], result in rax
// Uses same calling convention as trace fn: rdi = flatLocals ptr, rsi = count
void vancode_fib(dasm_State** Dst) {
  //|.code
  dasm_put(Dst, 0);
#line 198 "vancode_jit.dasc"
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
  dasm_put(Dst, 203);
#line 217 "vancode_jit.dasc"
}

void vancode_halt(dasm_State** Dst) {
  //| xor eax, eax
  //| pop r12
  //| pop rbx
  //| pop rbp
  //| ret
  dasm_put(Dst, 187);
#line 225 "vancode_jit.dasc"
}

// PushG: push global value by name string pointer
void vancode_pushg(dasm_State** Dst, void* namePtr, void* bridgeFn) {
  //| mov rdi, namePtr
  //| mov rax, bridgeFn
  //| call rax
  //| push rax
  dasm_put(Dst, 265, namePtr, bridgeFn);
#line 233 "vancode_jit.dasc"
}

// PopG: pop int64 val from stack, store to global by name
void vancode_popg(dasm_State** Dst, void* namePtr, void* bridgeFn) {
  //| pop rsi        // val (from operand stack)
  //| mov rdi, namePtr
  //| mov edx, 2     // typeId = tyInt
  //| mov rax, bridgeFn
  //| call rax
  dasm_put(Dst, 278, namePtr, bridgeFn);
#line 242 "vancode_jit.dasc"
}

void vancode_bridge_2(dasm_State** Dst, void* fn) {
  //| pop rsi
  //| pop rdi
  //| mov rax, fn
  //| call rax
  //| push rax
  dasm_put(Dst, 296, fn);
#line 250 "vancode_jit.dasc"
}

void vancode_bridge_3_void(dasm_State** Dst, void* fn) {
  //| pop rcx
  //| pop rsi
  //| pop rdi
  //| mov rax, fn
  //| call rax
  dasm_put(Dst, 307, fn);
#line 258 "vancode_jit.dasc"
}

void vancode_bridge_3(dasm_State** Dst, void* fn) {
  //| pop rcx
  //| pop rsi
  //| pop rdi
  //| mov rax, fn
  //| call rax
  //| push rax
  dasm_put(Dst, 318, fn);
#line 267 "vancode_jit.dasc"
}

void vancode_bridge_4(dasm_State** Dst, void* fn) {
  //| pop rcx
  //| pop rdx
  //| pop rsi
  //| pop rdi
  //| mov rax, fn
  //| call rax
  //| push rax
  dasm_put(Dst, 330, fn);
#line 277 "vancode_jit.dasc"
}

// Allocate flatArgs array on stack: sub rsp, nArgs*8
void vancode_call_alloc(dasm_State** Dst, int nArgs) {
  //| sub rsp, nArgs*8
  dasm_put(Dst, 343, nArgs*8);
#line 282 "vancode_jit.dasc"
}

// Pop rax, store at [rsp + slot*8] (for building flatArgs)
void vancode_call_pop_slot(dasm_State** Dst, int slot) {
  //| pop rax
  //| mov [rsp + slot*8], rax
  dasm_put(Dst, 349, slot*8);
#line 288 "vancode_jit.dasc"
}

// Invoke bridge: jitCallProcBridgeFlat(procId, flatArgs, nArgs, null)
// rdi=procId, rsi=flatArgs(rsp), rcx=nArgs, r8=null
void vancode_call_invoke(dasm_State** Dst, int nArgs, int procId, void* bridgeFn) {
  //| mov rsi, rsp
  //| xor r8d, r8d
  //| mov ecx, nArgs
  //| mov edi, procId
  //| mov rax, bridgeFn
  //| call rax
  dasm_put(Dst, 357, nArgs, procId, bridgeFn);
#line 299 "vancode_jit.dasc"
}

// Cleanup flatArgs (add rsp, nArgs*8) and push result
void vancode_call_finish(dasm_State** Dst, int nArgs) {
  //| add rsp, nArgs*8
  //| push rax
  dasm_put(Dst, 375, nArgs*8);
#line 305 "vancode_jit.dasc"
}

// Self-recursion: call the current function directly
// nArgs = paramCount (known at compile time)
// selfAddr = address of the JIT function buffer (known at emit time via pre-allocated buf)
void vancode_call_self(dasm_State** Dst, int nArgs, void* selfAddr) {
  //| sub rsp, nArgs*8
  //| mov ecx, nArgs
  //| test ecx, ecx
  //| jz >2
  //|1:
  //| pop rax
  //| mov [rsp + rcx*8 - 8], rax
  //| dec ecx
  //| jnz <1
  //|2:
  //| mov rdi, rsp
  //| mov esi, nArgs
  //| mov rax, selfAddr
  //| call rax
  //| add rsp, nArgs*8
  //| push rax
  dasm_put(Dst, 381, nArgs*8, nArgs, - 8, nArgs, selfAddr, nArgs*8);
#line 327 "vancode_jit.dasc"
}
