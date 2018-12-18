FROM rust:1.28-slim

RUN apt update -yqq && \
    apt install -yqq libpq-dev

RUN mkdir -p /opt/actix/src
RUN touch /opt/actix/src/lib.rs

ADD ./Cargo.toml /opt/actix/
WORKDIR /opt/actix
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

RUN rm -rf /opt/actix/src/
ADD ./src /opt/actix/src

RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

CMD ./target/release/actix
# CMD USE_THREADS=1 ./target/release/actix
