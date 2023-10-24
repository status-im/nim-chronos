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

proc processBody(node, setResultSym, baseType: NimNode): NimNode {.compileTime.} =
  case node.kind
  of nnkReturnStmt:
    # `return ...` -> `setResult(...); return`
    let
      res = newNimNode(nnkStmtList, node)
    if node[0].kind != nnkEmpty:
      res.add newCall(setResultSym, processBody(node[0], setResultSym, baseType))
    res.add newNimNode(nnkReturnStmt, node).add(newEmptyNode())

    res
  of RoutineNodes-{nnkTemplateDef}:
    # Skip nested routines since they have their own return value distinct from
    # the Future we inject
    node
  else:
    for i in 0 ..< node.len:
      node[i] = processBody(node[i], setResultSym, baseType)
    node

proc wrapInTryFinally(fut, baseType, body, raises: NimNode): NimNode {.compileTime.} =
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

  let raises = if raises == nil:
    const defaultException =
      when defined(chronosStrictException): "CatchableError"
      else: "Exception"
    nnkTupleConstr.newTree(ident(defaultException))
  elif isNoRaises(raises):
    nnkTupleConstr.newTree()
  else:
    raises

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
                  quote do: (ref ValueError)(msg: `excName`.msg, parent: `excName`)))
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
              newCall(ident "complete", fut, ident "result")
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

proc params2(someProc: NimNode): NimNode =
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

proc decodeParams(params: NimNode): tuple[raw: bool, raises: NimNode] =
  # decodes the parameter tuple given in `async: (name: value, ...)` to its
  # recognised parts
  params.expectKind(nnkTupleConstr)

  var
    raw = false
    raises: NimNode = nil

  for param in params:
    param.expectKind(nnkExprColonExpr)

    if param[0].eqIdent("raises"):
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
    else:
      warning("Unrecognised async parameter: " & repr(param[0]), param)

  (raw, raises)

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
    baseTypeIsVoid = baseType.eqIdent("void")
    (raw, raises) = decodeParams(params)
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

  if prc.kind notin {nnkProcTy, nnkLambda}: # TODO: Nim bug?
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

    when chronosDumpAsync:
      echo repr prc

    return prc

  if prc.kind in {nnkProcDef, nnkLambda, nnkMethodDef, nnkDo} and
      not isEmpty(prc.body):
    # don't do anything with forward bodies (empty)
    let
      prcName = prc.name.getName
      setResultSym = ident "setResult"
      procBody = prc.body.processBody(setResultSym, baseType)
      internalFutureSym = ident "chronosInternalRetFuture"
      castFutureSym = nnkCast.newTree(internalFutureType, internalFutureSym)
      resultIdent = ident "result"

      resultDecl = nnkWhenStmt.newTree(
        # when `baseType` is void:
        nnkElifExpr.newTree(
          nnkInfix.newTree(ident "is", baseType, ident "void"),
          quote do:
            template result: auto {.used.} =
              {.fatal: "You should not reference the `result` variable inside" &
                      " a void async proc".}
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

      # generates:
      # template `setResultSym`(code: untyped) {.used.} =
      #   when typeof(code) is void: code
      #   else: `resultIdent` = code
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

      # Wrapping in try/finally ensures that early returns are handled properly
      # and that `defer` is processed in the right scope
      completeDecl = wrapInTryFinally(
        castFutureSym, baseType,
        if baseTypeIsVoid: procBody # shortcut for non-generic `void`
        else: newCall(setResultSym, procBody),
        raises
      )

      closureBody = newStmtList(resultDecl, setResultDecl, completeDecl)

      internalFutureParameter = nnkIdentDefs.newTree(
        internalFutureSym, newIdentNode("FutureBase"), newEmptyNode())
      iteratorNameSym = genSym(nskIterator, $prcName)
      closureIterator = newProc(
        iteratorNameSym,
        [newIdentNode("FutureBase"), internalFutureParameter],
        closureBody, nnkIteratorDef)

      outerProcBody = newNimNode(nnkStmtList, prc.body)

    # Copy comment for nimdoc
    if prc.body.len > 0 and prc.body[0].kind == nnkCommentStmt:
      outerProcBody.add(prc.body[0])

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

    outerProcBody.add(closureIterator)

    # -> let resultFuture = newInternalRaisesFuture[T, E]()
    # declared at the end to be sure that the closure
    # doesn't reference it, avoid cyclic ref (#203)
    let
      retFutureSym = ident "resultFuture"
      newFutProc = if raises == nil:
        newTree(nnkBracketExpr, ident "newFuture", baseType)
      else:
        newTree(nnkBracketExpr, ident "newInternalRaisesFuture", baseType, raises)
    retFutureSym.copyLineInfo(prc)
    # Do not change this code to `quote do` version because `instantiationInfo`
    # will be broken for `newFuture()` call.
    outerProcBody.add(
      newLetStmt(
        retFutureSym,
        newCall(newFutProc, newLit(prcName))
      )
    )
    # -> resultFuture.internalClosure = iterator
    outerProcBody.add(
      newAssignment(
        newDotExpr(retFutureSym, newIdentNode("internalClosure")),
        iteratorNameSym)
    )

    # -> futureContinue(resultFuture))
    outerProcBody.add(
        newCall(newIdentNode("futureContinue"), retFutureSym)
    )

    # -> return resultFuture
    outerProcBody.add newNimNode(nnkReturnStmt, prc.body[^1]).add(retFutureSym)

    prc.body = outerProcBody

  when chronosDumpAsync:
    echo repr prc

  prc

template await*[T](f: Future[T]): untyped =
  when declared(chronosInternalRetFuture):
    chronosInternalRetFuture.internalChild = f
    # `futureContinue` calls the iterator generated by the `async`
    # transformation - `yield` gives control back to `futureContinue` which is
    # responsible for resuming execution once the yielded future is finished
    yield chronosInternalRetFuture.internalChild
    # `child` released by `futureContinue`
    cast[type(f)](chronosInternalRetFuture.internalChild).internalCheckComplete()

    when T isnot void:
      cast[type(f)](chronosInternalRetFuture.internalChild).value()
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
