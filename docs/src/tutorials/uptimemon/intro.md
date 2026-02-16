# HTTP Client: Uptime Monitor

In this tutorial, we'll create a performant and efficient monitoring service using Chronos. The service will regularly check URIs from a given list and notify you if a URI is unavailable.

Applications where you have to make thousands of HTTP requests concurrently is exactly the kinds of applications where Chronos truly shines. While working on our service, we'll discover Chronos's way of making HTTP requests, scaling them, working with timeouts and streaming.

The complete application (split into chapters to help you track progress) is available at [docs/examples/uptimemon](https://github.com/status-im/nim-chronos/blob/master/docs/examples/uptimemon).

## Prerequisites

To go through the tutorial, you'll need a computer with a stable Internet connection, any text editor, and a console (aka terminal emulator). Familiarity with the concepts of HTTP requests and async routines as well as Nim knowledge will help you along but are not required.

Before you start, make sure you have Nim programming language and Chronos installed:

1. To get Nim, follow [the official installation guide](https://nim-lang.org/install.html).
2. To install Chronos, use Nim's built-in package manager Nimble: `nimble install chronos`.
