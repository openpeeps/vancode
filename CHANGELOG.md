# v0.1.95 - 2026-07-07

- **FIX:** Reverted the `opcI2F` approach from v0.1.9 — emitting two sequential
  `opcI2F` instructions broke the stack (first one pushes a float, the second tries
  to read `.intVal` on it). Instead, `/` always emits `opcDivF` with result type
  `float`, and the gcc JIT's SIM stack tracks operand types per-pc (`divFTypes`) to
  pop from `stackI` (cast to `f64`) when operands are ints.

# v0.1.9 - 2026-07-07
- **FIX:** `/` operator now always returns a float (`opcDivF`), matching Python/JS
  semantics. Previously `11 / 2` emitted `opcDivI` (integer `div`), producing `5`
  instead of `5.5`. Added `opcI2F` (int-to-float conversion) opcode — codegen emits
  it for each integer operand before `opcDivF` so the JIT backends see float operands
  on the float stack. Implemented in VM, gccjit (`stackI` → cast → `stackF`), and
  llvmjit (`iStack` → `buildSIToFP` → `gepF`).

# v0.1.8 - 2026-07-07

- **NEW:** `ValueStorage` — value type for inline primitive storage in `Object.fields`,
  avoiding per-element heap allocation for `tyInt`/`tyBool`/`tyFloat`. Added
  `toValue`/`toStorage` conversion procs. Memory unchanged (24 bytes/element),
  allocations eliminated for primitive arrays.
- **CHANGE:** `Object.fields` type changed from `seq[Value]` to `seq[ValueStorage]`.
  All VM opcodes (`opcGetI`, `opcSetI`, `opcGetF`, `opcSetF`, `opcConstrArray`,
  `opcConstrObj`) updated to convert via `.toValue`/`.toStorage`. Foreign procs
  accessing `objectVal.fields` also updated.
- **PERF:** JIT `jitBridgeFastAdd` now writes `ValueStorage` directly (zero heap
  allocation per call). Combined with global bridge buffer and proc cache, the
  `test_loop.dfkup` (10M `list.add(i)`) achieves 6.7× speedup (4.97s → 0.74s user).
- **PERF:** Global `jitBridgeTmpBuf` replaces per-call stack `tmp` array in
  `jitCallProcBridgeFlat`, eliminating 10M×256 destructor calls.
- **PERF:** `jitProcCache` array caches `findProcById` results, eliminating O(n)
  linear scans on every bridge call.
- **FIX:** JIT hot loop trigger now gates on `currentChunk == script.mainChunk`
  (was compiling the main chunk even when a nested function's loop triggered,
  causing re-execution from scratch and performance regression).
- **FIX:** `stack.setLen(0)` before JIT call in `opcJumpBack` prevents spurious
  leftover value from being returned as script result (a GC interaction where
  stack had a stale int value after JIT function ran).
- **FIX:** `incL`/`decL` optimization in codegen now checks `sym.varLocal` before
  emitting `opcIncL`/`opcDecL` (was incorrectly applying the optimization to global
  variables, corrupting global state when `x = x + 1` matched the pattern but `x`
  was a global).

- **FIX:** `popVar` now always emits `opcPopL` for locals (removed `varSet` guard).
  Previously, the first assignment to a local left its initial value on the eval stack
  (relied on by the VM's `stackBottom + idx` scheme), but the JIT reads from a separate
  `flatArgs` array that was never written, causing `pushL` to read 0. This manifested as
  SIGFPE (`n / 0`) in bool-returning functions with `if` + `while` + division, and as
  infinite loops in for-range-lowered code.
- **FIX:** `popScope` restored to emit `opcDiscard` for each scope variable. Although
  `popVar` now stores values into local slots (via `opcPopL`), the stored value remains
  in the `stack` array at the slot position and would leak as the script result. The
  `opcDiscard` removes it. This fixes `for i in ["one", "two"]: echo i` producing
  `one`, `two`, `two` (last value leaked as script result) and `for i in range(0,2):
  echo i` producing `0 1 2 false` (accumulated peeked bools leaked as script result).
- **FIX:** For-range lowered loops now emit `opcDiscard 1` after `opcJumpFwdT` (which
  peeks) to consume the condition bool when entering the body. Previously the peeked
  bools accumulated one per iteration, leaking on the stack and appearing as a
  spurious `false` script result.
- **FIX:** For-range `__counter` variable now wrapped in its own `pushScope`/`popScope`
  so multiple for-range loops in the same block don't clash with "already declared"
  errors.
- **FIX:** JIT `opcJumpFwdT`/`opcJumpFwdF` changed from `popInt` to peek (read
  `stackI[sp-1]` without decrementing `sp`), matching the VM interpreter behavior
  that for-range lowered bytecode depends on.
- **FIX:** `ensureLocal(idx)` calls added in `opcPushL`/`opcPopL` VM dispatch,
  preventing `IndexDefect` crashes when loops run inside function scope.
- **FIX:** Default return type for functions without explicit return type annotation
  changed from `stmt` (`ttyAny`) to `void` (`ttyVoid`), so untyped functions can be
  called as statements.
- **NEW:** Hot loop detection overhead eliminated — `hotLoopCount` and
  `hotLoopCompiled` moved from hash tables (`Table`/`HashSet` on VM) to direct fields
  on `Chunk`, removing per-iteration hashing.
- **NEW:** Cross-function `opcCallD` in JIT compiler — functions can now call other
  user-defined functions from JIT-compiled code via `jitCallProcBridgeFlat`, a C-ABI
  bridge that uses `jitFnTable` for O(1) proc lookup. Self-recursion still uses a
  direct recursive gcc_jit call (no bridge overhead).
- **NEW:** `jitFnTable` and `jitParamCount` arrays populated on compilation for O(1)
  bridge lookup by `procId`.
- **FIX:** Self-recursion `opcCallD` now correctly pops all arguments (was only popping
  one arg, worked for single-param functions like `fib` but would fail for multi-param).
- **FIX:** `prewarmScriptOpsRec` now adds the script itself to `vm.importedModules`
  (not just its sub-modules), so JIT compilation can find procs in the current script.
- **FIX:** `dfkup.nim` calls `vmInstance.prewarmScriptOps(script)` before `interpret`,
  ensuring `vm.importedModules` is populated for JIT compilation.
- **FIX:** JIT compiler cross-function `opcCallD` only bridges to `pkNative` targets;
  falls back to VM for `pkForeign` (built-in) calls to avoid silently returning 0.
- **NEW:** JIT bool return type support — `jitReturnBool` field on `Proc`, set during
  codegen when return type is `bool`; the JIT wrapper returns `tyBool` instead of
  `tyInt` for bool-returning functions.

# v0.1.7 - 2026-07-05
- minor changes
- libgcc jit work

# v0.1.6 - 2026-07-04

- **FIX:** Empty arrays (`items: []`) now compile to `array[any]` instead of
  crashing with "Cannot create an empty array without type inference"
- **FIX:** Nested `for` loops on object dot-access (`for sub in item.items:`)
  no longer segfault — resolves to `items(item.items)` iteration
- **FIX:** `pushDefault` now handles `ttyArray` by emitting `opcConstrArray` with
  0 elements, enabling variable declarations with array types but no initial value
  (e.g. `var x: array[string]`)
- **NEW:** `CompilationPolicy` enforcement in codegen — `CodeGen` now has a
  `policy: CompilationPolicy` field (threaded through `initCompiler`/`initCodeGen`)
  that controls which features are allowed at compile time. Supports `policyAny`
  (wildcard), `policyImports`, `policyStdlib`, `policyPackages`, `policyLoops`,
  `policyConditionals`, `policyAssignments`, and `policyLoadDynlib`.
