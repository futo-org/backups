package handlers

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestSaveBlob_ClientCanceled_Returns499(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	store := &mockStorage{
		putObjectFn: func(_ context.Context, _, _ string, _ io.Reader, _ int64, _ bool, _ string) error {
			cancel()
			return fmt.Errorf("PutObject: %w", context.Canceled)
		},
	}
	srv := newTestServer(store)
	req := httptest.NewRequest(http.MethodPost, "/"+testRepository+"/data/"+testBlobName, strings.NewReader("x")).WithContext(ctx)
	req.Header.Set("Authorization", makeBasicAuth(makeJWT(t, jwt.MapClaims{
		"user": testUser, "repository": testRepository, "writeOnce": false, "exp": jwt.NewNumericDate(time.Now().Add(time.Hour)),
	})))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != StatusClientClosedRequest {
		t.Errorf("expected 499 when the client hangs up, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestSaveBlob_StorageCanceledWithLiveClient_Returns500(t *testing.T) {
	store := &mockStorage{
		putObjectFn: func(_ context.Context, _, _ string, _ io.Reader, _ int64, _ bool, _ string) error {
			return fmt.Errorf("PutObject: %w", context.Canceled)
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodPost, "/"+testRepository+"/data/"+testBlobName, strings.NewReader("x"), defaultAuth(), nil)

	if rec.Code != http.StatusInternalServerError {
		t.Errorf("expected 500 when the client is still there, got %d", rec.Code)
	}
}
