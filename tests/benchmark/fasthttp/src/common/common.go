package common

import (
	"encoding/json"
	"flag"
	"log"
	"net"
	"sync"
	"github.com/valyala/fasthttp"
)

const worldRowCount = 10000

type JSONResponse struct {
	Message string `json:"message"`
}

type World struct {
	Id           int32 `json:"id"`
	RandomNumber int32 `json:"randomNumber"`
}

var listenAddr = flag.String("listenAddr", ":8080", "Address to listen to")

func JSONHandler(ctx *fasthttp.RequestCtx) {
	r := jsonResponsePool.Get().(*JSONResponse)
	r.Message = "Hello, World!"
	JSONMarshal(ctx, r)
	jsonResponsePool.Put(r)
}

var jsonResponsePool = &sync.Pool{
	New: func() interface{} {
		return &JSONResponse{}
	},
}

func PlaintextHandler(ctx *fasthttp.RequestCtx) {
	ctx.SetContentType("text/plain")
	ctx.WriteString("Hello, World!")
}

func JSONMarshal(ctx *fasthttp.RequestCtx, v interface{}) {
	ctx.SetContentType("application/json")
	if err := json.NewEncoder(ctx).Encode(v); err != nil {
		log.Fatalf("error in json.Encoder.Encode: %s", err)
	}
}

func GetListener() net.Listener {
	ln, err := net.Listen("tcp4", *listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	return ln
}
