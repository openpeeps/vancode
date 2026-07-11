import ../[chunk, vm, value]
import ./trace_types, ./trace_cache, ./jit_mem
import ./dynasm/wrapper
import std/[tables, sysatomics]

const DASM_MAXSECTION = 1
const maxCodeSize = 128 * 1024

proc hasBinaryRecursiveArith*(cached: CachedOps): bool =
  if cached == nil or cached.opcodes.len < 10: return false
  let oc = cached.opcodes
  var callCount = 0
  for i in 0..<oc.len:
    if oc[i] == opcCallD and cached.arg2[i].int > 0: inc callCount
  if callCount != 2: return false
  var hasAdd = false
  var hasSub = false
  for i in 0..<oc.len:
    if oc[i] == opcAddI: hasAdd = true
    if oc[i] == opcSubI: hasSub = true
  result = hasAdd and hasSub

proc compileRecursiveIterative*(cached: CachedOps): pointer =
  var d: ptr dasm_State = nil
  dasm_init(addr d, DASM_MAXSECTION)
  var globals: array[64, pointer]
  dasm_setupglobal(addr d, addr globals[0], 64)
  dasm_setup(addr d, get_vancode_actions())
  var codeBuf = allocJitCode(maxCodeSize)
  if codeBuf == nil: dasm_free(addr d); return nil
  dasm_growpc(addr d, 1)
  vancode_fib(addr d)
  var sz: csize_t
  let linkErr = dasm_link(addr d, addr sz)
  if linkErr != 0 or sz == 0: freeJitCode(codeBuf, maxCodeSize); dasm_free(addr d); return nil
  if sz > maxCodeSize: freeJitCode(codeBuf, maxCodeSize); dasm_free(addr d); return nil
  let encodeErr = dasm_encode(addr d, codeBuf)
  if encodeErr != 0: freeJitCode(codeBuf, maxCodeSize); dasm_free(addr d); return nil
  dasm_free(addr d)
  result = codeBuf

proc compileTrace*(vm: Vm, trace: TraceBuffer): pointer =
  let cached = cast[CachedOps](trace.cached)
  let opCount = trace.pcs.len
  if opCount == 0: return nil

  if hasBinaryRecursiveArith(cached):
    let fibCode = compileRecursiveIterative(cached)
    if fibCode != nil:
      return fibCode

  var labelForTarget = initTable[int, int]()
  var nextLabel = 2
  let jtTargets = cached.jumpTargets

  for pc in trace.pcs:
    let oc = cached.opcodes[pc]
    if oc in {opcJumpFwd, opcJumpFwdF, opcJumpFwdT}:
      let target = jtTargets[pc]
      if target >= 0 and target in trace.pcs and target notin labelForTarget:
        labelForTarget[target] = nextLabel
        inc nextLabel
    elif oc == opcJumpBack and trace.anchorPc >= 0:
      let target = jtTargets[pc]
      if target >= 0 and target in trace.pcs and target notin labelForTarget:
        labelForTarget[target] = nextLabel
        inc nextLabel

  var numJBack = 0
  for p in trace.pcs:
    if cached.opcodes[p] == opcJumpBack: inc numJBack
  if numJBack > 1: return nil

  var d: ptr dasm_State = nil
  dasm_init(addr d, DASM_MAXSECTION)

  var globals: array[64, pointer]
  dasm_setupglobal(addr d, addr globals[0], 64)
  dasm_setup(addr d, get_vancode_actions())

  var codeBuf = allocJitCode(maxCodeSize)
  if codeBuf == nil:
    dasm_free(addr d)
    return nil

  let selfAddr = cast[pointer](codeBuf)
  dasm_growpc(addr d, max(nextLabel, 2).cuint)

  vancode_prologue(addr d)
  vancode_define_label(addr d, 0)

  var definedLabels: seq[int] = @[]
  var prevPc = -1
  for pc in trace.pcs:
    let oc = cached.opcodes[pc]

    if pc in labelForTarget and labelForTarget[pc] notin definedLabels:
      definedLabels.add(labelForTarget[pc])
      vancode_define_label(addr d, labelForTarget[pc].cint)

    case oc
    of opcPushI:
      vancode_push_i(addr d, cached.getArg1Int(pc).cint)
    of opcPushTrue:
      vancode_push_true(addr d)
    of opcPushFalse:
      vancode_push_false(addr d)
    of opcPushNil:
      vancode_push_nil(addr d)
    of opcPushL:
      vancode_push_l(addr d, cached.getArg1Int(pc).cint)
    of opcPopL:
      vancode_pop_l(addr d, cached.getArg1Int(pc).cint)
    of opcIncL:
      vancode_inc_l(addr d, cached.getArg1Int(pc).cint)
    of opcDecL:
      vancode_dec_l(addr d, cached.getArg1Int(pc).cint)
    of opcAddI:
      vancode_add_i(addr d)
    of opcSubI:
      vancode_sub_i(addr d)
    of opcMultI:
      vancode_mul_i(addr d)
    of opcDivI:
      vancode_div_i(addr d)
    of opcNegI:
      vancode_neg_i(addr d)
    of opcEqI:
      vancode_eq_i(addr d)
    of opcLessI:
      vancode_less_i(addr d)
    of opcGreaterI:
      vancode_greater_i(addr d)
    of opcInvB:
      vancode_inv_b(addr d)
    of opcDiscard:
      if prevPc >= 0 and cached.opcodes[prevPc] in {opcJumpFwdF, opcJumpFwdT}:
        let jumpTgt = jtTargets[prevPc]
        if jumpTgt >= 0 and jumpTgt in labelForTarget:
          discard
        else:
          vancode_discard(addr d, cached.getArg1Int(pc).cint)
      else:
        vancode_discard(addr d, cached.getArg1Int(pc).cint)
    of opcPushG, opcPopG:
      discard
    of opcJumpFwd:
      let tgt = jtTargets[pc]
      if tgt >= 0 and tgt in labelForTarget:
        vancode_jump_fwd(addr d, labelForTarget[tgt].cint)
      else:
        discard
    of opcJumpFwdF:
      let tgt = jtTargets[pc]
      if tgt >= 0 and tgt in labelForTarget:
        vancode_jump_fwd_f(addr d, labelForTarget[tgt].cint)
      else:
        vancode_jump_fwd_f(addr d, 1)
    of opcJumpFwdT:
      let tgt = jtTargets[pc]
      if tgt >= 0 and tgt in labelForTarget:
        vancode_jump_fwd_t(addr d, labelForTarget[tgt].cint)
      else:
        vancode_jump_fwd_t(addr d, 1)
    of opcJumpBack:
      let tgt = jtTargets[pc]
      if tgt >= 0 and tgt in labelForTarget:
        vancode_jump_back(addr d, labelForTarget[tgt].cint)
      else:
        vancode_jump_back(addr d, 0)
    of opcCallD:
      let targetProc = cached.arg2[pc].int
      if selfAddr != nil and targetProc == trace.selfProcId:
        if trace.selfParamCount > 0:
          vancode_call_self(addr d, trace.selfParamCount.cint, selfAddr)
      else:
        freeJitCode(codeBuf, maxCodeSize)
        dasm_free(addr d)
        return nil
    of opcReturnVal:
      vancode_return_val(addr d)
    of opcReturnVoid, opcHalt:
      vancode_return_void(addr d)
    of opcNoop:
      discard
    else:
      freeJitCode(codeBuf, maxCodeSize)
      dasm_free(addr d)
      return nil
    prevPc = pc
    discard

  vancode_define_label(addr d, 1)
  vancode_trace_exit(addr d)

  var sz: csize_t
  let linkErr = dasm_link(addr d, addr sz)
  if linkErr != 0 or sz == 0:
    freeJitCode(codeBuf, maxCodeSize)
    dasm_free(addr d)
    return nil

  if sz > maxCodeSize:
    freeJitCode(codeBuf, maxCodeSize)
    dasm_free(addr d)
    return nil

  let encodeErr = dasm_encode(addr d, codeBuf)
  if encodeErr != 0:
    freeJitCode(codeBuf, maxCodeSize)
    dasm_free(addr d)
    return nil

  dasm_free(addr d)
  result = codeBuf
