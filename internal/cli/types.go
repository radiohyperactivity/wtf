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

// Quantities, unit families and units have integer ids.

type quantity struct {
	ID       int          `json:"id"`
	Name     string       `json:"name"`
	Datatype string       `json:"datatype"`
	Families []unitFamily `json:"families"`
}

type unitFamily struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Quantity quantity `json:"quantity"`
	Units    []unit   `json:"units"`
}

type unit struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Symbol string `json:"symbol"`
	Family struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	} `json:"family"`
	Quantity   quantity    `json:"quantity"`
	BaseFactor json.Number `json:"base_factor"`
	BaseOffset json.Number `json:"base_offset"`
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
	Deleted  bool     `json:"deleted"`
}

type option struct {
	ID        string `json:"id"`
	Attribute string `json:"attribute"`
	Name      string `json:"name"`
	Deleted   bool   `json:"deleted"`
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
	Deleted     bool             `json:"deleted"`
}

type classAttribute struct {
	Attribute      attribute       `json:"attribute"`
	DefinedOnClass string          `json:"defined_on_class"`
	Inherited      bool            `json:"inherited"`
	Default        json.RawMessage `json:"default"`
	DefaultDisplay *display        `json:"default_display"`
	PerUnit        bool            `json:"per_unit"`
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
	Deleted     bool         `json:"deleted"`
}

type attachment struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Type  string `json:"type"`
	Size  int64  `json:"size"`
	Hash  string `json:"hash"`
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
	Deleted    bool        `json:"deleted"`
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
	Deleted     bool         `json:"deleted"`
}

type itemStock struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Location    string       `json:"location"`
	Quantity    *json.Number `json:"quantity"`
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
	Quantity    *json.Number `json:"quantity"`
	Display     *display     `json:"display"`
	Values      []value      `json:"values"`
	Missing     []ref        `json:"missing"`
	Photo       *attachment  `json:"photo"`
	Attachments []attachment `json:"attachments"`
	Deleted     bool         `json:"deleted"`
	MergedInto  *struct {
		ID   string `json:"id"`
		Code string `json:"code"`
	} `json:"merged_into"`
}

type page[T any] struct {
	Total  int `json:"total"`
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
	Rows   []T `json:"rows"`
}

type account struct {
	ID               string `json:"id"`
	Email            string `json:"email"`
	HasPassword      bool   `json:"has_password"`
	DataPrivilege    string `json:"data_privilege"`
	ModelPrivilege   string `json:"model_privilege"`
	AccountPrivilege string `json:"account_privilege"`
	HistoryPrivilege string `json:"history_privilege"`
	Deleted          bool   `json:"deleted"`
}

type historyEntry struct {
	ID          json.Number                `json:"id"`
	HappenedAt  string                     `json:"happened_at"`
	Transaction string                     `json:"transaction"`
	Account     *account                   `json:"account"`
	Table       string                     `json:"table"`
	Operation   string                     `json:"operation"`
	Data        map[string]json.RawMessage `json:"data"`
	Changes     map[string]json.RawMessage `json:"changes"`
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
