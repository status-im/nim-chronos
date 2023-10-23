import
  std/macros,
  ../futures

type
  InternalRaisesFuture*[T, E] = ref object of Future[T]
    ## Future with a tuple of possible exception types
    ## eg InternalRaisesFuture[void, (ValueError, OSError)]
    ##
    ## This type gets injected by `asyncraises` and similar utilities and
    ## should not be used manually as the internal exception representation is
    ## subject to change in future chronos versions.

iterator members(tup: NimNode): NimNode =
  # Given a typedesc[tuple] = (A, B, C), yields the tuple members (A, B C)
  if not tup.eqIdent("void"):
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
macro prepend*(tup: typedesc[tuple], typs: varargs[typed]): typedesc =
  result = nnkTupleConstr.newTree()
  for err in typs:
    if not tup.members().containsSignature(err):
      result.add err

  for err in tup.members():
    result.add err

  if result.len == 0:
    result = ident"void"

macro remove*(tup: typedesc[tuple], typs: varargs[typed]): typedesc =
  result = nnkTupleConstr.newTree()
  for err in tup.members():
    if not typs[0..^1].containsSignature(err):
      result.add err

  if result.len == 0:
    result = ident"void"

macro union*(tup0: typedesc[tuple], tup1: typedesc[tuple]): typedesc =
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

proc getRaises*(future: NimNode): NimNode {.compileTime.} =
  # Given InternalRaisesFuture[T, (A, B, C)], returns (A, B, C)
  let types = getType(getTypeInst(future)[2])
  if types.eqIdent("void"):
    nnkBracketExpr.newTree(newEmptyNode())
  else:
    expectKind(types, nnkBracketExpr)
    expectKind(types[0], nnkSym)
    assert types[0].strVal == "tuple"
    assert types.len >= 1

    types

macro checkRaises*[T: CatchableError](
    future: InternalRaisesFuture, error: ref T, warn: static bool = true): untyped =
  ## Generate code that checks that the given error is compatible with the
  ## raises restrictions of `future`.
  ##
  ## This check is done either at compile time or runtime depending on the
  ## information available at compile time - in particular, if the raises
  ## inherit from `error`, we end up with the equivalent of a downcast which
  ## raises a Defect if it fails.
  let raises = getRaises(future)

  expectKind(getTypeInst(error), nnkRefTy)
  let toMatch = getTypeInst(error)[0]

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
    errorMsg = "`fail`: `" & repr(toMatch) & "` incompatible with `asyncraises: " & repr(raises[1..^1]) & "`"
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
