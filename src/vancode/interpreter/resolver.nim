# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) iLiquid, 2019-2020
#     https://github.com/liquidev/
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## This module defines a file resolver for managing file imports and includes. It tracks
## which files have been resolve (imported/included) by which other files, and provides 
## utilities for checking dependencies and resolving files.
## 
## This is used by the interpreter to manage file imports and includes, and
## to detect circular dependencies.

import std/[os, tables, sequtils, sets, strutils]

type
  ResolvedFiles = Table[string, seq[string]]
  VirtualFileSystem* = ref object
    existsProc*: proc(path: string): bool
    readProc*: proc(path: string): string

  FileResolver* = object
    ## Manages file resolution for imports/includes
    resolvedFiles*: ResolvedFiles
      # Tracks which files have been resolved (imported/included)
    fs*: VirtualFileSystem
      ## The virtual file system used to check for file existence and
      ## read file contents. This allows us to swap out the actual disk FS for
      ## an in-memory or embedded FS

  ResolverError* = object of CatchableError

proc newDiskFS*(): VirtualFileSystem =
  ## Create a virtual file system that interacts with the actual disk.
  ## 
  ## This is the default file system used by the resolver, but it can be replaced with
  ## an in-memory or embedded file system for testing or special use cases.
  result = VirtualFileSystem()
  result.existsProc = proc(path: string): bool = os.fileExists(path)
  result.readProc   = proc(path: string): string = readFile(path)

proc newInMemoryFS*(map: TableRef[string, string]): VirtualFileSystem =
  ## Create a virtual file system from an in-memory map of file paths to contents.
  ## 
  ## This is useful for testing or when you want to embed files directly into your application
  result = VirtualFileSystem()
  result.existsProc =
    proc(path: string): bool =
      let p = normalizedPath(path)
      map.hasKey(p)
  result.readProc =
    proc(path: string): string =
      let p = normalizedPath(path)
      if not map.hasKey(p):
        raise newException(ResolverError, "File not found in VFS: " & p)
      return map[p]

proc initResolver*(): FileResolver =
  ## Initialize a new FileResolver
  result.resolvedFiles = ResolvedFiles()
  result.fs = newDiskFS()

proc fileExists*(resolver: FileResolver, filePath: string): bool =
  # Checks if the file exists using the configured FS
  return resolver.fs.existsProc(filePath)

proc readFile*(resolver: FileResolver, filePath: string): string =
  # Read file using the configured FS; raise ResolverError if missing
  if not resolver.fs.existsProc(filePath):
    raise newException(ResolverError, "File does not exist: " & filePath)
  return resolver.fs.readProc(filePath)

proc isResolved*(resolver: FileResolver, filePath: string): bool =
  # Checks if the file has already been resolved (included/imported)
  result = resolver.resolvedFiles.hasKey(filePath)

proc ensureNode(resolver: var FileResolver, filePath: string) =
  if not resolver.resolvedFiles.hasKey(filePath):
    resolver.resolvedFiles[filePath] = @[]

proc dependencies*(resolver: FileResolver, filePath: string): seq[string] =
  resolver.resolvedFiles.getOrDefault(filePath, @[])

proc setDependencies*(resolver: var FileResolver, aFile: string, deps: openArray[string]) =
  ## Set the dependencies for a file. This is used to mark which files have
  ## been resolved (imported/included) by a given file
  resolver.ensureNode(aFile)
  var normalized: seq[string] = @[]
  for dep in deps:
    let d = normalizedPath(dep)
    if d != aFile and d notin normalized:
      normalized.add(d)
      resolver.ensureNode(d)
  resolver.resolvedFiles[aFile] = normalized

proc clearFile*(resolver: var FileResolver, filePath: string) =
  ## Clear the resolution status of a file
  for key in resolver.resolvedFiles.keys.toSeq:
    resolver.resolvedFiles[key] = resolver.resolvedFiles[key].filterIt(it != filePath)
  if resolver.resolvedFiles.hasKey(filePath):
    resolver.resolvedFiles.del(filePath)

proc dependants*(resolver: FileResolver, target: string, recursive = true): seq[string] =
  ## Returns a list of files that depend on the target file. If `recursive` is true,
  ## it will return all files that directly or indirectly depend on the target. Otherwise
  ## it will only return files that directly depend to the target.
  if not recursive:
    for file, deps in resolver.resolvedFiles:
      if target in deps:
        result.add(file)
    return

  var
    visited = initHashSet[string]()
    stack = @[target]

  while stack.len > 0:
    let current = stack.pop()
    for file, deps in resolver.resolvedFiles:
      if current in deps and file notin visited:
        visited.incl(file)
        result.add(file)
        stack.add(file)

proc resolveFile*(resolver: var FileResolver, aFile, bFile: string) =
  ## Resolve a file import/include. This proc checks
  ## if the file exists, if it has already been resolved,
  ## and if there are any circular or self-imports.
  ## 
  ## If all checks pass, it marks the file as resolved.
  ## TODO handle symlinks
  if not resolver.fileExists(bFile):
    raise newException(ResolverError, "File does not exist: " & bFile)
  if bFile == aFile:
    raise newException(ResolverError, "Self-import detected: " & aFile)

  resolver.ensureNode(aFile)
  resolver.ensureNode(bFile)

  if bFile notin resolver.resolvedFiles[aFile]:
    resolver.resolvedFiles[aFile].add(bFile)