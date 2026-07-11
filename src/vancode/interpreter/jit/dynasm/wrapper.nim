when defined(vancodeDynasmDynlib):
  const dynasmLib* {.strdefine.} = "libvancodejit.dylib"
  {.pragma: dynasm, importc, cdecl, dynlib: dynasmLib.}
else:
  {.compile: "vancode_jit_glue.c".}
  {.pragma: dynasm, importc, cdecl.}

type
  dasm_State* = object

# DynASM C API: Dst_DECL defaults to "dasm_State **Dst"
# So all functions take pointer-to-pointer (ptr ptr dasm_State)
proc dasm_init*(Dst: ptr ptr dasm_State; maxsection: cint) {.dynasm, importc: "dasm_init".}
proc dasm_free*(Dst: ptr ptr dasm_State) {.dynasm, importc: "dasm_free".}
proc dasm_setupglobal*(Dst: ptr ptr dasm_State; gl: ptr pointer; maxgl: cuint) {.dynasm, importc: "dasm_setupglobal".}
proc dasm_setup*(Dst: ptr ptr dasm_State; actionlist: pointer) {.dynasm, importc: "dasm_setup".}
proc dasm_growpc*(Dst: ptr ptr dasm_State; maxpc: cuint) {.dynasm, importc: "dasm_growpc".}
proc dasm_link*(Dst: ptr ptr dasm_State; szp: ptr csize_t): cint {.dynasm, importc: "dasm_link".}
proc dasm_encode*(Dst: ptr ptr dasm_State; buf: pointer): cint {.dynasm, importc: "dasm_encode".}

# Our emit functions also take dasm_State** per Dst_DECL convention
proc vancode_prologue*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_prologue".}
proc vancode_load_param*(Dst: ptr ptr dasm_State; slot: cint) {.dynasm, importc: "vancode_load_param".}
proc vancode_push_i*(Dst: ptr ptr dasm_State; value: cint) {.dynasm, importc: "vancode_push_i".}
proc vancode_push_true*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_push_true".}
proc vancode_push_false*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_push_false".}
proc vancode_push_nil*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_push_nil".}
proc vancode_push_l*(Dst: ptr ptr dasm_State; slot: cint) {.dynasm, importc: "vancode_push_l".}
proc vancode_pop_l*(Dst: ptr ptr dasm_State; slot: cint) {.dynasm, importc: "vancode_pop_l".}
proc vancode_inc_l*(Dst: ptr ptr dasm_State; slot: cint) {.dynasm, importc: "vancode_inc_l".}
proc vancode_dec_l*(Dst: ptr ptr dasm_State; slot: cint) {.dynasm, importc: "vancode_dec_l".}
proc vancode_add_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_add_i".}
proc vancode_sub_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_sub_i".}
proc vancode_mul_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_mul_i".}
proc vancode_div_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_div_i".}
proc vancode_neg_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_neg_i".}
proc vancode_eq_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_eq_i".}
proc vancode_less_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_less_i".}
proc vancode_greater_i*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_greater_i".}
proc vancode_inv_b*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_inv_b".}
proc vancode_discard*(Dst: ptr ptr dasm_State; n: cint) {.dynasm, importc: "vancode_discard".}
proc vancode_jump_fwd*(Dst: ptr ptr dasm_State; label: cint) {.dynasm, importc: "vancode_jump_fwd".}
proc vancode_jump_back*(Dst: ptr ptr dasm_State; label: cint) {.dynasm, importc: "vancode_jump_back".}
proc vancode_jump_fwd_f*(Dst: ptr ptr dasm_State; label: cint) {.dynasm, importc: "vancode_jump_fwd_f".}
proc vancode_jump_fwd_t*(Dst: ptr ptr dasm_State; label: cint) {.dynasm, importc: "vancode_jump_fwd_t".}
proc vancode_define_label*(Dst: ptr ptr dasm_State; label: cint) {.dynasm, importc: "vancode_define_label".}
proc vancode_return_val*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_return_val".}
proc vancode_return_void*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_return_void".}
proc vancode_halt*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_halt".}
proc vancode_bridge_2*(Dst: ptr ptr dasm_State; fnAddr: pointer) {.dynasm, importc: "vancode_bridge_2".}
proc vancode_bridge_3_void*(Dst: ptr ptr dasm_State; fnAddr: pointer) {.dynasm, importc: "vancode_bridge_3_void".}
proc vancode_bridge_3*(Dst: ptr ptr dasm_State; fnAddr: pointer) {.dynasm, importc: "vancode_bridge_3".}
proc vancode_bridge_4*(Dst: ptr ptr dasm_State; fnAddr: pointer) {.dynasm, importc: "vancode_bridge_4".}
proc vancode_call_alloc*(Dst: ptr ptr dasm_State; nArgs: cint) {.dynasm, importc: "vancode_call_alloc".}
proc vancode_call_pop_slot*(Dst: ptr ptr dasm_State; slot: cint) {.dynasm, importc: "vancode_call_pop_slot".}
proc vancode_call_invoke*(Dst: ptr ptr dasm_State; nArgs: cint; procId: cint; bridgeFn: pointer) {.dynasm, importc: "vancode_call_invoke".}
proc vancode_call_finish*(Dst: ptr ptr dasm_State; nArgs: cint) {.dynasm, importc: "vancode_call_finish".}
proc vancode_call_self*(Dst: ptr ptr dasm_State; nArgs: cint; selfAddr: pointer) {.dynasm, importc: "vancode_call_self".}
proc vancode_guard_false*(Dst: ptr ptr dasm_State; exitLabel: cint) {.dynasm, importc: "vancode_guard_false".}
proc vancode_guard_true*(Dst: ptr ptr dasm_State; exitLabel: cint) {.dynasm, importc: "vancode_guard_true".}
proc vancode_trace_exit*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_trace_exit".}
proc vancode_fib*(Dst: ptr ptr dasm_State) {.dynasm, importc: "vancode_fib".}
proc vancode_pushg*(Dst: ptr ptr dasm_State; namePtr: pointer; bridgeFn: pointer) {.dynasm, importc: "vancode_pushg".}
proc vancode_popg*(Dst: ptr ptr dasm_State; namePtr: pointer; bridgeFn: pointer) {.dynasm, importc: "vancode_popg".}

proc get_vancode_actions*(): pointer {.dynasm, importc: "get_vancode_actions".}
proc vancode_setup*(d: ptr ptr dasm_State; gl: ptr pointer; maxgl: cuint): cint {.dynasm, importc: "vancode_setup".}
