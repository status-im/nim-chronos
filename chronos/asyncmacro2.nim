#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[macros]

proc skipUntilStmtList(node: NimNode): NimNode {.compileTime.} =
  # Skips a nest of StmtList's.
  result = node
  if node[0].kind == nnkStmtList:
    result = skipUntilStmtList(node[0])

proc processBody(node, retFutureSym: NimNode,
                 subTypeIsVoid: bool): NimNode {.compileTime.} =
  #echo(node.treeRepr)
  result = node
  case node.kind
  of nnkReturnStmt:
    result = newNimNode(nnkStmtList, node)

    # As I've painfully found out, the order here really DOES matter.
    if node[0].kind == nnkEmpty:
      if not subTypeIsVoid:
        result.add newCall(newIdentNode("complete"), retFutureSym,
            newIdentNode("result"))
      else:
        result.add newCall(newIdentNode("complete"), retFutureSym)
    else:
      let x = node[0].processBody(retFutureSym, subTypeIsVoid)
      if x.kind == nnkYieldStmt: result.add x
      else:
        result.add newCall(newIdentNode("complete"), retFutureSym, x)

    result.add newNimNode(nnkReturnStmt, node).add(newNilLit())
    return # Don't process the children of this return stmt
  of RoutineNodes-{nnkTemplateDef}:
    # skip all the nested procedure definitions
    return node
  else: discard

  for i in 0 ..< result.len:
    # We must not transform nested procedures of any form, otherwise
    # `retFutureSym` will be used for all nested procedures as their own
    # `retFuture`.
    result[i] = processBody(result[i], retFutureSym, subTypeIsVoid)

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

proc isInvalidReturnType(typeName: string): bool =
  return typeName notin ["Future"] #, "FutureStream"]

proc verifyReturnType(typeName: string) {.compileTime.} =
  if typeName.isInvalidReturnType:
    error("Expected return type of 'Future' got '" & typeName & "'")

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
            " proc/method definition or lambda node expected.")

  let returnType = cleanupOpenSymChoice(prc.params2[0])

  # Verify that the return type is a Future[T]
  let baseType =
    if returnType.kind == nnkBracketExpr:
      let fut = repr(returnType[0])
      verifyReturnType(fut)
      returnType[1]
    elif returnType.kind == nnkEmpty:
      ident("void")
    else:
      raiseAssert("Unhandled async return type: " & $prc.kind)

  let subtypeIsVoid = baseType.eqIdent("void")

  if prc.kind in {nnkProcDef, nnkLambda, nnkMethodDef, nnkDo}:
    let
      prcName = prc.name.getName
      outerProcBody = newNimNode(nnkStmtList, prc.body)

    # Copy comment for nimdoc
    if prc.body.len > 0 and prc.body[0].kind == nnkCommentStmt:
      outerProcBody.add(prc.body[0])

    # -> iterator nameIter(chronosInternalRetFuture: Future[T]): FutureBase {.closure.} =
    # ->   {.push warning[resultshadowed]: off.}
    # ->   var result: T
    # ->   {.pop.}
    # ->   <proc_body>
    # ->   complete(chronosInternalRetFuture, result)
    let
      internalFutureSym = ident "chronosInternalRetFuture"
      iteratorNameSym = genSym(nskIterator, $prcName)
    var
      procBody = prc.body.processBody(internalFutureSym, subtypeIsVoid)

    # don't do anything with forward bodies (empty)
    if procBody.kind != nnkEmpty:
      if subtypeIsVoid:
        let resultTemplate = quote do:
          template result: auto {.used.} =
            {.fatal: "You should not reference the `result` variable inside" &
                    " a void async proc".}
        procBody = newStmtList(resultTemplate, procBody)

      # fix #13899, `defer` should not escape its original scope
      procBody = newStmtList(newTree(nnkBlockStmt, newEmptyNode(), procBody))

      if not subtypeIsVoid:
        procBody.insert(0, newNimNode(nnkPragma).add(newIdentNode("push"),
          newNimNode(nnkExprColonExpr).add(newNimNode(nnkBracketExpr).add(
            newIdentNode("warning"), newIdentNode("resultshadowed")),
          newIdentNode("off")))) # -> {.push warning[resultshadowed]: off.}

        procBody.insert(1, newNimNode(nnkVarSection, prc.body).add(
          newIdentDefs(newIdentNode("result"), baseType))) # -> var result: T

        procBody.insert(2, newNimNode(nnkPragma).add(
          newIdentNode("pop"))) # -> {.pop.})

        procBody.add(
          newCall(newIdentNode("complete"),
            internalFutureSym, newIdentNode("result"))) # -> complete(chronosInternalRetFuture, result)
      else:
        # -> complete(chronosInternalRetFuture)
        procBody.add(newCall(newIdentNode("complete"), internalFutureSym))

      let
        internalFutureType =
          if subtypeIsVoid:
            newNimNode(nnkBracketExpr, prc).add(newIdentNode("Future")).add(newIdentNode("void"))
          else: returnType
        internalFutureParameter = nnkIdentDefs.newTree(internalFutureSym, internalFutureType, newEmptyNode())
        closureIterator = newProc(iteratorNameSym, [newIdentNode("FutureBase"), internalFutureParameter],
                                  procBody, nnkIteratorDef)

      closureIterator.pragma = newNimNode(nnkPragma, lineInfoFrom=prc.body)
      closureIterator.addPragma(newIdentNode("closure"))
      # **Remark 435**: We generate a proc with an inner iterator which call each other
      # recursively. The current Nim compiler is not smart enough to infer
      # the `gcsafe`-ty aspect of this setup, so we always annotate it explicitly
      # with `gcsafe`. This means that the client code is always enforced to be
      # `gcsafe`. This is still **safe**, the compiler still checks for `gcsafe`-ty
      # regardless, it is only helping the compiler's inference algorithm. See
      # https://github.com/nim-lang/RFCs/issues/435
      # for more details.
      closureIterator.addPragma(newIdentNode("gcsafe"))

      # TODO when push raises is active in a module, the iterator here inherits
      #      that annotation - here we explicitly disable it again which goes
      #      against the spirit of the raises annotation - one should investigate
      #      here the possibility of transporting more specific error types here
      #      for example by casting exceptions coming out of `await`..
      let raises = nnkBracket.newTree()
      when chronosStrictException:
        raises.add(newIdentNode("CatchableError"))
        when (NimMajor, NimMinor) < (1, 4):
          raises.add(newIdentNode("Defect"))
      else:
        raises.add(newIdentNode("Exception"))

      closureIterator.addPragma(nnkExprColonExpr.newTree(
        newIdentNode("raises"),
        raises
      ))

      # If proc has an explicit gcsafe pragma, we add it to iterator as well.
      if prc.pragma.findChild(it.kind in {nnkSym, nnkIdent} and
                              it.strVal == "gcsafe") != nil:
        closureIterator.addPragma(newIdentNode("gcsafe"))
      outerProcBody.add(closureIterator)

      # -> var resultFuture = newFuture[T]()
      # declared at the end to be sure that the closure
      # doesn't reference it, avoid cyclic ref (#203)
      var retFutureSym = ident "resultFuture"
      var subRetType =
        if returnType.kind == nnkEmpty:
          newIdentNode("void")
        else:
          baseType
      # Do not change this code to `quote do` version because `instantiationInfo`
      # will be broken for `newFuture()` call.
      outerProcBody.add(
        newVarStmt(
          retFutureSym,
          newCall(newTree(nnkBracketExpr, ident "newFuture", subRetType),
                  newLit(prcName))
        )
      )

      # -> resultFuture.closure = iterator
      outerProcBody.add(
        newAssignment(
          newDotExpr(retFutureSym, newIdentNode("closure")),
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

  let raises = nnkBracket.newTree()
  when (NimMajor, NimMinor) < (1, 4):
    raises.add(newIdentNode("Defect"))
  prc.addPragma(nnkExprColonExpr.newTree(
    newIdentNode("raises"),
    raises
  ))

  if subtypeIsVoid:
    # Add discardable pragma.
    if returnType.kind == nnkEmpty:
      # Add Future[void]
      prc.params2[0] =
        newNimNode(nnkBracketExpr, prc)
        .add(newIdentNode("Future"))
        .add(newIdentNode("void"))

  prc

template await*[T](f: Future[T]): untyped =
  when declared(chronosInternalRetFuture):
    #work around https://github.com/nim-lang/Nim/issues/19193
    when not declaredInScope(chronosInternalTmpFuture):
      var chronosInternalTmpFuture {.inject.}: FutureBase = f
    else:
      chronosInternalTmpFuture = f
    chronosInternalRetFuture.child = chronosInternalTmpFuture

    # This "yield" is meant for a closure iterator in the caller.
    yield chronosInternalTmpFuture

    # By the time we get control back here, we're guaranteed that the Future we
    # just yielded has been completed (success, failure or cancellation),
    # through a very complicated mechanism in which the caller proc (a regular
    # closure) adds itself as a callback to chronosInternalTmpFuture.
    #
    # Callbacks are called only after completion and a copy of the closure
    # iterator that calls this template is still in that callback's closure
    # environment. That's where control actually gets back to us.

    chronosInternalRetFuture.child = nil
    if chronosInternalRetFuture.mustCancel:
      raise newCancelledError()
    chronosInternalTmpFuture.internalCheckComplete()
    when T isnot void:
      cast[type(f)](chronosInternalTmpFuture).internalRead()
  else:
    unsupported "await is only available within {.async.}"

template awaitne*[T](f: Future[T]): Future[T] =
  when declared(chronosInternalRetFuture):
    #work around https://github.com/nim-lang/Nim/issues/19193
    when not declaredInScope(chronosInternalTmpFuture):
      var chronosInternalTmpFuture {.inject.}: FutureBase = f
    else:
      chronosInternalTmpFuture = f
    chronosInternalRetFuture.child = chronosInternalTmpFuture
    yield chronosInternalTmpFuture
    chronosInternalRetFuture.child = nil
    if chronosInternalRetFuture.mustCancel:
      raise newCancelledError()
    cast[type(f)](chronosInternalTmpFuture)
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
