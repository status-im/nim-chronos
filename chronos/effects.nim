# Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
type
  NestedPoll* = object of RootEffect
    ## Nested poll calls are those where `poll` (or `waitFor`) is called from
    ## within the call stack of another `poll` call - this can happen if
    ## a call scheduled with `callSoon` gets called as part of event loop
    ## processing, as happens with async continuations.
    ##
    ## Such nested calls are undefined behavior since they re-enter the event
    ## loop and cause events to be handled out of order with respect to how
    ## they are polled from the operating system.
    ##
    ## When deeply nested, it can also quickly exhaust available stack space and
    ## cause other forms of undefined behavior.
    ##
    ## The nested poll effect helps prevent obvious cases of `poll` being called
    ## inside `async` functions, though not all such calls can be detected at
    ## compile time currently.
