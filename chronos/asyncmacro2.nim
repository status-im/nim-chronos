#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[macros]

# `quote do` will ruin line numbers so we avoid it using these helpers
proc completeWithResult(fut, baseType: NimNode): NimNode {.compileTime.} =
  # when `baseType` is void:
  #   complete(`fut`)
  # else:
  #   complete(`fut`, result)
  if baseType.eqIdent("void"):
    # Shortcut if we know baseType at macro expansion time
    newCall(ident "complete", fut)
  else:
    # `baseType` might be generic and resolve to `void`
    nnkWhenStmt.newTree(
      nnkElifExpr.newTree(
        nnkInfix.newTree(ident "is", baseType, ident "void"),
        newCall(ident "complete", fut)
      ),
      nnkElseExpr.newTree(
        newCall(ident "complete", fut, ident "result")
      )
    )

proc completeWithNode(fut, baseType, node: NimNode): NimNode {.compileTime.} =
  #   when typeof(`node`) is void:
  #     `node` # statement / explicit return
  #     -> completeWithResult(fut, baseType)
  #   else: # expression / implicit return
  #     complete(`fut`, `node`)
  if node.kind == nnkEmpty: # shortcut when known at macro expanstion time
    completeWithResult(fut, baseType)
  else:
    # Handle both expressions and statements - since the type is not know at
    # macro expansion time, we delegate this choice to a later compilation stage
    # with `when`.
    nnkWhenStmt.newTree(
      nnkElifExpr.newTree(
        nnkInfix.newTree(
          ident "is", nnkTypeOfExpr.newTree(node), ident "void"),
        newStmtList(
          node,
          completeWithResult(fut, baseType)
        )
      ),
      nnkElseExpr.newTree(
        newCall(ident "complete", fut, node)
      )
    )

proc processBody(node, fut, baseType: NimNode): NimNode {.compileTime.} =
  #echo(node.treeRepr)
  case node.kind
  of nnkReturnStmt:
    let
      res = newNimNode(nnkStmtList, node)
    res.add completeWithNode(fut, baseType, processBody(node[0], fut, baseType))
    res.add newNimNode(nnkReturnStmt, node).add(newNilLit())

    res
  of RoutineNodes-{nnkTemplateDef}:
    # skip all the nested procedure definitions
    node
  else:
    for i in 0 ..< node.len:
      # We must not transform nested procedures of any form, otherwise
      # `fut` will be used for all nested procedures as their own
      # `retFuture`.
      node[i] = processBody(node[i], fut, baseType)
    node

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

proc asyncSingleProc(prc: NimNode): NimNode {.compileTime.} =
  ## This macro transforms a single procedure into a closure iterator.
  ## The ``async`` macro supports a stmtList holding multiple async procedures.
  if prc.kind notin {nnkProcTy, nnkProcDef, nnkLambda, nnkMethodDef, nnkDo}:
      error("Cannot transform " & $prc.kind & " into an async proc." &
            " proc/method definition or lambda node expected.", prc)

  let returnType = cleanupOpenSymChoice(prc.params2[0])

  # Verify that the return type is a Future[T]
  let baseType =
    if returnType.kind == nnkEmpty:
      ident "void"
    elif not (
        returnType.kind == nnkBracketExpr and eqIdent(returnType[0], "Future")):
      error(
        "Expected return type of 'Future' got '" & repr(returnType) & "'", prc)
      return
    else:
      returnType[1]

  let
    baseTypeIsVoid = baseType.eqIdent("void")
    futureVoidType = nnkBracketExpr.newTree(ident "Future", ident "void")

  if prc.kind in {nnkProcDef, nnkLambda, nnkMethodDef, nnkDo}:
    let
      prcName = prc.name.getName
      outerProcBody = newNimNode(nnkStmtList, prc.body)

    # Copy comment for nimdoc
    if prc.body.len > 0 and prc.body[0].kind == nnkCommentStmt:
      outerProcBody.add(prc.body[0])

    let
      internalFutureSym = ident "chronosInternalRetFuture"
      internalFutureType =
        if baseTypeIsVoid: futureVoidType
        else: returnType
      castFutureSym = nnkCast.newTree(internalFutureType, internalFutureSym)

      procBody = prc.body.processBody(castFutureSym, baseType)

    # don't do anything with forward bodies (empty)
    if procBody.kind != nnkEmpty:
      let
        # fix #13899, `defer` should not escape its original scope
        procBodyBlck = nnkBlockStmt.newTree(newEmptyNode(), procBody)

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
                  ident "result",
                  nnkPragma.newTree(ident "used")),
                baseType, newEmptyNode())
                ),
              quote do: {.pop.},
            )
          )
        )

        completeDecl = completeWithNode(castFutureSym, baseType, procBodyBlck)

        closureBody = newStmtList(resultDecl, completeDecl)

        internalFutureParameter = nnkIdentDefs.newTree(
          internalFutureSym, newIdentNode("FutureBase"), newEmptyNode())
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

      # TODO when push raises is active in a module, the iterator here inherits
      #      that annotation - here we explicitly disable it again which goes
      #      against the spirit of the raises annotation - one should investigate
      #      here the possibility of transporting more specific error types here
      #      for example by casting exceptions coming out of `await`..
      let raises = nnkBracket.newTree()
      when chronosStrictException:
        raises.add(newIdentNode("CatchableError"))
      else:
        raises.add(newIdentNode("Exception"))

      closureIterator.addPragma(nnkExprColonExpr.newTree(
        newIdentNode("raises"),
        raises
      ))

      # If proc has an explicit gcsafe pragma, we add it to iterator as well.
      # TODO if these lines are not here, srcloc tests fail (!)
      if prc.pragma.findChild(it.kind in {nnkSym, nnkIdent} and
                              it.strVal == "gcsafe") != nil:
        closureIterator.addPragma(newIdentNode("gcsafe"))

      outerProcBody.add(closureIterator)

      # -> let resultFuture = newFuture[T]()
      # declared at the end to be sure that the closure
      # doesn't reference it, avoid cyclic ref (#203)
      let
        retFutureSym = ident "resultFuture"
      retFutureSym.copyLineInfo(prc)
      # Do not change this code to `quote do` version because `instantiationInfo`
      # will be broken for `newFuture()` call.
      outerProcBody.add(
        newLetStmt(
          retFutureSym,
          newCall(newTree(nnkBracketExpr, ident "newFuture", baseType),
                  newLit(prcName))
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

  if prc.kind notin {nnkProcTy, nnkLambda}: # TODO: Nim bug?
    prc.addPragma(newColonExpr(ident "stackTrace", ident "off"))

  # See **Remark 435** in this file.
  # https://github.com/nim-lang/RFCs/issues/435
  prc.addPragma(newIdentNode("gcsafe"))

  prc.addPragma(nnkExprColonExpr.newTree(
    newIdentNode("raises"),
    nnkBracket.newTree()
  ))

  if baseTypeIsVoid:
    if returnType.kind == nnkEmpty:
      # Add Future[void]
      prc.params2[0] = futureVoidType

  prc

template await*[T](f: Future[T]): untyped =
  when declared(chronosInternalRetFuture):
    chronosInternalRetFuture.internalChild = f
    # `futureContinue` calls the iterator generated by the `async`
    # transformation - `yield` gives control back to `futureContinue` which is
    # responsible for resuming execution once the yielded future is finished
    yield chronosInternalRetFuture.internalChild

    # `child` is guaranteed to have been `finished` after the yield
    if chronosInternalRetFuture.internalMustCancel:
      raise newCancelledError()

    # `child` released by `futureContinue`
    chronosInternalRetFuture.internalChild.internalCheckComplete()
    when T isnot void:
      cast[type(f)](chronosInternalRetFuture.internalChild).internalRead()
  else:
    unsupported "await is only available within {.async.}"

template awaitne*[T](f: Future[T]): Future[T] =
  when declared(chronosInternalRetFuture):
    chronosInternalRetFuture.internalChild = f
    yield chronosInternalRetFuture.internalChild
    if chronosInternalRetFuture.internalMustCancel:
      raise newCancelledError()
    cast[type(f)](chronosInternalRetFuture.internalChild)
  else:
    unsupported "awaitne is only available within {.async.}"

macro async*(prc: untyped): untyped =
  ## Macro which processes async procedures into the appropriate
  ## iterators and yield statements.
  if prc.kind == nnkStmtList:
    result = newStmtList()
    for oneProc in prc:
      result.add asyncSingleProc(oneProc)
  else:
    result = asyncSingleProc(prc)
  when chronosDumpAsync:
    echo repr result
