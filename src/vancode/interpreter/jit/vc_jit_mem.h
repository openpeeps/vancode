#ifndef VC_JIT_MEM_H
#define VC_JIT_MEM_H

#include <sys/mman.h>
#include <stdlib.h>
#if defined(__APPLE__) && defined(__aarch64__)
#include <pthread.h>
#endif

static inline void* vc_alloc_jit_code(size_t size) {
#if defined(__APPLE__) && defined(__aarch64__)
  int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT;
  void* p = mmap(NULL, size, PROT_READ | PROT_WRITE, flags, -1, 0);
  if (p == MAP_FAILED) return NULL;
  if (mprotect(p, size, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
    munmap(p, size);
    return NULL;
  }
  pthread_jit_write_protect_np(1);
#else
  void* p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
#endif
  return (p == MAP_FAILED) ? NULL : p;
}

static inline void vc_jit_code_make_writable(void* p) {
#if defined(__APPLE__) && defined(__aarch64__)
  pthread_jit_write_protect_np(0);
#else
  (void)p;
#endif
}

static inline void vc_jit_code_make_executable(void* p) {
#if defined(__APPLE__) && defined(__aarch64__)
  pthread_jit_write_protect_np(1);
#else
  (void)p;
#endif
}

static inline void vc_jit_code_flush_cache(void* p, size_t size) {
  // ARM64 has a non-coherent instruction cache: after writing machine
  // code the CPU may execute stale bytes (e.g. a previous generation's
  // code in a reused buffer) until the icache is invalidated. Missing
  // flush shows up as nondeterministic crashes/stale execution on
  // Apple Silicon while x86_64 (coherent icache) is unaffected.
#if defined(__aarch64__)
  __builtin___clear_cache((char*)p, (char*)p + size);
#else
  (void)p; (void)size;
#endif
}

static inline void vc_free_jit_code(void* p, size_t size) {
  munmap(p, size);
}

#endif
