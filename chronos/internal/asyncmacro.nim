#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import
  std/[macros],
  ../[futures, config],
  ./raisesfutures

proc processBody(node, setResultSym: NimNode): NimNode {.compileTime.} =
  case node.kind
  of nnkReturnStmt:
    # `return ...` -> `setResult(...); return`
    let
      res = newNimNode(nnkStmtList, node)
    if node[0].kind != nnkEmpty:
      res.add newCall(setResultSym, processBody(node[0], setResultSym))
    res.add newNimNode(nnkReturnStmt, node).add(newEmptyNode())

    res
  of RoutineNodes-{nnkTemplateDef}:
    # Skip nested routines since they have their own return value distinct from
    # the Future we inject
    node
  else:
    if node.kind == nnkYieldStmt:
      # asyncdispatch allows `yield` but this breaks cancellation
      warning(
        "`yield` in async procedures not supported - use `awaitne` instead",
        node)

    for i in 0 ..< node.len:
      node[i] = processBody(node[i], setResultSym)
    node

proc wrapInTryFinally(
  fut, baseType, body, raises: NimNode,
  handleException: bool): NimNode {.compileTime.} =
  # creates:
  # try: `body`
  # [for raise in raises]:
  #   except `raise`: closureSucceeded = false; `castFutureSym`.fail(exc)
  # finally:
  #   if closureSucceeded:
  #     `castFutureSym`.complete(result)
  #
  # Calling `complete` inside `finally` ensures that all success paths
  # (including early returns and code inside nested finally statements and
  # defer) are completed with the final contents of `result`
  let
    closureSucceeded = genSym(nskVar, "closureSucceeded")
    nTry = nnkTryStmt.newTree(body)
    excName = ident"exc"

  # Depending on the exception type, we must have at most one of each of these
  # "special" exception handlers that are needed to implement cancellation and
  # Defect propagation
  var
    hasDefect = false
    hasCancelledError = false
    hasCatchableError = false

  template addDefect =
    if not hasDefect:
      hasDefect = true
      # When a Defect is raised, the program is in an undefined state and
      # continuing running other tasks while the Future completion sits on the
      # callback queue may lead to further damage so we re-raise them eagerly.
      nTry.add nnkExceptBranch.newTree(
            nnkInfix.newTree(ident"as", ident"Defect", excName),
            nnkStmtList.newTree(
              nnkAsgn.newTree(closureSucceeded, ident"false"),
              nnkRaiseStmt.newTree(excName)
            )
          )
  template addCancelledError =
    if not hasCancelledError:
      hasCancelledError = true
      nTry.add nnkExceptBranch.newTree(
                ident"CancelledError",
                nnkStmtList.newTree(
                  nnkAsgn.newTree(closureSucceeded, ident"false"),
                  newCall(ident "cancelAndSchedule", fut)
                )
              )

  template addCatchableError =
    if not hasCatchableError:
      hasCatchableError = true
      nTry.add nnkExceptBranch.newTree(
                nnkInfix.newTree(ident"as", ident"CatchableError", excName),
                nnkStmtList.newTree(
                  nnkAsgn.newTree(closureSucceeded, ident"false"),
                  newCall(ident "fail", fut, excName)
                ))

  var raises = if raises == nil:
    nnkTupleConstr.newTree(ident"CatchableError")
  elif isNoRaises(raises):
    nnkTupleConstr.newTree()
  else:
    raises.copyNimTree()

  if handleException:
    raises.add(ident"Exception")

  for exc in raises:
    if exc.eqIdent("Exception"):
      addCancelledError
      addCatchableError
      addDefect

      # Because we store `CatchableError` in the Future, we cannot re-raise the
      # original exception
      nTry.add nnkExceptBranch.newTree(
                nnkInfix.newTree(ident"as", ident"Exception", excName),
                newCall(ident "fail", fut,
                  nnkStmtList.newTree(
                    nnkAsgn.newTree(closureSucceeded, ident"false"),
                  quote do:
                    (ref AsyncExceptionError)(
                      msg: `excName`.msg, parent: `excName`)))
              )
    elif exc.eqIdent("CancelledError"):
      addCancelledError
    elif exc.eqIdent("CatchableError"):
      # Ensure cancellations are re-routed to the cancellation handler even if
      # not explicitly specified in the raises list
      addCancelledError
      addCatchableError
    else:
      nTry.add nnkExceptBranch.newTree(
                nnkInfix.newTree(ident"as", exc, excName),
                nnkStmtList.newTree(
                  nnkAsgn.newTree(closureSucceeded, ident"false"),
                  newCall(ident "fail", fut, excName)
                ))

  addDefect # Must not complete future on defect

  nTry.add nnkFinally.newTree(
    nnkIfStmt.newTree(
      nnkElifBranch.newTree(
        closureSucceeded,
        if baseType.eqIdent("void"): # shortcut for non-generic void
          newCall(ident "complete", fut)
        else:
          nnkWhenStmt.newTree(
            nnkElifExpr.newTree(
              nnkInfix.newTree(ident "is", baseType, ident "void"),
              newCall(ident "complete", fut)
            ),
            nnkElseExpr.newTree(
              newCall(ident "complete", fut, newCall(ident "move", ident "result"))
            )
          )
        )
      )
    )

  nnkStmtList.newTree(
      newVarStmt(closureSucceeded, ident"true"),
      nTry
  )

proc getName(node: NimNode): string {.compileTime.} =
  case node.kind
  of nnkSym:
    return node.strVal
  of nnkPostfix:
    return node[1].strVal
  of nnkIdent:
    return node.strVal
  of nnkEmpty:
    return "anonymous"
  else:
    error("Unknown name.")

macro unsupported(s: static[string]): untyped =
  error s

proc params2(someProc: NimNode): NimNode {.compileTime.} =
  # until https://github.com/nim-lang/Nim/pull/19563 is available
  if someProc.kind == nnkProcTy:
    someProc[0]
  else:
    params(someProc)

proc cleanupOpenSymChoice(node: NimNode): NimNode {.compileTime.} =
  # Replace every Call -> OpenSymChoice by a Bracket expr
  # ref https://github.com/nim-lang/Nim/issues/11091
  if node.kind in nnkCallKinds and
    node[0].kind == nnkOpenSymChoice and node[0].eqIdent("[]"):
    result = newNimNode(nnkBracketExpr)
    for child in node[1..^1]:
      result.add(cleanupOpenSymChoice(child))
  else:
    result = node.copyNimNode()
    for child in node:
      result.add(cleanupOpenSymChoice(child))

type
  AsyncParams = tuple
    raw: bool
    raises: NimNode
    handleException: bool

proc decodeParams(params: NimNode): AsyncParams =
  # decodes the parameter tuple given in `async: (name: value, ...)` to its
  # recognised parts
  params.expectKind(nnkTupleConstr)

  var
    raw = false
    raises: NimNode = nil
    handleException = false
    hasLocalAnnotations = false

  for param in params:
    param.expectKind(nnkExprColonExpr)

    if param[0].eqIdent("raises"):
      hasLocalAnnotations = true
      param[1].expectKind(nnkBracket)
      if param[1].len == 0:
        raises = makeNoRaises()
      else:
        raises = nnkTupleConstr.newTree()
        for possibleRaise in param[1]:
          raises.add(possibleRaise)
    elif param[0].eqIdent("raw"):
      # boolVal doesn't work in untyped macros it seems..
      raw = param[1].eqIdent("true")
    elif param[0].eqIdent("handleException"):
      hasLocalAnnotations = true
      handleException = param[1].eqIdent("true")
    else:
      warning("Unrecognised async parameter: " & repr(param[0]), param)

  if not hasLocalAnnotations:
    handleException = chronosHandleException

  (raw, raises, handleException)

proc isEmpty(n: NimNode): bool {.compileTime.} =
  # true iff node recursively contains only comments or empties
  case n.kind
  of nnkEmpty, nnkCommentStmt: true
  of nnkStmtList:
    for child in n:
      if not isEmpty(child): return false
    true
  else:
    false

proc asyncSingleProc(prc, params: NimNode): NimNode {.compileTime.} =
  ## This macro transforms a single procedure into a closure iterator.
  ## The ``async`` macro supports a stmtList holding multiple async procedures.
  if prc.kind notin {nnkProcTy, nnkProcDef, nnkLambda, nnkMethodDef, nnkDo}:
      error("Cannot transform " & $prc.kind & " into an async proc." &
            " proc/method definition or lambda node expected.", prc)

  for pragma in prc.pragma():
    if pragma.kind == nnkExprColonExpr and pragma[0].eqIdent("raises"):
      warning("The raises pragma doesn't work on async procedures - use " &
      "`async: (raises: [...]) instead.", prc)

  let returnType = cleanupOpenSymChoice(prc.params2[0])

  # Verify that the return type is a Future[T]
  let baseType =
    if returnType.kind == nnkEmpty:
      ident "void"
    elif not (
        returnType.kind == nnkBracketExpr and
        (eqIdent(returnType[0], "Future") or eqIdent(returnType[0], "InternalRaisesFuture"))):
      error(
        "Expected return type of 'Future' got '" & repr(returnType) & "'", prc)
      return
    else:
      returnType[1]

  let
    # When the base type is known to be void (and not generic), we can simplify
    # code generation - however, in the case of generic async procedures it
    # could still end up being void, meaning void detection needs to happen
    # post-macro-expansion.
    baseTypeIsVoid = baseType.eqIdent("void")
    (raw, raises, handleException) = decodeParams(params)
    internalFutureType =
      if baseTypeIsVoid:
        newNimNode(nnkBracketExpr, prc).
          add(newIdentNode("Future")).
          add(baseType)
      else:
        returnType
    internalReturnType = if raises == nil:
      internalFutureType
    else:
      nnkBracketExpr.newTree(
        newIdentNode("InternalRaisesFuture"),
        baseType,
        raises
      )

  prc.params2[0] = internalReturnType

  if prc.kind notin {nnkProcTy, nnkLambda}:
    prc.addPragma(newColonExpr(ident "stackTrace", ident "off"))

  # The proc itself doesn't raise
  prc.addPragma(
    nnkExprColonExpr.newTree(newIdentNode("raises"), nnkBracket.newTree()))

  # `gcsafe` isn't deduced even though we require async code to be gcsafe
  # https://github.com/nim-lang/RFCs/issues/435
  prc.addPragma(newIdentNode("gcsafe"))

  if raw: # raw async = body is left as-is
    if raises != nil and prc.kind notin {nnkProcTy, nnkLambda} and not isEmpty(prc.body):
      # Inject `raises` type marker that causes `newFuture` to return a raise-
      # tracking future instead of an ordinary future:
      #
      # type InternalRaisesFutureRaises = `raisesTuple`
      # `body`
      prc.body = nnkStmtList.newTree(
        nnkTypeSection.newTree(
          nnkTypeDef.newTree(
            nnkPragmaExpr.newTree(
              ident"InternalRaisesFutureRaises",
              nnkPragma.newTree(ident "used")),
            newEmptyNode(),
            raises,
          )
        ),
        prc.body
      )

  elif prc.kind in {nnkProcDef, nnkLambda, nnkMethodDef, nnkDo} and
      not isEmpty(prc.body):
    let
      setResultSym = ident "setResult"
      procBody = prc.body.processBody(setResultSym)
      resultIdent = ident "result"
      fakeResult = quote do:
        template result: auto {.used.} =
          {.fatal: "You should not reference the `result` variable inside" &
                  " a void async proc".}
      resultDecl =
        if baseTypeIsVoid: fakeResult
        else: nnkWhenStmt.newTree(
          # when `baseType` is void:
          nnkElifExpr.newTree(
            nnkInfix.newTree(ident "is", baseType, ident "void"),
            fakeResult
          ),
          # else:
          nnkElseExpr.newTree(
            newStmtList(
              quote do: {.push warning[resultshadowed]: off.},
              # var result {.used.}: `baseType`
              # In the proc body, result may or may not end up being used
              # depending on how the body is written - with implicit returns /
              # expressions in particular, it is likely but not guaranteed that
              # it is not used. Ideally, we would avoid emitting it in this
              # case to avoid the default initializaiton. {.used.} typically
              # works better than {.push.} which has a tendency to leak out of
              # scope.
              # TODO figure out if there's a way to detect `result` usage in
              #      the proc body _after_ template exapnsion, and therefore
              #      avoid creating this variable - one option is to create an
              #      addtional when branch witha fake `result` and check
              #      `compiles(procBody)` - this is not without cost though
              nnkVarSection.newTree(nnkIdentDefs.newTree(
                nnkPragmaExpr.newTree(
                  resultIdent,
                  nnkPragma.newTree(ident "used")),
                baseType, newEmptyNode())
                ),
              quote do: {.pop.},
            )
          )
        )

      # ```nim
      # template `setResultSym`(code: untyped) {.used.} =
      #   when typeof(code) is void: code
      #   else: `resultIdent` = code
      # ```
      #
      # this is useful to handle implicit returns, but also
      # to bind the `result` to the one we declare here
      setResultDecl =
        if baseTypeIsVoid: # shortcut for non-generic void
          newEmptyNode()
        else:
          nnkTemplateDef.newTree(
            setResultSym,
            newEmptyNode(), newEmptyNode(),
            nnkFormalParams.newTree(
              newEmptyNode(),
              nnkIdentDefs.newTree(
                ident"code",
                ident"untyped",
                newEmptyNode(),
              )
            ),
            nnkPragma.newTree(ident"used"),
            newEmptyNode(),
            nnkWhenStmt.newTree(
              nnkElifBranch.newTree(
                nnkInfix.newTree(
                  ident"is", nnkTypeOfExpr.newTree(ident"code"), ident"void"),
                ident"code"
              ),
              nnkElse.newTree(
                newAssignment(resultIdent, ident"code")
              )
            )
          )

      internalFutureSym = ident "chronosInternalRetFuture"
      castFutureSym = nnkCast.newTree(internalFutureType, internalFutureSym)
      # Wrapping in try/finally ensures that early returns are handled properly
      # and that `defer` is processed in the right scope
      completeDecl = wrapInTryFinally(
        castFutureSym, baseType,
        if baseTypeIsVoid: procBody # shortcut for non-generic `void`
        else: newCall(setResultSym, procBody),
        raises,
        handleException
      )

      closureBody = newStmtList(resultDecl, setResultDecl, completeDecl)

      internalFutureParameter = nnkIdentDefs.newTree(
        internalFutureSym, newIdentNode("FutureBase"), newEmptyNode())
      prcName = prc.name.getName
      iteratorNameSym = genSym(nskIterator, $prcName)
      closureIterator = newProc(
        iteratorNameSym,
        [newIdentNode("FutureBase"), internalFutureParameter],
        closureBody, nnkIteratorDef)

    iteratorNameSym.copyLineInfo(prc)

    closureIterator.pragma = newNimNode(nnkPragma, lineInfoFrom=prc.body)
    closureIterator.addPragma(newIdentNode("closure"))

    # `async` code must be gcsafe
    closureIterator.addPragma(newIdentNode("gcsafe"))

    # Exceptions are caught inside the iterator and stored in the future
    closureIterator.addPragma(nnkExprColonExpr.newTree(
      newIdentNode("raises"),
      nnkBracket.newTree()
    ))

    # The body of the original procedure (now moved to the iterator) is replaced
    # with:
    #
    # ```nim
    # let resultFuture = newFuture[T]()
    # resultFuture.internalClosure = `iteratorNameSym`
    # futureContinue(resultFuture)
    # return resultFuture
    # ```
    #
    # Declared at the end to be sure that the closure doesn't reference it,
    # avoid cyclic ref (#203)
    #
    # Do not change this code to `quote do` version because `instantiationInfo`
    # will be broken for `newFuture()` call.

    let
      outerProcBody = newNimNode(nnkStmtList, prc.body)

    # Copy comment for nimdoc
    if prc.body.len > 0 and prc.body[0].kind == nnkCommentStmt:
      outerProcBody.add(prc.body[0])

    outerProcBody.add(closureIterator)

    let
      retFutureSym = ident "resultFuture"
      newFutProc = if raises == nil:
        nnkBracketExpr.newTree(ident "newFuture", baseType)
      else:
        nnkBracketExpr.newTree(ident "newInternalRaisesFuture", baseType, raises)

    retFutureSym.copyLineInfo(prc)
    outerProcBody.add(
      newLetStmt(
        retFutureSym,
        newCall(newFutProc, newLit(prcName))
      )
    )

    outerProcBody.add(
      newAssignment(
        newDotExpr(retFutureSym, newIdentNode("internalClosure")),
        iteratorNameSym)
    )

    outerProcBody.add(
        newCall(newIdentNode("futureContinue"), retFutureSym)
    )

    outerProcBody.add newNimNode(nnkReturnStmt, prc.body[^1]).add(retFutureSym)

    prc.body = outerProcBody

  when chronosDumpAsync:
    echo repr prc

  prc

template await*[T](f: Future[T]): T =
  ## Ensure that the given `Future` is finished, then return its value.
  ##
  ## If the `Future` failed or was cancelled, the corresponding exception will
  ## be raised instead.
  ##
  ## If the `Future` is pending, execution of the current `async` procedure
  ## will be suspended until the `Future` is finished.
  when declared(chronosInternalRetFuture):
    chronosInternalRetFuture.internalChild = f
    # `futureContinue` calls the iterator generated by the `async`
    # transformation - `yield` gives control back to `futureContinue` which is
    # responsible for resuming execution once the yielded future is finished
    yield chronosInternalRetFuture.internalChild
    # `child` released by `futureContinue`
    cast[type(f)](chronosInternalRetFuture.internalChild).internalRaiseIfError(f)

    when T isnot void:
      cast[type(f)](chronosInternalRetFuture.internalChild).value()
  else:
    unsupported "await is only available within {.async.}"

template await*[T, E](fut: InternalRaisesFuture[T, E]): T =
  ## Ensure that the given `Future` is finished, then return its value.
  ##
  ## If the `Future` failed or was cancelled, the corresponding exception will
  ## be raised instead.
  ##
  ## If the `Future` is pending, execution of the current `async` procedure
  ## will be suspended until the `Future` is finished.
  when declared(chronosInternalRetFuture):
    chronosInternalRetFuture.internalChild = fut
    # `futureContinue` calls the iterator generated by the `async`
    # transformation - `yield` gives control back to `futureContinue` which is
    # responsible for resuming execution once the yielded future is finished
    yield chronosInternalRetFuture.internalChild
    # `child` released by `futureContinue`
    cast[type(fut)](
      chronosInternalRetFuture.internalChild).internalRaiseIfError(E, fut)

    when T isnot void:
      cast[type(fut)](chronosInternalRetFuture.internalChild).value()
  else:
    unsupported "await is only available within {.async.}"

template awaitne*[T](f: Future[T]): Future[T] =
  when declared(chronosInternalRetFuture):
    chronosInternalRetFuture.internalChild = f
    yield chronosInternalRetFuture.internalChild
    cast[type(f)](chronosInternalRetFuture.internalChild)
  else:
    unsupported "awaitne is only available within {.async.}"

macro async*(params, prc: untyped): untyped =
  ## Macro which processes async procedures into the appropriate
  ## iterators and yield statements.
  if prc.kind == nnkStmtList:
    result = newStmtList()
    for oneProc in prc:
      result.add asyncSingleProc(oneProc, params)
  else:
    result = asyncSingleProc(prc, params)

macro async*(prc: untyped): untyped =
  ## Macro which processes async procedures into the appropriate
  ## iterators and yield statements.

  if prc.kind == nnkStmtList:
    result = newStmtList()
    for oneProc in prc:
      result.add asyncSingleProc(oneProc, nnkTupleConstr.newTree())
  else:
    result = asyncSingleProc(prc, nnkTupleConstr.newTree())
