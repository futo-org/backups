// Package bot posts investigation results to futo-backups-bot, the only
// place columbo is allowed to write: the bot validates the target is a staff
// thread before anything reaches Discord.
package bot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"

	"columbo/internal/ticket"
	"strings"
	"time"
)

type Client struct {
	URL            string
	InternalSecret string
	HTTPClient     *http.Client
}

func NewClient(url, internalSecret string) *Client {
	return &Client{
		URL:            strings.TrimRight(url, "/"),
		InternalSecret: internalSecret,
		HTTPClient:     &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *Client) PostStaffNote(ctx context.Context, staffThreadID, content string) error {
	body, err := json.Marshal(map[string]string{
		"staffThreadId": staffThreadID,
		"content":       content,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/internal/staff-notes", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Secret", c.InternalSecret)

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("staff-note post failed with status %d: %s", resp.StatusCode, detail)
	}
	return nil
}

const (
	ticketContextTimeout  = 10 * time.Second
	maxTicketContextBytes = 1 << 20
)

func (c *Client) GetTicketContext(ctx context.Context, threadID string) (ticket.Context, error) {
	ctx, cancel := context.WithTimeout(ctx, ticketContextTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.URL+"/internal/tickets/"+url.PathEscape(threadID)+"/context", nil)
	if err != nil {
		return ticket.Context{}, err
	}
	req.Header.Set("X-Internal-Secret", c.InternalSecret)
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return ticket.Context{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ticket.Context{}, fmt.Errorf("ticket context failed with status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxTicketContextBytes+1))
	if err != nil {
		return ticket.Context{}, err
	}
	if len(body) > maxTicketContextBytes {
		return ticket.Context{}, errors.New("ticket context response exceeds limit")
	}
	var fresh ticket.Context
	if err := json.Unmarshal(body, &fresh); err != nil {
		return ticket.Context{}, fmt.Errorf("invalid ticket context: %w", err)
	}
	return fresh, nil
}
