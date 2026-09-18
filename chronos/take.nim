#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

when defined(release):
  template take*[T](x: var T): T =
    move(x)
else:
  proc take*[T](x: var T): T =
    let res =
      when defined(nimHasEnsureMove):
        ensureMove(x)
      else:
        move(x)
    doAssert x == default(typeof(x))
    res
