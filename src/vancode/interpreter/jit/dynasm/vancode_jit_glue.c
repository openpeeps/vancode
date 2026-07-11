/* Glue file: includes DynASM runtime + generated action list + emit functions.
   Compiled once by Nim's {.compile.} pragma.
   Use -DNDEBUG to disable DASM_CHECKS in release builds. */

#ifndef NDEBUG
#define DASM_CHECKS
#endif

#include "dasm_proto.h"
#include "dasm_x86.h"
#include "vancode_jit.c"

/* Re-export the action list pointer (the generated vancode_actions[] is
   static within the included file, so we provide a non-static accessor). */
const void* get_vancode_actions(void) {
  return (const void*)vancode_actions;
}

/* Helper: set up a dasm_State with our action list.
   Returns 0 on success, non-zero on failure. */
int vancode_setup(dasm_State** d, void** globals, unsigned int maxgl) {
  dasm_init(d, DASM_MAXSECTION);
  if (*d == NULL) return -1;
  dasm_setupglobal(d, globals, maxgl);
  dasm_setup(d, vancode_actions);
  return 0;
}
