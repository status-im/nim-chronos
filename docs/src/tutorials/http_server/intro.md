# HTTP Server: Status Dashboard

In this tutorial, we'll build a dashboard server for our uptime monitor. This server will provide an API to receive status reports and a web interface to view the current status of monitored services.

Chronos's high performance and efficiency make it an excellent choice for building microservices and web backends that need to handle thousands of concurrent requests with low resource usage. While building our dashboard, we'll learn how to set up an HTTP server, handle different request types, process JSON data, and use middleware.

The complete application (split into chapters to help you track progress) is available at [docs/examples/http_server](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server).

## Prerequisites

To go through the tutorial, you'll need a computer with a stable Internet connection, any text editor, and a console (aka terminal emulator). Familiarity with the concepts of HTTP requests and async routines as well as Nim knowledge will help you along but are not required.

Before you start, make sure you have Nim programming language and Chronos installed:

1. To get Nim, follow [the official installation guide](https://nim-lang.org/install.html).
2. To install Chronos, use Nim's built-in package manager Nimble: `nimble install chronos`.
