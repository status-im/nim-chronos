.. title:: Updating this book

To contribute to this book, [fork the repository](https://github.com/status-im/nim-chronos/fork), edit the book locally, and [send a pull request](https://github.com/status-im/nim-chronos/compare) with your changes.

# Modifying the content

The book's content is stored in the form of `.md` files in the `book` directory. For example, this page's source is at `book/book.md`.

To edit the content, you'll need any text editor and familiarity with [Nim-flavored Markdown](https://nim-lang.org/docs/markdown_rst.html) syntax.

If you want to add a new page, edit the file `book/SUMMARY.md`. It's a list of all pages in this book, groupped into parts:

```markdown
- [Introduction](./introduction.md)
- [Examples](./examples.md)

# User guide

- [Core concepts](./concepts.md)
- [`async` functions](./async_procs.md)
- [Errors and exceptions](./error_handling.md)
- [Threads](./threads.md)
- [Tips, tricks and best practices](./tips.md)
- [Porting code to `chronos`](./porting.md)
- [HTTP server middleware](./http_server_middleware.md)

# Developer guide

- [Updating this book](./book.md)
```

# Building the docs locally

This book is created using [`nim book`](https://nim-lang.org/docs/markdown_rst.html) so to test your changes locally, you'll need a Nim compiler.

Build the book with:

```shell
nim book book
```

The output is written to the `htmldocs` directory. Open `htmldocs/index.html` in your browser to see the docs.
