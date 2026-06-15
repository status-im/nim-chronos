# Session Reuse

**Goal:** Learn how to reuse HTTP sessions for multiple requests.

**Source code:** [chapter2/src/uptimemon.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_client/chapter2/src/uptimemon.nim)

OK, we have a working app that can check one URI. Now let's see how to check multiple URIs.

While it might be tempting to just wrap our code from Chapter 1 in a loop, there's a much more efficient way to handle multiple requests in Chronos: **reusing the HTTP session**.

Recall from Chapter 1 that a session (`HttpSessionRef`) is a **connection pool manager**. Its job is to keep a collection of open connections to various servers. When you make a request, the session looks into its pool:

1. If there is already an idle connection to that server, it _reuses_ it.
2. Only if no idle connection exists does it _allocate_ a new one.

If you create a new session for every request, you end up with multiple "pools" that don't know about each other.

Imagine you are checking 10 pages on the same website.

- _With session reuse_: The first request opens a connection. When it's done, the connection goes back to the pool. The second request then picks up that _exact same connection_ and uses it immediately.
- _With a new session per request_: Each request creates a brand new pool. Since a brand new pool is always empty, every single request is forced to open a new connection from scratch.

Opening a new connection is expensive: your computer has to talk to the server to establish a TCP link, and then perform a cryptographic handshake (TLS) to secure it. By reusing a session, you skip this setup phase for subsequent requests, making your app faster and more respectful of the server's resources.

To reuse a session, we'll pass it as an argument to our `check` function:

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:all}}
```

Let's see what changed.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:uris}}
```

We define a list of URIs to check.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:check_uri}}
```

We've modified `check` to accept a `session` argument. Notice that we no longer create or close the session inside this function—that's now the responsibility of the caller. This allows the session's pool to outlive any single request.

```nim
{{#shiftinclude auto:../../../examples/http_client/chapter2/src/uptimemon.nim:check_uris}}
```

We've added a new `check` function that takes a list of URIs. It creates a single `HttpSessionRef` and reuses it for each URI in the loop. The `try..finally` block ensures that the session is properly closed—and all its pooled connections are freed—after all checks are done.

Run this code with `nimble run`. You'll see it checks each URI one by one, but much more efficiently than if it were creating a new session for each.

In the next chapter, we'll see how to make these requests run concurrently!
