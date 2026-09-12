/* Glue file: includes DynASM runtime + generated action list + emit functions.
   Compiled once by Nim's {.compile.} pragma.
   Use -DNDEBUG to disable DASM_CHECKS in release builds. */

/* vancode embeds its own DynASM runtime copy (openparser ships another one
   for regex JIT). Rename this TU's runtime symbols so both can link into
   one binary without duplicate-symbol errors. The generated vancode_jit.c
   and the helpers below see the renamed symbols consistently. */
#define dasm_init vc_dasm_init
#define dasm_free vc_dasm_free
#define dasm_setup vc_dasm_setup
#define dasm_setupglobal vc_dasm_setupglobal
#define dasm_growpc vc_dasm_growpc
#define dasm_put vc_dasm_put
#define dasm_link vc_dasm_link
#define dasm_encode vc_dasm_encode
#define dasm_getpclabel vc_dasm_getpclabel
#define dasm_checkstep vc_dasm_checkstep

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
