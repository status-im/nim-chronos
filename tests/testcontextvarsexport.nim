#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Cross-module test for `{.contextVar.}`'s export-marker semantics:
## `let name* {.contextVar.} = v` must produce a key reachable from an
## importing module, while `let name {.contextVar.} = v` (no star) must
## be unreachable by name — and, symmetrically, the raw constructor's
## `private` param must be verified independent of that export marker.
##
## Uses a real second module (`contextvarsexportfixture.nim`) rather than
## same-module `declared()` checks, since visibility only differs across
## module boundaries.

import unittest2
import ../chronos/contextvars  # currentContext, AsyncContext, dumpContext
import ./contextvarsexportfixture

{.used.}

when (NimMajor, NimMinor) >= (2, 0):
  # `{.contextVar.}` is 2.x-only (see contextvarsexportfixture.nim) — the
  # export-marker semantics it's responsible for can only be exercised
  # where the pragma itself exists.
  static:
    doAssert declared(exportedVar),
      "a starred key declared via {.contextVar.} must be reachable from " &
      "an importing module"
    doAssert not declared(privateVar),
      "a non-starred key declared via {.contextVar.} must NOT be " &
      "reachable from an importing module"
    doAssert not declared(setExportedVar),
      "the {.contextVar.} pragma must not generate an imperative setter " &
      "or any other derived identifier — see the one-symbol-emission " &
      "guardrail in testcontextvars.nim"

  suite "contextvars: export marker (cross-module)":

    test "starred key's value/withValue are callable from another module":
      exportedVar.withValue(42):
        check exportedVar.value == 42
      check exportedVar.value == 1

    test "starred key's snapshot access is callable from another module":
      exportedVar.withValue(7):
        let snap = currentContext()
        check snap[exportedVar] == 7

    test "non-starred key is invisible to dumpContext from an importing module":
      # privateVar is registered (if at all) from contextvarsexportfixture.nim,
      # not here — the module-private contract requires it to be absent from
      # this module's dumpContext output too, not just unreachable by name.
      let entries = dumpContext(currentContext())
      for e in entries:
        check e.name != "privateVar"

    test "starred key IS visible to dumpContext from an importing module":
      # Control: proves the check above isn't vacuous (registration works
      # at all across the module boundary for the starred sibling key).
      let entries = dumpContext(currentContext())
      var found = false
      for e in entries:
        if e.name == "exportedVar":
          found = true
      check found

static:
  doAssert not declared(rawUnexportedRegistered),
    "an unexported raw-constructed key must not be reachable by name " &
    "from an importing module either — Nim's own export rules govern " &
    "reachability regardless of the constructor's `private` argument"

suite "contextvars: raw-constructor privacy decoupling (cross-module)":

  test "unexported raw-constructed key registered with private=false still appears in another module's dumpContext":
    # The export-decoupling negative case, pinned as intentional: the
    # raw constructor's `private` param is an ordinary value argument,
    # entirely decoupled from the enclosing `let`'s own export marker.
    # See docs/src/contextvars.md, "Privacy and the raw constructor".
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "rawUnexportedRegistered":
        found = true
    check found
