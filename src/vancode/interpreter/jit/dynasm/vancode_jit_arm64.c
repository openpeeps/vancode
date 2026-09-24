/*
** This file has been pre-processed with DynASM.
** https://luajit.org/dynasm.html
** DynASM version 1.5.0, DynASM arm version 1.5.0
** DO NOT EDIT! The original file is in "vancode_jit_arm64.dasc".
*/

#line 1 "vancode_jit_arm64.dasc"
//|.arch arm64
#if DASM_VERSION != 10500
#error "Version mismatch between DynASM and included encoding engine"
#endif
#line 2 "vancode_jit_arm64.dasc"

//|.section code
#define DASM_SECTION_CODE	0
#define DASM_MAXSECTION		1
#line 4 "vancode_jit_arm64.dasc"

//|.actionlist vancode_actions
static const unsigned int vancode_actions[320] = {
0xa9bd7bfd,
0x910003fd,
0xf9000bf3,
0xf9000ff4,
0xaa0003f3,
0x00000000,
0xf8400269,
0x000f0003,
0xf81f0fe9,
0x00000000,
0xd2800009,
0x000a0205,
0xf2a00009,
0x000a0205,
0x93407d29,
0xf81f0fe9,
0x00000000,
0x52800029,
0xf81f0fe9,
0x00000000,
0xf81f0fff,
0x00000000,
0xf81f0fff,
0x00000000,
0xf8400269,
0x000f0003,
0xf81f0fe9,
0x00000000,
0xf84107e9,
0xf8000269,
0x000f0003,
0x00000000,
0xf8400269,
0x000f0003,
0x91000529,
0xf8000269,
0x000f0003,
0x00000000,
0xf8400269,
0x000f0003,
0xd1000529,
0xf8000269,
0x000f0003,
0x00000000,
0xf84107e9,
0xf84107ea,
0x8b09014a,
0xf81f0fea,
0x00000000,
0xf84107e9,
0xf84107ea,
0xcb09014a,
0xf81f0fea,
0x00000000,
0xf84107e9,
0xf84107ea,
0x9b097d4a,
0xf81f0fea,
0x00000000,
0xf84107e9,
0xf84107ea,
0x9ac90d4a,
0xf81f0fea,
0x00000000,
0xf84107e9,
0xcb0903e9,
0xf81f0fe9,
0x00000000,
0xf84107e9,
0xf84107ea,
0xeb09015f,
0x1a9f17e9,
0xf81f0fe9,
0x00000000,
0xf84107e9,
0xf84107ea,
0xeb09015f,
0x1a9fa7e9,
0xf81f0fe9,
0x00000000,
0xf84107e9,
0xf84107ea,
0xeb09015f,
0x1a9fd7e9,
0xf81f0fe9,
0x00000000,
0xf84107e9,
0xf100013f,
0x1a9f17e9,
0xf81f0fe9,
0x00000000,
0x52800009,
0x000a0205,
0x8b2963ff,
0x00000000,
0x14000000,
0x00070000,
0x00000000,
0x14000000,
0x00070000,
0x00000000,
0xf84107e9,
0xf100013f,
0x54000000,
0x00070800,
0xf81f0fe9,
0x00000000,
0xf84107e9,
0xf100013f,
0x54000001,
0x00070800,
0xf81f0fe9,
0x00000000,
0x00080000,
0x00000000,
0xf84107e0,
0xa94153f3,
0xa8c37bfd,
0xd65f03c0,
0x00000000,
0x52800000,
0xa94153f3,
0xa8c37bfd,
0xd65f03c0,
0x00000000,
0x52800000,
0xa94153f3,
0xa8c37bfd,
0xd65f03c0,
0x00000000,
0xf9400000,
0xf100001f,
0x5400000d,
0x00070800,
0xaa1f03e8,
0x52800029,
0xaa0003ea,
0xd100054a,
0x00080000,
0xaa0903eb,
0x8b080129,
0xaa0b03e8,
0xd100054a,
0x54000001,
0x00070800,
0xaa0903e0,
0xd65f03c0,
0x00080000,
0xd65f03c0,
0x00000000,
0x52800000,
0xa94153f3,
0xa8c37bfd,
0xd65f03c0,
0x00000000,
0xd2800000,
0x000a0205,
0xf2a00000,
0x000a0205,
0xf2c00000,
0x000a0205,
0xf2e00000,
0x000a0205,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0xf81f0fe0,
0x00000000,
0xf84107e1,
0xd2800000,
0x000a0205,
0xf2a00000,
0x000a0205,
0xf2c00000,
0x000a0205,
0xf2e00000,
0x000a0205,
0x52800042,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0x00000000,
0xf84107e1,
0xd2800000,
0x000a0205,
0xf2a00000,
0x000a0205,
0xf2c00000,
0x000a0205,
0xf2e00000,
0x000a0205,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0x00000000,
0xf84107e1,
0xf84107e0,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0xf81f0fe0,
0x00000000,
0xf84107e2,
0xf84107e1,
0xf84107e0,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0x00000000,
0xf84107e2,
0xf84107e1,
0xf84107e0,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0xf81f0fe0,
0x00000000,
0xf84107e3,
0xf84107e2,
0xf84107e1,
0xf84107e0,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0xf81f0fe0,
0x00000000,
0x52800009,
0x000a0205,
0xd37df129,
0x91003d29,
0xd344fd29,
0xd37ced29,
0xcb2963ff,
0x00000000,
0xf84003e9,
0x000f0003,
0xf80003e9,
0x000f0003,
0x00000000,
0xf84107e9,
0xf80003e9,
0x000f0003,
0x00000000,
0x910003f4,
0x52800002,
0x000a0205,
0x52800003,
0x52800000,
0x000a0205,
0xaa1403e1,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0x00000000,
0x52800009,
0x000a0205,
0x8b2963ff,
0xf81f0fe0,
0x00000000,
0x910003e0,
0x52800001,
0x000a0205,
0xd2800010,
0x000a0205,
0xf2a00010,
0x000a0205,
0xf2c00010,
0x000a0205,
0xf2e00010,
0x000a0205,
0xd63f0200,
0x00000000
};

#line 6 "vancode_jit_arm64.dasc"

//|.globals lbl_
enum {
  lbl__MAX
};
#line 8 "vancode_jit_arm64.dasc"

void vancode_prologue(dasm_State** Dst) {
  //| stp x29, x30, [sp, #-48]!
  //| mov x29, sp
  //| str x19, [sp, #16]
  //| str x20, [sp, #24]
  //| mov x19, x0
  dasm_put(Dst, 0);
#line 15 "vancode_jit_arm64.dasc"
}

void vancode_load_param(dasm_State** Dst, int slot) {
  //| ldr x9, [x19, #(slot*8)]
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 6, (slot*8));
#line 20 "vancode_jit_arm64.dasc"
}

void vancode_push_i(dasm_State** Dst, int value) {
  //| movz x9, #(value & 0xFFFF)
  //| movk x9, #((value >> 16) & 0xFFFF), lsl #16
  //| sxtw x9, w9
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 10, (value & 0xFFFF), ((value >> 16) & 0xFFFF));
#line 27 "vancode_jit_arm64.dasc"
}

void vancode_push_true(dasm_State** Dst) {
  //| mov x9, #1
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 17);
#line 32 "vancode_jit_arm64.dasc"
}

void vancode_push_false(dasm_State** Dst) {
  //| str xzr, [sp, #-16]!
  dasm_put(Dst, 20);
#line 36 "vancode_jit_arm64.dasc"
}

void vancode_push_nil(dasm_State** Dst) {
  //| str xzr, [sp, #-16]!
  dasm_put(Dst, 22);
#line 40 "vancode_jit_arm64.dasc"
}

void vancode_push_l(dasm_State** Dst, int slot) {
  //| ldr x9, [x19, #(slot*8)]
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 24, (slot*8));
#line 45 "vancode_jit_arm64.dasc"
}

void vancode_pop_l(dasm_State** Dst, int slot) {
  //| ldr x9, [sp], #16
  //| str x9, [x19, #(slot*8)]
  dasm_put(Dst, 28, (slot*8));
#line 50 "vancode_jit_arm64.dasc"
}

void vancode_inc_l(dasm_State** Dst, int slot) {
  //| ldr x9, [x19, #(slot*8)]
  //| add x9, x9, #1
  //| str x9, [x19, #(slot*8)]
  dasm_put(Dst, 32, (slot*8), (slot*8));
#line 56 "vancode_jit_arm64.dasc"
}

void vancode_dec_l(dasm_State** Dst, int slot) {
  //| ldr x9, [x19, #(slot*8)]
  //| sub x9, x9, #1
  //| str x9, [x19, #(slot*8)]
  dasm_put(Dst, 38, (slot*8), (slot*8));
#line 62 "vancode_jit_arm64.dasc"
}

void vancode_add_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| add x10, x10, x9
  //| str x10, [sp, #-16]!
  dasm_put(Dst, 44);
#line 69 "vancode_jit_arm64.dasc"
}

void vancode_sub_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| sub x10, x10, x9
  //| str x10, [sp, #-16]!
  dasm_put(Dst, 49);
#line 76 "vancode_jit_arm64.dasc"
}

void vancode_mul_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| mul x10, x10, x9
  //| str x10, [sp, #-16]!
  dasm_put(Dst, 54);
#line 83 "vancode_jit_arm64.dasc"
}

void vancode_div_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| sdiv x10, x10, x9
  //| str x10, [sp, #-16]!
  dasm_put(Dst, 59);
#line 90 "vancode_jit_arm64.dasc"
}

void vancode_neg_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| neg x9, x9
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 64);
#line 96 "vancode_jit_arm64.dasc"
}

void vancode_eq_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| cmp x10, x9
  //| cset w9, eq
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 68);
#line 104 "vancode_jit_arm64.dasc"
}

void vancode_less_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| cmp x10, x9
  //| cset w9, lt
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 74);
#line 112 "vancode_jit_arm64.dasc"
}

void vancode_greater_i(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| ldr x10, [sp], #16
  //| cmp x10, x9
  //| cset w9, gt
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 80);
#line 120 "vancode_jit_arm64.dasc"
}

void vancode_inv_b(dasm_State** Dst) {
  //| ldr x9, [sp], #16
  //| cmp x9, #0
  //| cset w9, eq
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 86);
#line 127 "vancode_jit_arm64.dasc"
}

void vancode_discard(dasm_State** Dst, int n) {
  //| mov x9, #(n*16)
  //| add sp, sp, x9
  dasm_put(Dst, 91, (n*16));
#line 132 "vancode_jit_arm64.dasc"
}

void vancode_jump_fwd(dasm_State** Dst, int label) {
  //| b =>label
  dasm_put(Dst, 95, label);
#line 136 "vancode_jit_arm64.dasc"
}

void vancode_jump_back(dasm_State** Dst, int label) {
  //| b =>label
  dasm_put(Dst, 98, label);
#line 140 "vancode_jit_arm64.dasc"
}

void vancode_jump_fwd_f(dasm_State** Dst, int label) {
  //| ldr x9, [sp], #16
  //| cmp x9, #0
  //| beq =>label
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 101, label);
#line 147 "vancode_jit_arm64.dasc"
}

void vancode_jump_fwd_t(dasm_State** Dst, int label) {
  //| ldr x9, [sp], #16
  //| cmp x9, #0
  //| bne =>label
  //| str x9, [sp, #-16]!
  dasm_put(Dst, 107, label);
#line 154 "vancode_jit_arm64.dasc"
}

void vancode_define_label(dasm_State** Dst, int label) {
  //|=>label:
  dasm_put(Dst, 113, label);
#line 158 "vancode_jit_arm64.dasc"
}

void vancode_return_val(dasm_State** Dst) {
  //| ldr x0, [sp], #16
  //| ldp x19, x20, [sp, #16]
  //| ldp x29, x30, [sp], #48
  //| ret
  dasm_put(Dst, 115);
#line 165 "vancode_jit_arm64.dasc"
}

void vancode_return_void(dasm_State** Dst) {
  //| mov x0, #0
  //| ldp x19, x20, [sp, #16]
  //| ldp x29, x30, [sp], #48
  //| ret
  dasm_put(Dst, 120);
#line 172 "vancode_jit_arm64.dasc"
}

void vancode_trace_exit(dasm_State** Dst) {
  //| mov x0, #0
  //| ldp x19, x20, [sp, #16]
  //| ldp x29, x30, [sp], #48
  //| ret
  dasm_put(Dst, 125);
#line 179 "vancode_jit_arm64.dasc"
}

void vancode_fib(dasm_State** Dst) {
  //| ldr x0, [x0]
  //| cmp x0, #0
  //| ble =>1
  //| mov x8, xzr
  //| mov x9, #1
  //| mov x10, x0
  //| sub x10, x10, #1
  //|=>2:
  //| mov x11, x9
  //| add x9, x9, x8
  //| mov x8, x11
  //| sub x10, x10, #1
  //| bne =>2
  //| mov x0, x9
  //| ret
  //|=>1:
  //| ret
  dasm_put(Dst, 130, 1, 2, 2, 1);
#line 199 "vancode_jit_arm64.dasc"
}

void vancode_halt(dasm_State** Dst) {
  //| mov x0, #0
  //| ldp x19, x20, [sp, #16]
  //| ldp x29, x30, [sp], #48
  //| ret
  dasm_put(Dst, 150);
#line 206 "vancode_jit_arm64.dasc"
}

void vancode_pushg(dasm_State** Dst, unsigned long long namePtr,
                   unsigned long long bridgeFn) {
  //| movz x0, #(namePtr & 0xFFFFULL)
  //| movk x0, #((namePtr >> 16) & 0xFFFFULL), lsl #16
  //| movk x0, #((namePtr >> 32) & 0xFFFFULL), lsl #32
  //| movk x0, #((namePtr >> 48) & 0xFFFFULL), lsl #48
  //| movz x16, #(bridgeFn & 0xFFFFULL)
  //| movk x16, #((bridgeFn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((bridgeFn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((bridgeFn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  //| str x0, [sp, #-16]!
  dasm_put(Dst, 155, (namePtr & 0xFFFFULL), ((namePtr >> 16) & 0xFFFFULL), ((namePtr >> 32) & 0xFFFFULL), ((namePtr >> 48) & 0xFFFFULL), (bridgeFn & 0xFFFFULL), ((bridgeFn >> 16) & 0xFFFFULL), ((bridgeFn >> 32) & 0xFFFFULL), ((bridgeFn >> 48) & 0xFFFFULL));
#line 220 "vancode_jit_arm64.dasc"
}

void vancode_popg(dasm_State** Dst, unsigned long long namePtr,
                  unsigned long long bridgeFn) {
  //| ldr x1, [sp], #16
  //| movz x0, #(namePtr & 0xFFFFULL)
  //| movk x0, #((namePtr >> 16) & 0xFFFFULL), lsl #16
  //| movk x0, #((namePtr >> 32) & 0xFFFFULL), lsl #32
  //| movk x0, #((namePtr >> 48) & 0xFFFFULL), lsl #48
  //| mov x2, #2
  //| movz x16, #(bridgeFn & 0xFFFFULL)
  //| movk x16, #((bridgeFn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((bridgeFn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((bridgeFn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  dasm_put(Dst, 174, (namePtr & 0xFFFFULL), ((namePtr >> 16) & 0xFFFFULL), ((namePtr >> 32) & 0xFFFFULL), ((namePtr >> 48) & 0xFFFFULL), (bridgeFn & 0xFFFFULL), ((bridgeFn >> 16) & 0xFFFFULL), ((bridgeFn >> 32) & 0xFFFFULL), ((bridgeFn >> 48) & 0xFFFFULL));
#line 235 "vancode_jit_arm64.dasc"
}

void vancode_pop_host(dasm_State** Dst, unsigned long long namePtr,
                      unsigned long long bridgeFn) {
  //| ldr x1, [sp], #16
  //| movz x0, #(namePtr & 0xFFFFULL)
  //| movk x0, #((namePtr >> 16) & 0xFFFFULL), lsl #16
  //| movk x0, #((namePtr >> 32) & 0xFFFFULL), lsl #32
  //| movk x0, #((namePtr >> 48) & 0xFFFFULL), lsl #48
  //| movz x16, #(bridgeFn & 0xFFFFULL)
  //| movk x16, #((bridgeFn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((bridgeFn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((bridgeFn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  dasm_put(Dst, 194, (namePtr & 0xFFFFULL), ((namePtr >> 16) & 0xFFFFULL), ((namePtr >> 32) & 0xFFFFULL), ((namePtr >> 48) & 0xFFFFULL), (bridgeFn & 0xFFFFULL), ((bridgeFn >> 16) & 0xFFFFULL), ((bridgeFn >> 32) & 0xFFFFULL), ((bridgeFn >> 48) & 0xFFFFULL));
#line 249 "vancode_jit_arm64.dasc"
}

void vancode_bridge_2(dasm_State** Dst, unsigned long long fn) {
  //| ldr x1, [sp], #16
  //| ldr x0, [sp], #16
  //| movz x16, #(fn & 0xFFFFULL)
  //| movk x16, #((fn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((fn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((fn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  //| str x0, [sp, #-16]!
  dasm_put(Dst, 213, (fn & 0xFFFFULL), ((fn >> 16) & 0xFFFFULL), ((fn >> 32) & 0xFFFFULL), ((fn >> 48) & 0xFFFFULL));
#line 260 "vancode_jit_arm64.dasc"
}

void vancode_bridge_3_void(dasm_State** Dst, unsigned long long fn) {
  //| ldr x2, [sp], #16
  //| ldr x1, [sp], #16
  //| ldr x0, [sp], #16
  //| movz x16, #(fn & 0xFFFFULL)
  //| movk x16, #((fn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((fn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((fn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  dasm_put(Dst, 226, (fn & 0xFFFFULL), ((fn >> 16) & 0xFFFFULL), ((fn >> 32) & 0xFFFFULL), ((fn >> 48) & 0xFFFFULL));
#line 271 "vancode_jit_arm64.dasc"
}

void vancode_bridge_3(dasm_State** Dst, unsigned long long fn) {
  //| ldr x2, [sp], #16
  //| ldr x1, [sp], #16
  //| ldr x0, [sp], #16
  //| movz x16, #(fn & 0xFFFFULL)
  //| movk x16, #((fn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((fn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((fn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  //| str x0, [sp, #-16]!
  dasm_put(Dst, 239, (fn & 0xFFFFULL), ((fn >> 16) & 0xFFFFULL), ((fn >> 32) & 0xFFFFULL), ((fn >> 48) & 0xFFFFULL));
#line 283 "vancode_jit_arm64.dasc"
}

void vancode_bridge_4(dasm_State** Dst, unsigned long long fn) {
  //| ldr x3, [sp], #16
  //| ldr x2, [sp], #16
  //| ldr x1, [sp], #16
  //| ldr x0, [sp], #16
  //| movz x16, #(fn & 0xFFFFULL)
  //| movk x16, #((fn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((fn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((fn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  //| str x0, [sp, #-16]!
  dasm_put(Dst, 253, (fn & 0xFFFFULL), ((fn >> 16) & 0xFFFFULL), ((fn >> 32) & 0xFFFFULL), ((fn >> 48) & 0xFFFFULL));
#line 296 "vancode_jit_arm64.dasc"
}

void vancode_call_alloc(dasm_State** Dst, int nArgs) {
  // Reserve a packed flatArgs array of nArgs int64s below the operand
  // stack. Operands live in 16-byte slots (str [sp,#-16]!) while the
  // array is 8-byte packed for the bridge ABI, so the Nim side copies
  // with src = allocSize + (n-1-i)*16, dst = i*8. Round the reservation
  // up to 16 bytes: Apple Silicon faults (SIGBUS) on misaligned sp at
  // blr, which the old nArgs*8 reservation caused for odd arities.
  //| mov x9, #nArgs
  //| lsl x9, x9, #3
  //| add x9, x9, #15
  //| lsr x9, x9, #4
  //| lsl x9, x9, #4
  //| sub sp, sp, x9
  dasm_put(Dst, 268, nArgs);
#line 311 "vancode_jit_arm64.dasc"
}

void vancode_call_move_one(dasm_State** Dst, int srcDisp, int dstDisp) {
  //| ldr x9, [sp, #srcDisp]
  //| str x9, [sp, #dstDisp]
  dasm_put(Dst, 276, srcDisp, dstDisp);
#line 316 "vancode_jit_arm64.dasc"
}

void vancode_call_pop_slot(dasm_State** Dst, int slot) {
  //| ldr x9, [sp], #16
  //| str x9, [sp, #(slot*8)]
  dasm_put(Dst, 281, (slot*8));
#line 321 "vancode_jit_arm64.dasc"
}

void vancode_call_invoke(dasm_State** Dst, int nArgs, int procId,
                         unsigned long long bridgeFn) {
  //| mov x20, sp
  //| mov x2, #nArgs
  //| mov x3, #0
  //| mov x0, #procId
  //| mov x1, x20
  //| movz x16, #(bridgeFn & 0xFFFFULL)
  //| movk x16, #((bridgeFn >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((bridgeFn >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((bridgeFn >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  dasm_put(Dst, 285, nArgs, procId, (bridgeFn & 0xFFFFULL), ((bridgeFn >> 16) & 0xFFFFULL), ((bridgeFn >> 32) & 0xFFFFULL), ((bridgeFn >> 48) & 0xFFFFULL));
#line 335 "vancode_jit_arm64.dasc"
}

void vancode_call_finish(dasm_State** Dst, int dropBytes) {
  // Drop the flatArgs array plus the stale 16-byte operand slots above
  // it (dropBytes = allocSize + nArgs*16, passed from the Nim side) and
  // push the bridge result. Via register to avoid the 12-bit limit on
  // add-immediates for large arities.
  //| mov x9, #dropBytes
  //| add sp, sp, x9
  //| str x0, [sp, #-16]!
  dasm_put(Dst, 302, dropBytes);
#line 345 "vancode_jit_arm64.dasc"
}

void vancode_call_self(dasm_State** Dst, int nArgs,
                       unsigned long long selfAddr) {
  //| mov x0, sp
  //| mov x1, #nArgs
  //| movz x16, #(selfAddr & 0xFFFFULL)
  //| movk x16, #((selfAddr >> 16) & 0xFFFFULL), lsl #16
  //| movk x16, #((selfAddr >> 32) & 0xFFFFULL), lsl #32
  //| movk x16, #((selfAddr >> 48) & 0xFFFFULL), lsl #48
  //| blr x16
  dasm_put(Dst, 307, nArgs, (selfAddr & 0xFFFFULL), ((selfAddr >> 16) & 0xFFFFULL), ((selfAddr >> 32) & 0xFFFFULL), ((selfAddr >> 48) & 0xFFFFULL));
#line 356 "vancode_jit_arm64.dasc"
}
