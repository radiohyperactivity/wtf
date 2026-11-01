package cli

import (
	"bytes"
	"encoding/json"
)

// The API's JSON shapes (see API.md, "JSON shapes"), as far as the client
// reads them. Numbers stay json.Number so they print exactly as sent.
//
// Outside the unit routes the API gives a unit as its id only; such a unit
// decodes with only its ID, and e.decode fills in the rest from the unit
// families the client keeps (e.unitFamilies).

type ref struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Quantities, unit families and units are global (every tenant sees them)
// or the tenant's own; a tenant can turn quantities and families on and off
// (TENANTS.md). Lists and gets say whether they are available, what the
// default is, and the tenant's own choice (nil: it follows the default).

type quantity struct {
	ID        string       `json:"id"`
	Name      string       `json:"name"`
	Datatype  string       `json:"datatype"`
	Global    bool         `json:"global"`
	Available *bool        `json:"available"`
	Standard  bool         `json:"standard"`
	Choice    *bool        `json:"choice"`
	Families  []unitFamily `json:"families"`
}

type unitFamily struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Quantity  quantity `json:"quantity"`
	Global    bool     `json:"global"`
	Available *bool    `json:"available"`
	Standard  bool     `json:"standard"`
	Choice    *bool    `json:"choice"`
	Units     []unit   `json:"units"`
}

// isAvailable tells whether a quantity or family (by its available field)
// can be chosen; nil, from inside another object, counts as available.
func isAvailable(available *bool) bool {
	return available == nil || *available
}

type unit struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Symbol string `json:"symbol"`
	Global bool   `json:"global"`
	Family struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"family"`
	Quantity   quantity    `json:"quantity"`
	BaseFactor json.Number `json:"base_factor"`
	BaseOffset json.Number `json:"base_offset"`
}

// UnmarshalJSON reads a unit as an object, or as its id alone (a JSON
// string), which e.decode then fills in.
func (u *unit) UnmarshalJSON(data []byte) error {
	if len(data) > 0 && data[0] == '"' {
		*u = unit{}
		return json.Unmarshal(data, &u.ID)
	}
	type plain unit
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	return d.Decode((*plain)(u))
}

type display struct {
	Value json.Number `json:"value"`
	Unit  unit        `json:"unit"`
}

type attribute struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Datatype string   `json:"datatype"`
	Unit     *unit    `json:"unit"`
	UnitLock bool     `json:"unit_lock"`
	Options  []option `json:"options"`
}

type option struct {
	ID        string `json:"id"`
	Attribute string `json:"attribute"`
	Name      string `json:"name"`
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
	ID          string           `json:"id"`
	Name        string           `json:"name"`
	Parent      *string          `json:"parent"`
	Container   bool             `json:"container"`
	Path        []ref            `json:"path"`
	Attributes  []classAttribute `json:"attributes"`
	Photo       *attachment      `json:"photo"`
	Attachments []attachment     `json:"attachments"`
}

type classAttribute struct {
	Attribute      attribute       `json:"attribute"`
	AssignedTo     string          `json:"assigned_to"`
	Inherited      bool            `json:"inherited"`
	Default        json.RawMessage `json:"default"`
	DefaultDisplay *display        `json:"default_display"`
	Scope          string          `json:"scope"` // "item" or "stock": where its values live
	Required       bool            `json:"required"`
}

type location struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Name        string       `json:"name"`
	Parent      *string      `json:"parent"`
	Container   bool         `json:"container"`
	Path        []ref        `json:"path"`
	Photo       *attachment  `json:"photo"`
	Attachments []attachment `json:"attachments"`
}

type attachment struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	MediaType string `json:"media_type"`
	Size      int64  `json:"size"`
	Hash      string `json:"hash"`
}

type value struct {
	Attribute attribute       `json:"attribute"`
	Value     json.RawMessage `json:"value"`
	Display   *display        `json:"display"`
	IsDefault bool            `json:"is_default"`
}

// itemRow is an item in item_list (and, without stock, inside a stock row).
type itemRow struct {
	ID         string      `json:"id"`
	Code       string      `json:"code"`
	Name       string      `json:"name"`
	Class      string      `json:"class"`
	Unit       *unit       `json:"unit"`
	UnitLock   bool        `json:"unit_lock"`
	Stock      *stockTotal `json:"stock"`
	Incomplete bool        `json:"incomplete"`
	Photo      *attachment `json:"photo"`
}

type stockTotal struct {
	Total     json.Number `json:"total"`
	Display   *display    `json:"display"`
	Uncounted bool        `json:"uncounted"`
}

type item struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Name        string       `json:"name"`
	Class       class        `json:"class"`
	Unit        *unit        `json:"unit"`
	UnitLock    bool         `json:"unit_lock"`
	Values      []value      `json:"values"`
	Missing     []ref        `json:"missing"`
	Photo       *attachment  `json:"photo"`
	Attachments []attachment `json:"attachments"`
	Stock       []itemStock  `json:"stock"`
}

type itemStock struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Location    string       `json:"location"`
	Amount      *json.Number `json:"amount"`
	Display     *display     `json:"display"`
	Values      []value      `json:"values"`
	Missing     []ref        `json:"missing"`
	Photo       *attachment  `json:"photo"`
	Attachments []attachment `json:"attachments"`
}

type stock struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Item        itemRow      `json:"item"`
	Location    string       `json:"location"`
	Amount      *json.Number `json:"amount"`
	Display     *display     `json:"display"`
	Values      []value      `json:"values"`
	Missing     []ref        `json:"missing"`
	Photo       *attachment  `json:"photo"`
	Attachments []attachment `json:"attachments"`
}

type page[T any] struct {
	Total  int `json:"total"`
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
	Rows   []T `json:"rows"`
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
