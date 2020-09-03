type
  SrcLoc* = object
    procedure*: cstring
    file*: cstring
    line*: int

proc `$`*(loc: ptr SrcLoc): string =
  result.add loc.file
  result.add "("
  result.add $loc.line
  result.add ")"
  result.add "    "
  if len(loc.procedure) == 0:
    result.add "[unspecified]"
  else:
    result.add loc.procedure

proc srcLocImpl(procedure: static string,
                file: static string, line: static int): ptr SrcLoc =
  var loc {.global.} = SrcLoc(
    file: cstring(file), line: line, procedure: procedure
  )
  return addr(loc)

template getSrcLocation*(procedure: static string = "",
                         callerAt = -2): ptr SrcLoc =
  srcLocImpl(procedure,
             instantiationInfo(callerAt).filename,
             instantiationInfo(callerAt).line)
