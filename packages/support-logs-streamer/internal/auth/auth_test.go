package auth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var testPrivateKey, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

const (
	testUser       = "00000000-0000-0000-0000-000000000001"
	testSession    = "00000000-0000-0000-0000-000000000002"
	testConnection = "00000000-0000-0000-0000-000000000003"
)

func makeJWT(t *testing.T, key *ecdsa.PrivateKey, claims jwt.MapClaims) string {
	t.Helper()
	signed, err := jwt.NewWithClaims(jwt.SigningMethodES256, claims).SignedString(key)
	if err != nil {
		t.Fatalf("failed to sign JWT: %v", err)
	}
	return signed
}

func validClaims() jwt.MapClaims {
	return jwt.MapClaims{
		"aud":        Audience,
		"sub":        testUser,
		"sid":        testSession,
		"job":        "job-1",
		"jobName":    "RepositoryBackup",
		"connection": testConnection,
		"exp":        jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}
}

func TestVerifyValid(t *testing.T) {
	session, err := Verify(makeJWT(t, testPrivateKey, validClaims()), &testPrivateKey.PublicKey)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := Session{User: testUser, Session: testSession, Job: "job-1", JobName: "RepositoryBackup", Connection: testConnection}
	if session != want {
		t.Errorf("got %+v, want %+v", session, want)
	}
}

func TestVerifyOptionalClaims(t *testing.T) {
	claims := validClaims()
	delete(claims, "connection")
	delete(claims, "jobName")
	if _, err := Verify(makeJWT(t, testPrivateKey, claims), &testPrivateKey.PublicKey); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestVerifyRejects(t *testing.T) {
	otherKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

	cases := map[string]func(jwt.MapClaims){
		"restic token audience": func(c jwt.MapClaims) { delete(c, "aud") },
		"wrong audience":        func(c jwt.MapClaims) { c["aud"] = "yucca-admin-cli" },
		"missing exp":           func(c jwt.MapClaims) { delete(c, "exp") },
		"expired":               func(c jwt.MapClaims) { c["exp"] = jwt.NewNumericDate(time.Now().Add(-time.Minute)) },
		"missing sub":           func(c jwt.MapClaims) { delete(c, "sub") },
		"sub not a uuid":        func(c jwt.MapClaims) { c["sub"] = "someone" },
		"missing sid":           func(c jwt.MapClaims) { delete(c, "sid") },
		"sid not a uuid":        func(c jwt.MapClaims) { c["sid"] = "abc" },
		"missing job":           func(c jwt.MapClaims) { delete(c, "job") },
		"connection not a uuid": func(c jwt.MapClaims) { c["connection"] = "abc" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			claims := validClaims()
			mutate(claims)
			if _, err := Verify(makeJWT(t, testPrivateKey, claims), &testPrivateKey.PublicKey); err == nil {
				t.Fatal("expected rejection")
			}
		})
	}

	t.Run("wrong key", func(t *testing.T) {
		if _, err := Verify(makeJWT(t, otherKey, validClaims()), &testPrivateKey.PublicKey); err == nil {
			t.Fatal("expected rejection")
		}
	})

	t.Run("hmac token", func(t *testing.T) {
		signed, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, validClaims()).SignedString([]byte("secret"))
		if _, err := Verify(signed, &testPrivateKey.PublicKey); err == nil {
			t.Fatal("expected rejection")
		}
	})
}

func TestMiddleware(t *testing.T) {
	handler := Middleware(&testPrivateKey.PublicKey)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if FromContext(r.Context()).Session != testSession {
			t.Error("session missing from context")
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	cases := map[string]struct {
		header string
		want   int
	}{
		"bearer":  {"Bearer " + makeJWT(t, testPrivateKey, validClaims()), http.StatusNoContent},
		"missing": {"", http.StatusUnauthorized},
		"basic":   {"Basic abc", http.StatusUnauthorized},
		"garbage": {"Bearer nope", http.StatusUnauthorized},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/batches", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Errorf("got %d, want %d", rec.Code, tc.want)
			}
		})
	}
}
