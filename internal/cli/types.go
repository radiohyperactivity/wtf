package cli

import (
	"bytes"
	"encoding/json"
)

// The API's JSON shapes (see API.md, "JSON shapes"), as far as the client
// reads them. Numbers stay json.Number so they print exactly as sent.

type ref struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// attribute is one of a class's attributes, its own or inherited.
type attribute struct {
	Name      string          `json:"name"`
	Class     string          `json:"class"` // the class that defines it
	Inherited bool            `json:"inherited"`
	Scope     string          `json:"scope"` // "item" or "stock": where its values live
	Type      string          `json:"type"`
	Required  bool            `json:"required"`
	Unit      string          `json:"unit"`
	Default   json.RawMessage `json:"default"`
	Choices   []string        `json:"choices"`
	Media     []string        `json:"media"`
	Order     int             `json:"order"`
}

// hasDefault tells whether the attribute has a default.
func (a attribute) hasDefault() bool {
	return len(a.Default) > 0 && string(a.Default) != "null"
}

type node struct {
	ID        string  `json:"id"`
	Code      string  `json:"code"`
	Name      string  `json:"name"`
	Parent    *string `json:"parent"`
	Container bool    `json:"container"`
	Children  []*node `json:"children"`
}

type tree struct {
	Version int64   `json:"version"`
	Tree    []*node `json:"tree"`
}

type class struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Parent     *string     `json:"parent"`
	Container  bool        `json:"container"`
	Path       []ref       `json:"path"`
	Attributes []attribute `json:"attributes"`
}

// classChange is the answer of a change of a class's attributes.
type classChange struct {
	Class  class `json:"class"`
	Items  int   `json:"items"`
	Stock  int   `json:"stock"`
	DryRun bool  `json:"dry_run"`
}

type location struct {
	ID        string  `json:"id"`
	Code      string  `json:"code"`
	Name      string  `json:"name"`
	Parent    *string `json:"parent"`
	Container bool    `json:"container"`
	Path      []ref   `json:"path"`
}

// values are an item's or a stock row's values, by attribute name.
type values = map[string]json.RawMessage

// itemRow is an item in item_list (and, without stock, inside a stock row).
type itemRow struct {
	ID    string      `json:"id"`
	Code  string      `json:"code"`
	Name  string      `json:"name"`
	Class string      `json:"class"`
	Unit  *string     `json:"unit"`
	Photo *string     `json:"photo"`
	Stock *stockTotal `json:"stock"`
}

type stockTotal struct {
	Total     json.Number `json:"total"`
	Uncounted bool        `json:"uncounted"`
}

type item struct {
	ID        string      `json:"id"`
	Code      string      `json:"code"`
	Name      string      `json:"name"`
	Class     class       `json:"class"`
	Unit      *string     `json:"unit"`
	Photo     *string     `json:"photo"`
	Values    values      `json:"values"`
	Defaulted []string    `json:"defaulted"`
	Stock     []itemStock `json:"stock"`
}

type itemStock struct {
	ID        string       `json:"id"`
	Code      string       `json:"code"`
	Location  string       `json:"location"`
	Amount    *json.Number `json:"amount"`
	Reference *string      `json:"reference"`
	Serial    *string      `json:"serial"`
	Photo     *string      `json:"photo"`
	Values    values       `json:"values"`
	Defaulted []string     `json:"defaulted"`
}

type stock struct {
	ID        string       `json:"id"`
	Code      string       `json:"code"`
	Item      itemRow      `json:"item"`
	Location  string       `json:"location"`
	Amount    *json.Number `json:"amount"`
	Reference *string      `json:"reference"`
	Serial    *string      `json:"serial"`
	Photo     *string      `json:"photo"`
	Values    values       `json:"values"`
	Defaulted []string     `json:"defaulted"`
}

// page is one page of a list: its rows, whether more follow, and the row
// to list after for the next page.
type page[T any] struct {
	Rows []T    `json:"rows"`
	More bool   `json:"more"`
	Next string `json:"next"`
}

type account struct {
	ID          string `json:"id"`
	Email       string `json:"email"`
	HasPassword bool   `json:"has_password"`
	Role        string `json:"role"`
}

// session is one of the account's own sessions (GET /me/sessions).
type session struct {
	ID       string  `json:"id"`
	Client   *string `json:"client"`
	Created  string  `json:"created"`
	LastUsed string  `json:"last_used"`
	MaxIdle  *int64  `json:"max_idle"` // seconds; nil: never expires
	Expires  *string `json:"expires"`
	Current  bool    `json:"current"`
	Usage    []struct {
		Address string `json:"address"`
		Seen    string `json:"seen"`
	} `json:"usage"`
}

type codeResult struct {
	Type   string          `json:"type"`
	Object json.RawMessage `json:"object"`
}

// decode unmarshals API JSON, keeping numbers as json.Number.
func decode(data []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	return d.Decode(v)
}

// decode is decode, as a method, for the commands.
func (e *env) decode(data []byte, v any) error {
	return decode(data, v)
}
