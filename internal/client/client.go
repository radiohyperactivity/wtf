// Package client talks to the WtF REST API (wtfd serve). Responses are
// returned as raw JSON; errors from the API (RFC 9457 problem details) are
// returned as *Problem.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The API this client speaks: version 1, at /api/v1, and the revision of it
// it was built for. See WTFD.md, "Versions".
const (
	APIPath     = "/api/v1"
	APIVersion  = 1
	APIRevision = 2
)

// SessionCookie is the cookie the API keeps the session in.
const SessionCookie = "wtf_session"

// Client is an API client.
type Client struct {
	Server string // e.g. "http://localhost:8080"
	Token  string // session token, sent as the session cookie; empty for anonymous requests
	HTTP   *http.Client

	// ServerRevision is the API revision of the last answer (API-Revision),
	// 0 before the first.
	ServerRevision int
}

// New returns a client for server, authenticated with token.
func New(server, token string) *Client {
	return &Client{
		Server: strings.TrimRight(server, "/"),
		Token:  token,
		HTTP:   &http.Client{Timeout: 15 * time.Minute},
	}
}

// Problem is an error response of the API (RFC 9457).
type Problem struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Detail    string `json:"detail"`
	Hint      string `json:"hint"` // what to do about it, when the server knows (revision 2)
	SQLState  string `json:"sqlstate"`
	Supported []int  `json:"supported"` // API versions, in an unsupported-api-version problem
}

// Problem types the client produces or explains itself.
const (
	// OldServer is a 404 from a server that doesn't know /api/v1 at all.
	OldServer          = "/problems/old-server"
	UnsupportedVersion = "/problems/unsupported-api-version"
)

func (p *Problem) Error() string {
	if p.Type == UnsupportedVersion && len(p.Supported) > 0 {
		newest := p.Supported[len(p.Supported)-1]
		if newest > APIVersion {
			return fmt.Sprintf("the server only serves API version %v, newer than this client's (%d): update this client", p.Supported, APIVersion)
		}
		return fmt.Sprintf("the server only serves API version %v, older than this client's (%d): update the server (wtfd)", p.Supported, APIVersion)
	}
	msg := p.Title
	if p.Detail != "" {
		msg += ": " + p.Detail
	}
	if p.Hint != "" {
		msg += "\n" + p.Hint
	}
	return msg
}

// Do sends a request with an optional JSON body and returns the response
// body (nil for 204/304) and headers.
func (c *Client) Do(ctx context.Context, method, path string, query url.Values, body any, headers ...string) (json.RawMessage, http.Header, error) {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, nil, err
		}
		reader = bytes.NewReader(data)
	}
	req, err := c.newRequest(ctx, method, path, query, reader)
	if err != nil {
		return nil, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	return c.send(req)
}

// Get is Do for GET requests without a body.
func (c *Client) Get(ctx context.Context, path string, query url.Values) (json.RawMessage, error) {
	data, _, err := c.Do(ctx, http.MethodGet, path, query, nil)
	return data, err
}

// Upload posts a file as multipart/form-data, with extra text fields.
func (c *Client) Upload(ctx context.Context, path, file string, fields map[string]string) (json.RawMessage, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	// Stream the multipart body instead of holding the file in memory.
	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		err := func() error {
			for k, v := range fields {
				if err := mw.WriteField(k, v); err != nil {
					return err
				}
			}
			h := textproto.MIMEHeader{}
			h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename=%q`, filepath.Base(file)))
			if ct := contentTypeByExtension(file); ct != "" {
				h.Set("Content-Type", ct)
			}
			part, err := mw.CreatePart(h)
			if err != nil {
				return err
			}
			if _, err := io.Copy(part, f); err != nil {
				return err
			}
			return mw.Close()
		}()
		pw.CloseWithError(err)
	}()

	req, err := c.newRequest(ctx, http.MethodPost, path, nil, pr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	data, _, err := c.send(req)
	return data, err
}

// Download writes the body of a GET request to w and returns its headers.
func (c *Client) Download(ctx context.Context, path string, w io.Writer) (http.Header, error) {
	req, err := c.newRequest(ctx, http.MethodGet, path, nil, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	c.noteRevision(resp)
	if resp.StatusCode >= 400 {
		return nil, problemFrom(resp)
	}
	_, err = io.Copy(w, resp.Body)
	return resp.Header, err
}

func (c *Client) newRequest(ctx context.Context, method, path string, query url.Values, body io.Reader) (*http.Request, error) {
	if c.Server == "" {
		return nil, fmt.Errorf("no server configured; run 'wtf login --server URL'")
	}
	u := c.Server + APIPath + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, body)
	if err != nil {
		return nil, err
	}
	if c.Token != "" {
		req.AddCookie(&http.Cookie{Name: SessionCookie, Value: c.Token})
	}
	req.Header.Set("Accept", "application/json")
	return req, nil
}

func (c *Client) send(req *http.Request) (json.RawMessage, http.Header, error) {
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	c.noteRevision(resp)
	if resp.StatusCode >= 400 {
		return nil, resp.Header, problemFrom(resp)
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.Header, err
	}
	if len(data) == 0 {
		return nil, resp.Header, nil
	}
	return data, resp.Header, nil
}

// noteRevision remembers the API revision of an answer.
func (c *Client) noteRevision(resp *http.Response) {
	if n, err := strconv.Atoi(resp.Header.Get("API-Revision")); err == nil {
		c.ServerRevision = n
	}
}

// SessionFrom returns the session token a login answer sets as its cookie.
func SessionFrom(h http.Header) string {
	for _, line := range h.Values("Set-Cookie") {
		if c, err := http.ParseSetCookie(line); err == nil && c.Name == SessionCookie && c.MaxAge >= 0 {
			return c.Value
		}
	}
	return ""
}

func problemFrom(resp *http.Response) error {
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	p := &Problem{}
	if err := json.Unmarshal(data, p); err != nil || p.Title == "" {
		p = &Problem{Status: resp.StatusCode, Title: resp.Status, Detail: strings.TrimSpace(string(data))}
	}
	// Every answer under /api/v1 names its revision. A 404 without one, that
	// isn't the server's "unsupported API version", comes from a server that
	// doesn't know /api/v1 at all.
	if resp.StatusCode == http.StatusNotFound && resp.Header.Get("API-Revision") == "" && p.Type != UnsupportedVersion {
		return &Problem{Type: OldServer, Status: http.StatusNotFound, Title: "Not found",
			Detail: "the server doesn't serve " + APIPath + "; it is probably older than this client: update the server (wtfd)"}
	}
	return p
}

// contentTypeByExtension guesses a few common types; the server detects the
// rest from the content.
func contentTypeByExtension(file string) string {
	switch strings.ToLower(filepath.Ext(file)) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".heic":
		return "image/heic"
	case ".svg":
		return "image/svg+xml"
	case ".pdf":
		return "application/pdf"
	case ".txt":
		return "text/plain"
	}
	return ""
}

// PathEscape escapes a path segment.
func PathEscape(s string) string { return url.PathEscape(s) }
