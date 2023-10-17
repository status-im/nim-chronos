type
  AsyncError* = object of CatchableError
    ## Generic async exception
  AsyncTimeoutError* = object of AsyncError
    ## Timeout exception
