# HTTP Server: Status Dashboard

In this tutorial, we'll build a dashboard server for the [uptime monitor](../http_client/intro.md). This server will provide an API to receive status reports and a basic (since this is not a frontend tutorial) web interface to view the current status of monitored services.

While building our dashboard, you'll learn how to setup up an async HTTP server, handle different request types, process JSON data, and process requests using middlewares.

The complete application (split into chapters to help you track progress) is available at [docs/examples/http_server](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server).

## Prerequisites

To go through the tutorial, you'll need a computer with a stable Internet connection, any text editor, and a console (aka terminal emulator). Familiarity with the concepts of HTTP requests and async routines as well as Nim knowledge will help you along but are not required.

Before you start, make sure you have Nim programming language and Nimble package manager installed using [the official installation guide](https://nim-lang.org/install.html).

We'll use Nimble to initialize our project and manage its dependencies. Each chapter in this tutorial is a separate Nimble project, and we'll show you how to set them up as we progress.
