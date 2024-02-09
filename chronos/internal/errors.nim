type
  AsyncError* = object of CatchableError ## Generic async exception
  AsyncTimeoutError* = object of AsyncError ## Timeout exception

  AsyncExceptionError* = object of AsyncError
    ## Error raised in `handleException` mode - the original exception is
    ## available from the `parent` field.
