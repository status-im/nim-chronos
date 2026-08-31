#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## The one-way `chronosDebug` construction lock for `newContextVar`
## (chronos/contextvars.nim, `lockContextVarConstruction()`), split into
## its own file so that its permanent, process-lifetime lock doesn't
## impose an import order on the other contextvars test files: every
## other file constructs keys at runtime and would hit the lock if it
## ran after this one in the same binary. Not imported from
## tests/testall.nim for the same reason — the lock must not be live for
## any other suite in that binary. In CI,
## tests/testcontextvarsstandalone.nim's orchestrate mode gives this
## suite its own process, so the lock's one-way nature can no longer
## affect another suite; import order only matters for the driver's
## no-args single-process mode, where this file must still run last.
##
## `when defined(chronosDebug)` guards the lock itself, mirroring
## tests/testcontextvarsbalance.nim: this file compiles on every leg but
## is only meaningful on the `chronosDebug` ones.

import unittest2
import ../chronos/contextvars

{.used.}

const contextVarsLockSuiteName* =
  "contextvars (raw key): chronosDebug construction lock"

suite contextVarsLockSuiteName:

  test "newContextVar after lockContextVarConstruction() asserts":
    when defined(chronosDebug):
      lockContextVarConstruction()
      expect AssertionDefect:
        discard newContextVar("afterLock", 1)
    else:
      skip()
