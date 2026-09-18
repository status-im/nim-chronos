#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

proc take*[T](x: var T): T =
  let res = move(x)
  when T is ref:
    doAssert x == nil
  res
