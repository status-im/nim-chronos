#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2025 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Base type of the continuation-local binding chain — split into its own
## dependency-free leaf module so `chronos/futures.nim` can import it (for
## `InternalAsyncCallback`'s `context` field type) without exporting it.
##
## The `next` field is private to this module: chain nodes are
## constructed only by the public contextvars layer's binder, and a
## public field would let user code link a node into a cycle. Keeping
## it private confines chain mutation to `linkNode` below.

{.push raises: [].}

type
  ContextNodeBase* = ref object of RootObj
    ## Base of the per-task continuation-local binding chain. The public
    ## contextvars layer layers keyed nodes on this base — a
    ## non-generic subtype carrying the owning key's identity and a
    ## generic subtype adding the bound `value: T` — so the chain is
    ## heterogeneous in value type and the lookup walk compares key
    ## identities to find the right node.
    next: ContextNodeBase
      ## Private — read via `nextNode`, written via `linkNode` only.

func nextNode*(node: ContextNodeBase): ContextNodeBase {.inline.} =
  ## Read-only chain traversal for the lookup walk in
  ## the public contextvars layer.
  node.next

proc linkNode*(node, prev: ContextNodeBase) {.inline.} =
  ## Link a freshly-constructed binding node to the chain head it is
  ## about to shadow. Call exactly once per node, before the node is
  ## published as the new chain head.
  node.next = prev
