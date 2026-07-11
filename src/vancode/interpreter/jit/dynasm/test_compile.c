#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define DASM_CHECKS
#define DASM_M_GROW(ctx, t, p, sz, need) \
  do { \
    size_t _sz = (sz), _need = (need); \
    if (_sz < _need) { \
      if (_sz < 16) _sz = 16; \
      while (_sz < _need) _sz += _sz; \
      (p) = (t *)realloc((p), _sz); \
      if ((p) == NULL) exit(1); \
      (sz) = _sz; \
    } \
  } while(0)
#define DASM_M_FREE(ctx, p, sz) free(p)

#include "dasm_proto.h"
#include "dasm_x86.h"
#include "dfkup_jit.c"

typedef int64_t (*JitFn)(int64_t*, int);

int main() {
  fprintf(stderr, "init...\n");
  dasm_State* d = NULL;
  dasm_init(&d, DASM_MAXSECTION);

  void* globals[lbl__MAX];
  dasm_setupglobal(&d, globals, lbl__MAX);
  fprintf(stderr, "setup...\n");
  dasm_setup(&d, dfkup_actions);

  fprintf(stderr, "emit prologue...\n");
  dfkup_prologue(&d);

  fprintf(stderr, "emit push_i 42...\n");
  dfkup_push_i(&d, 42);
  fprintf(stderr, "emit push_i 10...\n");
  dfkup_push_i(&d, 10);
  fprintf(stderr, "emit add_i...\n");
  dfkup_add_i(&d);
  fprintf(stderr, "emit return_val...\n");
  dfkup_return_val(&d);

  size_t sz;
  fprintf(stderr, "link...\n");
  int err = dasm_link(&d, &sz);
  if (err) { fprintf(stderr, "dasm_link: %d\n", err); return 1; }
  fprintf(stderr, "code size: %zu\n", sz);

  if (sz == 0) { fprintf(stderr, "zero size\n"); return 1; }

  void* buf = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (!buf) { fprintf(stderr, "mmap\n"); return 1; }

  fprintf(stderr, "encode...\n");
  err = dasm_encode(&d, buf);
  if (err) { fprintf(stderr, "dasm_encode: %d\n", err); return 1; }

  fprintf(stderr, "mprotect...\n");
  mprotect(buf, sz, PROT_READ | PROT_EXEC);

  JitFn fn = (JitFn)buf;
  fprintf(stderr, "calling fn...\n");
  int64_t args[8] = {0};
  int64_t result = fn(args, 0);
  fprintf(stderr, "result: %lld (expected 52)\n", (long long)result);

  dasm_free(&d);
  munmap(buf, sz);
  return 0;
}
