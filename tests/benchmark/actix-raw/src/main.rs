extern crate actix;
extern crate actix_web;
extern crate bytes;
extern crate futures;
extern crate serde_json;
#[macro_use]
extern crate serde_derive;
extern crate askama;
extern crate rand;
extern crate url;
extern crate diesel;

use actix::prelude::*;
use actix_web::server::{
    self, HttpHandler, HttpHandlerTask, HttpServer, Request, Writer,
};
use actix_web::Error;
use futures::{Async, Poll};

mod utils;

use utils::{Message, Writer as JsonWriter};

const HTTPOK: &[u8] = b"HTTP/1.1 200 OK\r\n";
const HDR_SERVER: &[u8] = b"Server: Actix\r\n";
const HDR_CTPLAIN: &[u8] = b"Content-Type: text/plain";
const HDR_CTJSON: &[u8] = b"Content-Type: application/json";
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
                5 if path == "/json" => return Ok(Box::new(Json)),
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

struct Json;

impl HttpHandlerTask for Json {
    fn poll_io(&mut self, io: &mut Writer) -> Poll<bool, Error> {
        let message = Message {
            message: "Hello, World!",
        };

        {
            let mut bytes = io.buffer();
            bytes.reserve(196);
            bytes.extend_from_slice(HTTPOK);
            bytes.extend_from_slice(HDR_SERVER);
            bytes.extend_from_slice(HDR_CTJSON);
            server::write_content_length(27, &mut bytes);
        }
        io.set_date();
        serde_json::to_writer(JsonWriter(io.buffer()), &message).unwrap();
        Ok(Async::Ready(true))
    }
}

fn main() {
    let sys = System::new("techempower");

    // start http server
    HttpServer::new(move || {
        vec![App { }]
    }).backlog(8192)
        .bind("0.0.0.0:8080")
        .unwrap()
        .start();

    println!("Started http server: 127.0.0.1:8080");
    let _ = sys.run();
}
