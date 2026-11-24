package proxy

import (
	"context"
	"errors"
	"net/http"
	"net/http/httputil"
	"restic-proxy/internal/client"
	"sync"

	"github.com/cornelk/hashmap"
	"github.com/rs/zerolog/log"
)

type routed struct {
	key   string
	grant client.Grant
	path  string
}

type contextKey struct{}

func reverseProxy(grants *hashmap.Map[string, client.Grant], transport http.RoundTripper) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Transport:  transport,
		BufferPool: newBufferPool(),
		Rewrite: func(request *httputil.ProxyRequest) {
			route := request.In.Context().Value(contextKey{}).(routed)
			request.Out.URL.Scheme = route.grant.Scheme
			request.Out.URL.Host = route.grant.Host
			request.Out.Host = route.grant.Host
			request.Out.URL.Path = route.grant.Path + "/" + route.path
			request.Out.URL.RawPath = ""
			request.Out.SetBasicAuth("restic", route.grant.Password)
			log.Debug().Any("host", request.Out.Host).Str("path", request.Out.URL.Path).Msg("forwarded request")
		},
		ModifyResponse: func(response *http.Response) error {
			if response.StatusCode != http.StatusUnauthorized {
				return nil
			}

			route := response.Request.Context().Value(contextKey{}).(routed)
			grants.Del(route.key)

			if err := response.Body.Close(); err != nil {
				return err
			}

			response.StatusCode = http.StatusServiceUnavailable
			response.Status = http.StatusText(http.StatusServiceUnavailable)
			response.Header = http.Header{"Content-Type": []string{"application/json"}}
			response.Body = http.NoBody
			response.ContentLength = 0

			return nil
		},
		ErrorHandler: func(writer http.ResponseWriter, request *http.Request, err error) {
			if errors.Is(context.Cause(request.Context()), errNetworkChanged) {
				writer.Header().Set("Connection", "close")
				http.Error(writer, "backend unreachable", http.StatusBadGateway)
				log.Warn().Err(err).Msg("Interrupted an upstream request after a network change")
				return
			}

			http.Error(writer, "backend unreachable", http.StatusBadGateway)
			log.Error().Err(err).Msg("backend unreachable")
		},
	}
}

type bufferPool struct{ pool sync.Pool }

const copyBufferSize = 32 << 10

func newBufferPool() *bufferPool {
	return &bufferPool{pool: sync.Pool{New: func() any {
		buffer := make([]byte, copyBufferSize)
		return &buffer
	}}}
}

func (b *bufferPool) Get() []byte {
	return *b.pool.Get().(*[]byte)
}

func (b *bufferPool) Put(buffer []byte) {
	b.pool.Put(&buffer)
}
