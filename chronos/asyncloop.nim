#
#                     Chronos
#
#           (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

import ./internal/[asyncengine, asyncfutures, asyncmacro, errors]

when defined(windows):
  # `asyncengine.nim`'s `captureContextInto(var CompletionData)`
  # overload is exported for `stream.nim`'s accept-loop registration
  # sites to use, but must not flow past this module — same
  # unnameability discipline as `CompletionData.context` itself, whose
  # privacy this overload exists to preserve.
  export asyncfutures, errors
  export asyncengine except captureContextInto
else:
  export asyncfutures, asyncengine, errors
export asyncmacro.async, asyncmacro.await, asyncmacro.awaitne
