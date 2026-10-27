package auth

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"net/http"
	"strings"

	"support-logs-streamer/internal/httputil"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const Audience = "support-logs"

type Session struct {
	User       string
	Session    string
	Job        string
	JobName    string
	Connection string
}

type claims struct {
	jwt.RegisteredClaims
	Session    string `json:"sid"`
	Job        string `json:"job"`
	JobName    string `json:"jobName"`
	Connection string `json:"connection"`
}

type contextKey struct{}

func NewContext(ctx context.Context, s Session) context.Context {
	return context.WithValue(ctx, contextKey{}, s)
}

func FromContext(ctx context.Context) Session {
	return ctx.Value(contextKey{}).(Session)
}

var errInvalidToken = errors.New("invalid token")

// Verify checks a support-logs token. The audience pin is what keeps a restic
// token, minted by yucca-api with the same key, from opening a log stream.
func Verify(token string, publicKey *ecdsa.PublicKey) (Session, error) {
	var c claims
	_, err := jwt.ParseWithClaims(token, &c, func(*jwt.Token) (any, error) {
		return publicKey, nil
	},
		jwt.WithValidMethods([]string{jwt.SigningMethodES256.Alg()}),
		jwt.WithAudience(Audience),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return Session{}, errInvalidToken
	}

	if !isUUID(c.Subject) || !isUUID(c.Session) || c.Job == "" {
		return Session{}, errInvalidToken
	}
	if c.Connection != "" && !isUUID(c.Connection) {
		return Session{}, errInvalidToken
	}

	return Session{
		User:       c.Subject,
		Session:    c.Session,
		Job:        c.Job,
		JobName:    c.JobName,
		Connection: c.Connection,
	}, nil
}

func Middleware(publicKey *ecdsa.PublicKey) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				httputil.WriteError(w, r, http.StatusUnauthorized, "Expected Bearer token")
				return
			}

			session, err := Verify(token, publicKey)
			if err != nil {
				httputil.WriteError(w, r, http.StatusUnauthorized, "Invalid token")
				return
			}

			next.ServeHTTP(w, r.WithContext(NewContext(r.Context(), session)))
		})
	}
}

func isUUID(s string) bool {
	_, err := uuid.Parse(s)
	return err == nil
}
