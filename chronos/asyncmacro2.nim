#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[macros, algorithm]

proc processBody(node, retFutureSym: NimNode,
                 subTypeIsVoid: bool): NimNode {.compileTime.} =
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

proc verifyReturnType(typeName: string) {.compileTime.} =
  if typeName notin ["Future", "RaiseTrackingFuture"]: #, "FutureStream"]
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

template emptyRaises: NimNode =
  when (NimMajor, NimMinor) < (1, 4):
    nnkBracket.newTree(newIdentNode("Defect"))
  else:
    nnkBracket.newTree()

proc getBaseType(prc: NimNode): NimNode {.compileTime.} =
  if prc.kind notin {nnkProcDef, nnkLambda, nnkMethodDef, nnkDo, nnkProcTy}:
      error("Cannot transform this node kind into an async proc." &
            " proc/method definition or lambda node expected.")

  let returnType = cleanupOpenSymChoice(prc.params2[0])

  # Verify that the return type is a Future[T]
  # and extract the BaseType from it
  if returnType.kind == nnkBracketExpr:
    let fut = repr(returnType[0])
    verifyReturnType(fut)
    returnType[1]
  elif returnType.kind == nnkEmpty:
    ident("void")
  else:
    error("Unhandled async return type: " & $prc.kind)
    # error isn't noreturn..
    return

proc combineAsyncExceptionsHelper(args: NimNode): seq[NimNode] =
  for argRaw in args:
    let arg = getTypeInst(argRaw)
    if arg.kind == nnkBracketExpr and arg[0].eqIdent("typeDesc"):
      if arg[1].kind == nnkSym:
        result.add(ident(arg[1].strVal))
      elif arg[1].kind == nnkTupleConstr:
        for subArg in arg[1]:
          result.add(ident(subArg.strVal))
      else:
        error("Unhandled exception subarg source" & $arg[1].kind)
    else:
      error("Unhandled exception source" & $arg.kind)

macro combineAsyncExceptions*(args: varargs[typed]): untyped =
  result = nnkTupleConstr.newTree()
  for argRaw in combineAsyncExceptionsHelper(args):
    result.add(argRaw)

macro asyncinternalraises*(prc, exceptions: typed): untyped =
  let closureRaises = nnkBracket.newNimNode()
  for argRaw in combineAsyncExceptionsHelper(exceptions):
    closureRaises.add(argRaw)

  prc.addPragma(nnkExprColonExpr.newTree(
      newIdentNode("raises"),
      closureRaises
    ))

  prc

proc asyncSingleProc(prc: NimNode): NimNode {.compileTime.} =
  ## This macro transforms a single procedure into a closure iterator.
  ## The ``async`` macro supports a stmtList holding multiple async procedures.

  let
    baseType = getBaseType(prc)
    subtypeIsVoid = baseType.eqIdent("void")

  var
    raisesTuple = nnkTupleConstr.newTree()
    foundRaises = -1
    foundRaisesOf = -1
    foundAsync = -1

  for index, pragma in pragma(prc):
    if pragma.kind == nnkExprColonExpr and pragma[0] == ident "asyncraises":
      foundRaises = index
    elif pragma.kind == nnkExprColonExpr and pragma[0] == ident "asyncraisesof":
      foundRaisesOf = index
    elif pragma.eqIdent("async"):
      foundAsync = index
    elif pragma.kind == nnkExprColonExpr and pragma[0] == ident "raises":
      warning("The raises pragma doesn't work on async procedure. " &
        "Please remove it or use asyncraises instead")

  if foundRaises >= 0:
    for possibleRaise in pragma(prc)[foundRaises][1]:
      raisesTuple.add(possibleRaise)
    if raisesTuple.len == 0:
      raisesTuple = ident("void")
  else:
    when defined(chronosWarnMissingRaises):
      warning("Async proc miss asyncraises")

    const defaultException =
      when defined(chronosStrictException): "CatchableError"
      else: "Exception"
    raisesTuple.add(ident(defaultException))


  var genericErrorTypes: seq[NimNode]
  var resultTypeSetter: NimNode
  if foundRaisesOf >= 0:

    if prc[2].kind == nnkEmpty:
      prc[2] = nnkGenericParams.newTree()
    prc.params2[0] = ident"auto"

    for index, raisesOf in pragma(prc)[foundRaisesOf][1]:
      let prcParams = params2(prc)
      for index, param in prcParams:
        if index == 0: continue # return type

        if param[0].eqIdent(raisesOf):
          if param[1].kind != nnkBracketExpr or (param[1][0].eqIdent("Future") == false):
            error "asyncraisesof only applies to Future parameters"
          param[1][0] = ident"RaiseTrackingFuture"

          let genericSym = genSym(kind=nskGenericParam, ident="Err" & $index)
          genericErrorTypes.add(genericSym)
          prc[2].add nnkIdentDefs.newTree(
            genericSym,
            newEmptyNode(),
            newEmptyNode()
          )
          param[1].add(genericSym)

      let macroCall = newCall("combineAsyncExceptions")
      for a in raisesTuple: macroCall.add(a)
      for a in genericErrorTypes: macroCall.add(ident(a.strVal))
      resultTypeSetter =
        newAssignment(
          ident"result",
          newCall(
            nnkBracketExpr.newTree(
              ident"RaiseTrackingFuture",
              baseType,
              macroCall),
            newNilLit()
          )
        )
    if prc.body.kind != nnkEmpty and foundAsync < 0:
      prc.body.insert(0, resultTypeSetter)
  elif foundRaises >= 0:
    # Rewrite to RaiseTrackingFuture
    prc.params2[0] = nnkBracketExpr.newTree(
      newIdentNode("RaiseTrackingFuture"),
      baseType,
      raisesTuple
    )
  elif subtypeIsVoid:
    # Rewrite the implicit Future[void]
    prc.params2[0] =
        newNimNode(nnkBracketExpr, prc).
          add(newIdentNode("Future")).
          add(newIdentNode("void"))

  # Remove pragmas
  let toRemoveList = @[foundRaises, foundAsync, foundRaisesOf].filterIt(it >= 0).sorted().reversed()
  for toRemove in toRemoveList:
    pragma(prc).del(toRemove)

  if prc.kind != nnkLambda and prc.kind != nnkProcTy: # TODO: Nim bug?
    prc.addPragma(newColonExpr(ident "stackTrace", ident "off"))

  # The proc itself can't raise
  prc.addPragma(nnkExprColonExpr.newTree(
    newIdentNode("raises"),
    emptyRaises))

  # See **Remark 435** in this file.
  # https://github.com/nim-lang/RFCs/issues/435
  prc.addPragma(newIdentNode("gcsafe"))

  if foundAsync < 0:
    return prc

  # Transform to closure iter
  var outerProcBody = newNimNode(nnkStmtList, prc)
  # Copy comment for nimdoc
  if prc.body.len > 0 and prc.body[0].kind == nnkCommentStmt:
    outerProcBody.add(prc.body[0])

  # -> iterator nameIter(chronosInternalRetFuture: Future[T]): FutureBase {.closure.} =
  # ->   {.push warning[resultshadowed]: off.}
  # ->   var result: T
  # ->   {.pop.}
  # ->   <proc_body>
  # ->   complete(chronosInternalRetFuture, result)
  let internalFutureSym = ident "chronosInternalRetFuture"
  var procBody =
    if prc.kind == nnkProcTy: newNimNode(nnkEmpty)
    else: prc.body.processBody(internalFutureSym, subtypeIsVoid)
  # don't do anything with forward bodies (empty)
  if procBody.kind != nnkEmpty:
    let prcName = prc.name.getName
    var iteratorNameSym = genSym(nskIterator, $prcName)
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

    let internalFutureParameter =
      nnkIdentDefs.newTree(
        internalFutureSym,
        newNimNode(nnkBracketExpr, prc).add(newIdentNode("Future")).add(baseType),
        newEmptyNode())
    var closureIterator = newProc(iteratorNameSym, [newIdentNode("FutureBase"), internalFutureParameter],
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

    let closureRaises = nnkBracket.newNimNode()
    for exception in raisesTuple:
      closureRaises.add(exception)

    when (NimMajor, NimMinor) < (1, 4):
      closureRaises.add(ident("Defect"))

    # If proc has an explicit gcsafe pragma, we add it to iterator as well.
    if prc.pragma.findChild(it.kind in {nnkSym, nnkIdent} and
                            it.strVal == "gcsafe") != nil:
      closureIterator.addPragma(newIdentNode("gcsafe"))

    if foundRaisesOf < 0:
      closureIterator.addPragma(nnkExprColonExpr.newTree(
        newIdentNode("raises"),
        closureRaises
      ))
    else:
      for a in genericErrorTypes: closureRaises.add(ident(a.strVal))
      closureIterator = newCall("asyncinternalraises", closureIterator, closureRaises)

    outerProcBody.add(closureIterator)

    # -> var resultFuture = newRaiseTrackingFuture[T]()
    # declared at the end to be sure that the closure
    # doesn't reference it, avoid cyclic ref (#203)
    var retFutureSym = ident "resultFuture"
    # Do not change this code to `quote do` version because `instantiationInfo`
    # will be broken for `newFuture()` call.
    if not isNil(resultTypeSetter):
      outerProcBody.add(resultTypeSetter)
    outerProcBody.add(
      newVarStmt(
        retFutureSym,
        newCall(newTree(nnkBracketExpr, ident "newRaiseTrackingFuture", baseType),
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

  result = prc

  if procBody.kind != nnkEmpty:
    result.body = outerProcBody

  when defined(nimDumpAsync):
    echo repr result

macro checkFutureExceptions*(f, typ: typed): untyped =
  # For RaiseTrackingFuture[void, (ValueError, OSError), will do:
  # if isNil(f.error): discard
  # elif f.error of type ValueError: raise (ref ValueError)(f.error)
  # elif f.error of type OSError: raise (ref OSError)(f.error)
  # else: raiseAssert("Unhandled future exception: " & f.error.msg)
  #
  # In future nim versions, this could simply be
  # {.cast(raises: [ValueError, OSError]).}:
  #   raise f.error
  let e = getTypeInst(typ)[2]
  let types = getType(e)

  if types.eqIdent("void"):
    return quote do:
      if not(isNil(`f`.error)):
        raiseAssert("Unhandled future exception: " & `f`.error.msg)

  expectKind(types, nnkBracketExpr)
  expectKind(types[0], nnkSym)
  assert types[0].strVal == "tuple"
  assert types.len > 1

  result = nnkIfExpr.newTree(
    nnkElifExpr.newTree(
      quote do: isNil(`f`.error),
      quote do: discard
    )
  )

  for errorType in types[1..^1]:
    result.add nnkElifExpr.newTree(
      quote do: `f`.error of type `errorType`,
      nnkRaiseStmt.newNimNode(lineInfoFrom=typ).add(
        quote do: (ref `errorType`)(`f`.error)
      )
    )

  result.add nnkElseExpr.newTree(
    quote do: raiseAssert("Unhandled future exception: " & `f`.error.msg)
  )

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
    when f is RaiseTrackingFuture:
      checkFutureExceptions(chronosInternalTmpFuture, f)
    else:
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
      oneProc.addPragma(ident"async")
      result.add asyncSingleProc(oneProc)
  else:
    prc.addPragma(ident"async")
    result = asyncSingleProc(prc)

macro asyncraises*(possibleExceptions, prc: untyped): untyped =
  # Add back the pragma and let asyncSingleProc handle it
  if prc.kind == nnkStmtList:
    result = newStmtList()
    for oneProc in prc:
      oneProc.addPragma(nnkExprColonExpr.newTree(
        ident"asyncraises",
        possibleExceptions
      ))
      result.add asyncSingleProc(oneProc)
  else:
    prc.addPragma(nnkExprColonExpr.newTree(
      ident"asyncraises",
      possibleExceptions
    ))
    result = asyncSingleProc(prc)

macro asyncraisesof*(raisesof, prc: untyped): untyped =
  # Add back the pragma and let asyncSingleProc handle it
  if prc.kind == nnkStmtList:
    result = newStmtList()
    for oneProc in prc:
      oneProc.addPragma(nnkExprColonExpr.newTree(
        ident"asyncraisesof",
        raisesof
      ))
      result.add asyncSingleProc(oneProc)
  else:
    prc.addPragma(nnkExprColonExpr.newTree(
      ident"asyncraisesof",
      raisesof
    ))
    result = asyncSingleProc(prc)
