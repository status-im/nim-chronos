# Chapter 1. Making an HTTP Request with Chronos

**Goal:** Learn how to make an HTTP request and proccess its response with Chronos.

Create a file called `uptimemon.nim` and open it your favorite text editor.

Copy and paste this code into this new file (we'll go through each line in a moment):

```nim
import std/strformat

import chronos, chronos/apps/http/httpclient

proc checkUrl(url: string) {.async.} =
  let session = HttpSessionRef.new()

  try:
    let response = await session.fetch(parseUri(url))

    if response.status == 200:
      echo fmt"[OK] {url}"
    else:
      echo fmt"[NOK] {url} returned status: {response.status}"
  except CatchableError:
    echo fmt"[ERR] Connection to {url} failed: {getCurrentExceptionMsg()}"
  finally:
    await noCancel(session.closeWait())

when isMainModule:
  waitFor checkUrl("https://google.com")
```

To execute the file, switch to the directory with this file in your terminal and run this command:

```shell
$ nim r uptimemon.nim
```

You should see the following message in you terminal:

```shell
✅ https://google.com
```

Now let's see what we're doing here line by line.

## Line-by-Line Explanation

```nim
import std/strformat
```

We import `strformat` from Nim's standard library. This module gives us a convenient way to print strings, we'll use that show the check results.

```nim
import chronos, chronos/apps/http/httpclient
```

We import `chronos` to enable the asynchronous runtime, i.e. `await`, `waitFor`, etc. `httpclient` module, as the title suggests, implements the HTTP client capabilities, i.e. sending HTTP requests and dealing with the responses.

```nim
proc checkUrl(url: string) {.async.} =
```

We define a function that sends an HTTP request to a URL we provide, checks if this URL is available, and prints the result. Note that this function must be annotated with `async` pragma because we won't call it directly but instead will "book" its execution from Chronos in an asynchronous way.

```nim
let session = HttpSessionRef.new()
```

Let's focus on this line for a moment. Here, we're creating an HTTP session. Why would we do it if we need to make only only request, why can't we just send it? The reason is, Chronos is designed for multitasking and a session is a more natural concept than a singular request in this context. While we're just starting, using a session may feel redundant but since our end goal is to send many requests, it will fit just right.

```nim
try:
  let response = await session.fetch(parseUri(url))
```

When dealing with the Web, we must always assume the connection can break. So it's a good idea to get wrap all web interactions in a `try-except` block.

`fetch` is a shortcut for "create an HTTP GET request within the given session to the given URL."

`parseUri` is a function that parses a string into a structured URI object.

Notice that when we are assigning a value to `response`, we do not call `fetch` directly but put an `await` before it. In the async land, you'll see that all the time: whenever you want to call a function that should not block, you `await` on it signaling to the runtime that at this point some other function can take control.

```nim
if response.status == 200:
  echo fmt"[OK] {url}"
else:
  echo fmt"[NOK] {url} returned status: {response.status}"
```

JJJJ
Once we've received our response, we can check its status. If it's 200, we mark this URL healthy (later in the tutorial, we'll improve this logic to handle empty and junk responses), otherwise—not healthy.

```nim
except CatchableError:
  echo fmt"[ERR] Connection to {url} failed: {getCurrentExceptionMsg()}"
```

`CatchableError` comes from the Nim standard library and just means any exceptions that can be caught. If our request fails (for whatever reason), we catch that error and print it withj `getCurrentExceptionMsg`.

```
finally:
  await noCancel(session.closeWait())
```

Regardless of how successful our check was, we must close the session after we're done with in and return the resources back to your computer. `closeWait` is a function that schedules all open connections within this session to be closed.

We added `noCancel` to make sure the closing procedure is not cancelled with a propagated `CancellationError` from another function. Use `noCancel` in resource-critical operations or atomic operation groups that must either all complete or all fail.

```nim
when isMainModule:
  waitFor checkUrl("https://google.com")
```

Finally, we call our function to check a particular URL. Google is probably up so you should get an `[OK]` message. However, you can try other URLs to see how the response changes if you use a non-existing URL or a forbidden one.
