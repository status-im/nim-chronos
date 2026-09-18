#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

proc take*[T](x: var T): T {.noinit.} =
  result = move(x)
  reset(x)  # `Move` may not always reset (e.g., local var still in use after)
