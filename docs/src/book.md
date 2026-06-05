# Updating this book

To contribute to this book, [fork the repository](https://github.com/status-im/nim-chronos/fork), edit the book locally, and [send a pull request](https://github.com/status-im/nim-chronos/compare) with your changes.

## Modifying the content

The book's content is stored in the form of `.md` files in `docs/src` directory. For example, this page's source is at `docs/src/book.md`.

To edit the content, you'll need any text editor and familiarity with [Markdown](https://rust-lang.github.io/mdBook/format/markdown.html) syntax.

If you want to add a new page, edit the file `docs/src/SUMMARY.md`. It's a list of all pages in this book, groupped into parts:

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

If mdBook detects a new page in `SUMMARY.md` that doesn't have a corresponding `.md` file, it will create it automatically during next build and you'll be able to edit it as any other page.

## Building the docs locally

This book is created using [mdBook](https://rust-lang.github.io/mdBook/) so to test your changes locally, you'll need to have it along with preprocessors installed.

If you have a working Rust toolchain set up, install the cargo crates with `cargo install`:

```shell
cargo install mdbook@0.4.36 mdbook-toc@0.14.1 mdbook-open-on-gh@2.4.3 mdbook-admonish@0.14.0
```

If you don't have it, the easiest way to install mdBook without installing Rust is to use [cargo-binstall](https://github.com/cargo-bins/cargo-binstall):

```shell
cargo-binstall mdbook@0.4.36 mdbook-toc@0.14.1 mdbook-open-on-gh@2.4.3 mdbook-admonish@0.14.0
```

After that, you can build and view the docs locally with this command:

```shell
mdbook serve --hostname:0.0.0.0 docs
```

Open [localhost:3000](http://localhost:3000) your browser to see the docs.

`mdbook serve` automatically detects changes in the docs sources, rebuilds the site, and refreshes the page in the browser to show the new version.
