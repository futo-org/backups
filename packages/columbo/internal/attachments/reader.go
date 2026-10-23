package attachments

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"columbo/internal/ticket"
)

const (
	MaxFiles          = 6
	MaxFileBytes      = 2 << 20
	MaxTotalBytes     = 6 << 20
	MaxTextBytes      = 32 << 10
	MaxTotalTextBytes = 96 << 10
	downloadTimeout   = 15 * time.Second
	batchTimeout      = 45 * time.Second
	maxRedirects      = 3
	maxNameBytes      = 256
)

type Result struct {
	Name      string
	Kind      string
	Text      string
	MediaType string
	Data      []byte
	Note      string
	Truncated bool
}

type Reader struct {
	client *http.Client
}

func NewReader(transport http.RoundTripper) *Reader {
	return &Reader{client: &http.Client{
		Transport: transport,
		Timeout:   downloadTimeout,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) > maxRedirects {
				return fmt.Errorf("attachment redirect limit exceeded")
			}
			return validateURL(request.URL)
		},
	}}
}

func (r *Reader) Read(ctx context.Context, files []ticket.Attachment) []Result {
	ctx, cancel := context.WithTimeout(ctx, batchTimeout)
	defer cancel()
	results := make([]Result, 0, min(len(files), MaxFiles)+1)
	total, textBytes := 0, 0
	for i, file := range files {
		if i == MaxFiles {
			results = append(results, Result{Kind: "unavailable", Note: fmt.Sprintf("%d additional attachments omitted: file limit reached", len(files)-i)})
			break
		}
		result, consumed := r.read(ctx, file, min(MaxFileBytes, MaxTotalBytes-total))
		total += consumed
		if result.Kind == "text" {
			limit := min(MaxTextBytes, MaxTotalTextBytes-textBytes)
			if len(result.Text) > limit {
				end := limit
				for end > 0 && !utf8.RuneStart(result.Text[end]) {
					end--
				}
				result.Text = result.Text[:end]
				result.Truncated = true
				result.Note = "Text excerpt truncated by attachment context limits"
			}
			textBytes += len(result.Text)
		}
		results = append(results, result)
	}
	return results
}

func (r *Reader) read(ctx context.Context, file ticket.Attachment, limit int) (Result, int) {
	name := strings.ToValidUTF8(file.Name, "�")
	if len(name) > maxNameBytes {
		end := maxNameBytes
		for !utf8.RuneStart(name[end]) {
			end--
		}
		name = name[:end]
	}
	result := Result{Name: name, Kind: "unavailable"}
	parsed, err := url.Parse(file.URL)
	if err != nil || validateURL(parsed) != nil {
		result.Note = "Attachment URL is not a canonical HTTPS Discord CDN attachment"
		return result, 0
	}
	if limit <= 0 || file.Size > int64(limit) {
		result.Note = "Attachment omitted: download byte limit exceeded"
		return result, 0
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		result.Note = "Attachment request could not be created"
		return result, 0
	}
	response, err := r.client.Do(request)
	if err != nil {
		result.Note = "Attachment download unavailable"
		return result, 0
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		result.Note = fmt.Sprintf("Attachment download returned HTTP %d", response.StatusCode)
		return result, 0
	}
	if response.ContentLength > int64(limit) {
		result.Note = "Attachment omitted: download byte limit exceeded"
		return result, 0
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		result.Note = "Attachment download interrupted"
		return result, len(data)
	}
	if len(data) > limit {
		result.Note = "Attachment omitted: download byte limit exceeded"
		return result, len(data)
	}
	result.MediaType = http.DetectContentType(data)
	switch result.MediaType {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		result.Kind, result.Data = "image", data
	case "text/plain; charset=utf-8", "text/xml; charset=utf-8", "text/html; charset=utf-8", "application/octet-stream":
		if readableText(data) {
			result.Kind, result.Text = "text", string(data)
			break
		}
		fallthrough
	default:
		result.Kind = "unsupported"
		result.Note = "Unsupported binary attachment; no extraction or execution was performed"
	}
	return result, len(data)
}

func validateURL(value *url.URL) error {
	if value == nil || value.Scheme != "https" || value.User != nil || value.Fragment != "" || value.Opaque != "" || value.Port() != "" {
		return fmt.Errorf("unsafe attachment URL")
	}
	switch strings.ToLower(value.Host) {
	case "cdn.discordapp.com", "media.discordapp.net":
	default:
		return fmt.Errorf("unsafe attachment host")
	}
	parts := strings.Split(value.Path, "/")
	if len(parts) != 5 || parts[0] != "" || parts[1] != "attachments" || !snowflake(parts[2]) || !snowflake(parts[3]) || parts[4] == "" || parts[4] == "." || parts[4] == ".." || strings.ContainsAny(parts[4], "\\\x00\r\n") {
		return fmt.Errorf("unsafe attachment path")
	}
	return nil
}

func snowflake(value string) bool {
	if len(value) < 17 || len(value) > 20 {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func readableText(data []byte) bool {
	if !utf8.Valid(data) {
		return false
	}
	for _, character := range string(data) {
		if unicode.IsControl(character) && character != '\n' && character != '\r' && character != '\t' && character != '\x1b' {
			return false
		}
	}
	return true
}
