import
  std/[macros, sequtils],
  ../futures

type
  InternalRaisesFuture*[T, E] = ref object of Future[T]
    ## Future with a tuple of possible exception types
    ## eg InternalRaisesFuture[void, (ValueError, OSError)]
    ##
    ## This type gets injected by `async: (raises: ...)` and similar utilities
    ## and should not be used manually as the internal exception representation
    ## is subject to change in future chronos versions.

proc makeNoRaises*(): NimNode {.compileTime.} =
  # An empty tuple would have been easier but...
  # https://github.com/nim-lang/Nim/issues/22863
  # https://github.com/nim-lang/Nim/issues/22865

  ident"void"

macro Raising*[T](F: typedesc[Future[T]], E: varargs[typedesc]): untyped =
  ## Given a Future type instance, return a type storing `{.raises.}`
  ## information
  ##
  ## Note; this type may change in the future
  E.expectKind(nnkBracket)

  let raises = if E.len == 0:
    makeNoRaises()
  else:
    nnkTupleConstr.newTree(E.mapIt(it))
  nnkBracketExpr.newTree(
    ident "InternalRaisesFuture",
    nnkDotExpr.newTree(F, ident"T"),
    raises
  )

template init*[T, E](
    F: type InternalRaisesFuture[T, E], fromProc: static[string] = ""): F =
  ## Creates a new pending future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = F()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Pending, {})
  res

template init*[T, E](
    F: type InternalRaisesFuture[T, E], fromProc: static[string] = "",
    flags: static[FutureFlags]): F =
  ## Creates a new pending future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = F()
  internalInitFutureBase(
    res, getSrcLocation(fromProc), FutureState.Pending, flags)
  res

proc dig(n: NimNode): NimNode {.compileTime.} =
  # Dig through the layers of type to find the raises list
  if n.eqIdent("void"):
    n
  elif n.kind == nnkBracketExpr:
    if n[0].eqIdent("tuple"):
      n
    elif n[0].eqIdent("typeDesc"):
      dig(getType(n[1]))
    else:
      echo astGenRepr(n)
      raiseAssert "Unkown bracket"
  elif n.kind == nnkTupleConstr:
    n
  else:
    dig(getType(getTypeInst(n)))

proc isNoRaises*(n: NimNode): bool {.compileTime.} =
  dig(n).eqIdent("void")

iterator members(tup: NimNode): NimNode =
  # Given a typedesc[tuple] = (A, B, C), yields the tuple members (A, B C)
  if not isNoRaises(tup):
    for n in getType(getTypeInst(tup)[1])[1..^1]:
      yield n

proc members(tup: NimNode): seq[NimNode] {.compileTime.} =
  for t in tup.members():
    result.add(t)

proc containsSignature(members: openArray[NimNode], typ: NimNode): bool {.compileTime.} =
  let typHash = signatureHash(typ)

  for err in members:
    if signatureHash(err) == typHash:
      return true
  false

# Utilities for working with the E part of InternalRaisesFuture - unstable
macro prepend*(tup: typedesc, typs: varargs[typed]): typedesc =
  result = nnkTupleConstr.newTree()
  for err in typs:
    if not tup.members().containsSignature(err):
      result.add err

  for err in tup.members():
    result.add err

  if result.len == 0:
    result = makeNoRaises()

macro remove*(tup: typedesc, typs: varargs[typed]): typedesc =
  result = nnkTupleConstr.newTree()
  for err in tup.members():
    if not typs[0..^1].containsSignature(err):
      result.add err

  if result.len == 0:
    result = makeNoRaises()

macro union*(tup0: typedesc, tup1: typedesc): typedesc =
  ## Join the types of the two tuples deduplicating the entries
  result = nnkTupleConstr.newTree()

  for err in tup0.members():
    var found = false
    for err2 in tup1.members():
      if signatureHash(err) == signatureHash(err2):
        found = true
    if not found:
      result.add err

  for err2 in getType(getTypeInst(tup1)[1])[1..^1]:
    result.add err2
  if result.len == 0:
    result = makeNoRaises()

proc getRaisesTypes*(raises: NimNode): NimNode =
  let typ = getType(raises)
  case typ.typeKind
  of ntyTypeDesc: typ[1]
  else: typ

macro checkRaises*[T: CatchableError](
    future: InternalRaisesFuture, raises: typed, error: ref T,
    warn: static bool = true): untyped =
  ## Generate code that checks that the given error is compatible with the
  ## raises restrictions of `future`.
  ##
  ## This check is done either at compile time or runtime depending on the
  ## information available at compile time - in particular, if the raises
  ## inherit from `error`, we end up with the equivalent of a downcast which
  ## raises a Defect if it fails.
  let
    raises = getRaisesTypes(raises)

  expectKind(getTypeInst(error), nnkRefTy)
  let toMatch = getTypeInst(error)[0]


  if isNoRaises(raises):
    error(
      "`fail`: `" & repr(toMatch) & "` incompatible with `raises: []`", future)
    return

  var
    typeChecker = ident"false"
    maybeChecker = ident"false"
    runtimeChecker = ident"false"

  for errorType in raises[1..^1]:
    typeChecker = infix(typeChecker, "or", infix(toMatch, "is", errorType))
    maybeChecker = infix(maybeChecker, "or", infix(errorType, "is", toMatch))
    runtimeChecker = infix(
      runtimeChecker, "or",
      infix(error, "of", nnkBracketExpr.newTree(ident"typedesc", errorType)))

  let
    errorMsg = "`fail`: `" & repr(toMatch) & "` incompatible with `raises: " & repr(raises[1..^1]) & "`"
    warningMsg = "Can't verify `fail` exception type at compile time - expected one of " & repr(raises[1..^1]) & ", got `" & repr(toMatch) & "`"
    # A warning from this line means exception type will be verified at runtime
    warning = if warn:
      quote do: {.warning: `warningMsg`.}
    else: newEmptyNode()

  # Cannot check inhertance in macro so we let `static` do the heavy lifting
  quote do:
    when not(`typeChecker`):
      when not(`maybeChecker`):
        static:
          {.error: `errorMsg`.}
      else:
        `warning`
        assert(`runtimeChecker`, `errorMsg`)

proc error*[T](future: InternalRaisesFuture[T, void]): ref CatchableError {.
    raises: [].} =
  static:
    warning("No exceptions possible with this operation, `error` always returns nil")
  nil

proc readError*[T](future: InternalRaisesFuture[T, void]): ref CatchableError {.
    raises: [ValueError].} =
  static:
    warning("No exceptions possible with this operation, `readError` always raises")
  raise newException(ValueError, "No error in future.")
