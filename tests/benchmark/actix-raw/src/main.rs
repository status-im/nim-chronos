extern crate actix;
extern crate actix_web;
extern crate futures;

use actix::prelude::*;
use actix_web::server::{
    self, HttpHandler, HttpHandlerTask, HttpServer, Request, Writer,
};
use actix_web::Error;
use futures::{Async, Poll};

const HTTPOK: &[u8] = b"HTTP/1.1 200 OK\r\n";
const HDR_SERVER: &[u8] = b"Server: Actix\r\n";
const HDR_CTPLAIN: &[u8] = b"Content-Type: text/plain";
const BODY: &[u8] = b"Hello, World!";

struct App {
}

impl HttpHandler for App {
    type Task = Box<HttpHandlerTask>;

    fn handle(&self, req: Request) -> Result<Box<HttpHandlerTask>, Request> {
        {
            let path = req.path();
            match path.len() {
                10 if path == "/plaintext" => return Ok(Box::new(Plaintext)),
                _ => (),
            }
        }
        Err(req)
    }
}

struct Plaintext;

impl HttpHandlerTask for Plaintext {
    fn poll_io(&mut self, io: &mut Writer) -> Poll<bool, Error> {
        {
            let mut bytes = io.buffer();
            bytes.reserve(196);
            bytes.extend_from_slice(HTTPOK);
            bytes.extend_from_slice(HDR_SERVER);
            bytes.extend_from_slice(HDR_CTPLAIN);
            server::write_content_length(13, &mut bytes);
        }
        io.set_date();
        io.buffer().extend_from_slice(BODY);
        Ok(Async::Ready(true))
    }
}

fn main() {
    let sys = System::new("techempower");

    // start http server
    HttpServer::new(move || {
        vec![App { }]
    }).backlog(8192)
      .workers(1) // comment this to enable multithread mode
      .bind("0.0.0.0:8080")
      .unwrap()
      .start();

    println!("Started http server: 127.0.0.1:8080");
    let _ = sys.run();
}
