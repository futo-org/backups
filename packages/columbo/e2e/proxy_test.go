package e2e

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newArtifactCDN(t *testing.T, handler http.HandlerFunc) (*httptest.Server, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "cdn.discordapp.com"}, DNSNames: []string{"cdn.discordapp.com"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	publicPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(publicPEM, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	t.Cleanup(server.Close)
	caPath := filepath.Join(t.TempDir(), "cdn-ca.crt")
	if err := os.WriteFile(caPath, publicPEM, 0644); err != nil {
		t.Fatal(err)
	}
	return server, caPath
}

func newArtifactProxy(t *testing.T, address string, fail func(error)) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect || r.Host != "cdn.discordapp.com:443" {
			fail(fmt.Errorf("unexpected outbound proxy request %s %s", r.Method, r.Host))
			http.Error(w, "outbound request denied", http.StatusForbidden)
			return
		}
		upstream, err := net.DialTimeout("tcp", address, artifactHTTPTimeout)
		if err != nil {
			fail(err)
			http.Error(w, "CDN unavailable", http.StatusBadGateway)
			return
		}
		hijacker, ok := w.(http.Hijacker)
		if !ok {
			_ = upstream.Close()
			fail(fmt.Errorf("proxy does not support hijacking"))
			http.Error(w, "proxy unavailable", http.StatusInternalServerError)
			return
		}
		client, buffer, err := hijacker.Hijack()
		if err != nil {
			_ = upstream.Close()
			fail(err)
			return
		}
		defer func() { _ = client.Close(); _ = upstream.Close() }()
		if err := client.SetDeadline(time.Now().Add(time.Minute)); err != nil {
			fail(err)
			return
		}
		if err := upstream.SetDeadline(time.Now().Add(time.Minute)); err != nil {
			fail(err)
			return
		}
		if _, err := buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
			fail(err)
			return
		}
		if err := buffer.Flush(); err != nil {
			fail(err)
			return
		}
		copied := make(chan struct{})
		go func() { _, _ = io.Copy(upstream, buffer); _ = upstream.Close(); close(copied) }()
		_, _ = io.Copy(client, upstream)
		_ = client.Close()
		<-copied
	}))
	t.Cleanup(server.Close)
	return server
}

func TestArtifactCDNProxyUsesTrustedCanonicalHTTPS(t *testing.T) {
	server, caPath := newArtifactCDN(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Host != "cdn.discordapp.com" {
			t.Errorf("unexpected CDN host %q", r.Host)
		}
		_, _ = io.WriteString(w, "script content as data")
	})
	proxy := newArtifactProxy(t, server.Listener.Addr().String(), func(err error) { t.Error(err) })
	proxyURL, err := url.Parse(proxy.URL)
	if err != nil {
		t.Fatal(err)
	}
	publicPEM, err := os.ReadFile(caPath)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(publicPEM) {
		t.Fatal("test CA was not loaded")
	}
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: artifactHTTPTimeout}
	response, err := client.Get("https://cdn.discordapp.com/attachments/12345678901234567/12345678901234572/diagnostic.sh")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = response.Body.Close() }()
	data, err := io.ReadAll(response.Body)
	if err != nil || !strings.Contains(string(data), "script content as data") {
		t.Fatalf("CDN content=%q error=%v", data, err)
	}
}
