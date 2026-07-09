# Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
type
  NestedPoll* = object of RootEffect
    ## Nested poll calls can lead to stack space getting exhausted as well as other
    ## kinds of undefined behavior - the event loop needs to run at top-level
    ## and cannot be called recursively from within tasks - this is enforced
    ## via `.forbids`
