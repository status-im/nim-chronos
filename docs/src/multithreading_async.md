# Multithreading with async event-loops

At times you may want to run asynchronous work on another thread for whatever reason,
then wait while working through the asynchronous work until you receive a signal to continue.

This kind of setup can be facilitated by using `threadSync/ThreadSignalPtr`

```nim
{{#include ../examples/multithreading.nim}}
```
