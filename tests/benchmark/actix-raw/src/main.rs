extern crate actix;
extern crate actix_web;
extern crate futures;

use std::env;

use actix::prelude::*;
use actix_web::{http, server, App, HttpRequest, HttpResponse};

fn plaintext(req: &HttpRequest) -> HttpResponse {
    HttpResponse::build_from(req)
        .header(http::header::SERVER, "Actix")
        .header(http::header::CONTENT_TYPE, "text/plain")
        .body("Hello, World!")
}

fn main() {
    let sys = System::new("techempower");

    // start http server
    let srv = server::new(move || {
        App::new()
            .resource("/plaintext", |r| r.f(plaintext))
    }).backlog(8192);

    if env::var_os("USE_THREADS").is_none() {
        srv.workers(1)
    } else {
        srv
    }.bind("0.0.0.0:8080").unwrap().start();

    println!("Started http server: 127.0.0.1:8080");
    let _ = sys.run();
}
