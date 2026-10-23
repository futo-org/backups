package server

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"columbo/internal/o11y"
)

const versionLookupTimeout = 3 * time.Second

type VersionLookup func(context.Context, string) (o11y.VersionResult, error)

func (s *Server) WithVersionLookup(lookup VersionLookup) *Server {
	s.versionLookup = lookup
	return s
}

func (s *Server) handleVersions(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	if strings.TrimSpace(userID) == "" {
		http.Error(w, "userId is required", http.StatusBadRequest)
		return
	}
	if s.versionLookup == nil {
		http.Error(w, "version lookup unavailable", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), versionLookupTimeout)
	defer cancel()
	versions, err := s.versionLookup(ctx, userID)
	if err != nil {
		http.Error(w, "version lookup unavailable", http.StatusServiceUnavailable)
		return
	}
	if versions.Versions == nil {
		versions.Versions = []o11y.Version{}
	}
	if versions.UnavailableSources == nil {
		versions.UnavailableSources = []string{}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(versions)
}
