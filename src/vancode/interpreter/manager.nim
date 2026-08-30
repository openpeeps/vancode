# VanCode - ModuleManager
# Manages loaded modules via hash-keyed LRU + optional flysystem persistent cache.
# Replaces Packager distribution logic. Embedder (tim) supplies cacheRoot.

import std/[tables, options, os, locks, sets, sequtils, strutils, hashes]
import pkg/checksums/md5 as md5
import pkg/flysystem
import ./ast
import ./chunk
import ./sym
import ./resolver
import ./policy
import ./cache/fbe

type
  ModuleEntry* = object
    normPath*: string
    hash*: string
    ast*: Ast
    script*: Script
    module*: Module
    chunk*: Chunk
    deps*: seq[string]
    fbeVersion*: uint32

  LruNode = ref object
    hash: string
    prev, next: LruNode

  ModuleManager* = ref object
    lock*: Lock
    maxEntries*: int
    entries*: Table[string, ModuleEntry]  # hash -> entry
    pathToHash*: Table[string, string]    # normPath -> hash
    lruHead*, lruTail*: LruNode
    lruIndex*: Table[string, LruNode]
    resolver*: FileResolver
    driver*: Option[LocalDriver]
    policy*: CompilationPolicy
    fbeVersion*: uint32
    pkgResolver*: Option[proc(pkgImport: string): Option[string] {.closure.}]

proc newModuleManager*(resolver = initResolver(),
                       cacheRoot: Option[string] = none(string),
                       maxEntries = 256,
                       fbeVersion = 1'u32,
                       policy = CompilationPolicy()): ModuleManager =
  result = ModuleManager(
    maxEntries: maxEntries,
    resolver: resolver,
    policy: policy,
    fbeVersion: fbeVersion,
  )
  initLock(result.lock)
  result.entries = initTable[string, ModuleEntry]()
  result.pathToHash = initTable[string, string]()
  result.lruIndex = initTable[string, LruNode]()
  if cacheRoot.isSome:
    let root = cacheRoot.get()
    # ensure dir exists via flysystem driver
    let d = newLocalDriver(root)
    result.driver = some(d)
  else:
    result.driver = none(LocalDriver)

proc computeHash*(source: string): string =
  ## Hex md5 of source content. Primary cache key.
  getMD5(source)

proc hashSource*(m: ModuleManager, source: string): string =
  computeHash(source)

# LRU helpers
proc detach(m: ModuleManager, n: LruNode) =
  if n.prev != nil: n.prev.next = n.next else: m.lruHead = n.next
  if n.next != nil: n.next.prev = n.prev else: m.lruTail = n.prev
  n.prev = nil
  n.next = nil

proc attachHead(m: ModuleManager, n: LruNode) =
  n.next = m.lruHead
  n.prev = nil
  if m.lruHead != nil: m.lruHead.prev = n
  m.lruHead = n
  if m.lruTail == nil: m.lruTail = n

proc touch(m: ModuleManager, hash: string) =
  let n = m.lruIndex.getOrDefault(hash, nil)
  if n == nil: return
  if m.lruHead == n: return
  m.detach(n)
  m.attachHead(n)

proc evictIfNeeded(m: ModuleManager) =
  if m.maxEntries <= 0: return
  while m.entries.len > m.maxEntries:
    let tail = m.lruTail
    if tail == nil: break
    let h = tail.hash
    m.detach(tail)
    m.lruIndex.del(h)
    let e = m.entries.getOrDefault(h, ModuleEntry())
    if e.normPath.len > 0:
      # only delete path mapping if it still points to this hash
      if m.pathToHash.getOrDefault(e.normPath, "") == h:
        m.pathToHash.del(e.normPath)
    m.entries.del(h)

# Public API
proc hasHash*(m: ModuleManager, hash: string): bool =
  withLock m.lock:
    result = m.entries.hasKey(hash)

proc hasModule*(m: ModuleManager, path: string): bool =
  let norm = normalizedPath(path)
  withLock m.lock:
    if not m.pathToHash.hasKey(norm): return false
    let h = m.pathToHash[norm]
    result = m.entries.hasKey(h)

proc getByHash*(m: ModuleManager, hash: string): Option[ModuleEntry] =
  withLock m.lock:
    if m.entries.hasKey(hash):
      m.touch(hash)
      result = some(m.entries[hash])
    else:
      result = none(ModuleEntry)

proc getModule*(m: ModuleManager, path: string): Option[ModuleEntry] =
  let norm = normalizedPath(path)
  withLock m.lock:
    let h = m.pathToHash.getOrDefault(norm, "")
    if h.len == 0: return none(ModuleEntry)
    if m.entries.hasKey(h):
      m.touch(h)
      result = some(m.entries[h])
    else:
      result = none(ModuleEntry)

proc allPaths*(m: ModuleManager): seq[string] =
  withLock m.lock:
    result = toSeq(m.pathToHash.keys)

proc allHashes*(m: ModuleManager): seq[string] =
  withLock m.lock:
    result = toSeq(m.entries.keys)

proc len*(m: ModuleManager): int =
  withLock m.lock:
    result = m.entries.len

proc put*(m: ModuleManager, entry: ModuleEntry) =
  ## Insert or update entry. Hash is primary key, path indexed.
  withLock m.lock:
    let h = entry.hash
    let isNew = not m.entries.hasKey(h)
    m.entries[h] = entry
    m.pathToHash[entry.normPath] = h
    if m.lruIndex.hasKey(h):
      m.touch(h)
    else:
      let n = LruNode(hash: h)
      m.lruIndex[h] = n
      m.attachHead(n)
    if isNew:
      m.evictIfNeeded()
    # persistent write (best-effort)
    if m.driver.isSome and entry.ast != nil:
      try:
        let rel = h & ".fbe"
        m.driver.get().write(rel, fbe.toFbe(entry.ast, m.fbeVersion))
      except: discard

proc tryLoadPersistent*(m: ModuleManager, hash: string): Option[ModuleEntry] =
  ## Attempt to load Ast from flysystem persistent cache. Returns entry with ast only.
  if m.driver.isNone: return none(ModuleEntry)
  let rel = hash & ".fbe"
  withLock m.lock:
    let d = m.driver.get()
    if not d.exists(rel): return none(ModuleEntry)
    try:
      let data = d.read(rel)
      let ast = fbe.fromFbe(data, Ast, m.fbeVersion)
      result = some(ModuleEntry(hash: hash, ast: ast, fbeVersion: m.fbeVersion))
    except:
      result = none(ModuleEntry)

proc invalidate*(m: ModuleManager, path: string, recursive = true) =
  let norm = normalizedPath(path)
  var toDelete: seq[string] = @[norm]
  withLock m.lock:
    if recursive:
      toDelete.add(m.resolver.dependants(norm, true))
    for p in toDelete:
      let h = m.pathToHash.getOrDefault(p, "")
      if h.len > 0:
        m.pathToHash.del(p)
        # only delete hash entry if no other path points to it
        var stillReferenced = false
        for _, hh in m.pathToHash:
          if hh == h: stillReferenced = true; break
        if not stillReferenced and m.entries.hasKey(h):
          m.entries.del(h)
          let n = m.lruIndex.getOrDefault(h, nil)
          if n != nil:
            m.detach(n)
            m.lruIndex.del(h)
      m.resolver.clearFile(p)

proc invalidateHash*(m: ModuleManager, hash: string) =
  withLock m.lock:
    if m.entries.hasKey(hash):
      let e = m.entries[hash]
      if m.pathToHash.getOrDefault(e.normPath, "") == hash:
        m.pathToHash.del(e.normPath)
      m.entries.del(hash)
    let n = m.lruIndex.getOrDefault(hash, nil)
    if n != nil:
      m.detach(n)
      m.lruIndex.del(hash)

proc clear*(m: ModuleManager, clearPersistent = false) =
  withLock m.lock:
    m.entries.clear()
    m.pathToHash.clear()
    m.lruIndex.clear()
    m.lruHead = nil
    m.lruTail = nil
  if clearPersistent and m.driver.isSome:
    # best-effort: delete all .fbe files? No-op for now — caller can wipe dir
    discard

proc dependencies*(m: ModuleManager, path: string): seq[string] =
  let norm = normalizedPath(path)
  result = m.resolver.dependencies(norm)

# Shared singleton
var globalManager {.global.}: ModuleManager
var globalLock {.global.}: Lock
var globalInit {.global.}: bool

proc sharedManager*(cacheRoot: Option[string] = none(string),
                    maxEntries = 256,
                    fbeVersion = 1'u32): ModuleManager =
  ## Global shared manager. First call wins for config.
  if not globalInit:
    initLock(globalLock)
    globalInit = true
  withLock globalLock:
    if globalManager == nil:
      globalManager = newModuleManager(cacheRoot = cacheRoot, maxEntries = maxEntries, fbeVersion = fbeVersion)
    result = globalManager

proc setSharedManager*(m: ModuleManager) =
  if not globalInit:
    initLock(globalLock)
    globalInit = true
  withLock globalLock:
    globalManager = m
