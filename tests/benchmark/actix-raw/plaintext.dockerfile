FROM rust:1.28-slim

ADD ./ /actix
WORKDIR /actix

RUN apt update -yqq && \
    apt install -yqq libpq-dev
RUN cargo clean
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

CMD ./target/release/actix
