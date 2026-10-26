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

type quantity struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Datatype   string `json:"datatype"`
	BaseUnit   *unit  `json:"base_unit"`
	Units      []unit `json:"units"`
	UnitGroups []ref  `json:"unit_groups"`
}

type unit struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Symbol     string      `json:"symbol"`
	Quantity   quantity    `json:"quantity"`
	BaseFactor json.Number `json:"base_factor"`
	BaseOffset json.Number `json:"base_offset"`
	IsBase     bool        `json:"is_base"`
}

type unitGroup struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Quantity quantity `json:"quantity"`
	BaseUnit *unit    `json:"base_unit"`
	Units    []unit   `json:"units"`
}

type display struct {
	Value json.Number `json:"value"`
	Unit  unit        `json:"unit"`
}

type attribute struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Datatype  string     `json:"datatype"`
	UnitGroup *unitGroup `json:"unit_group"`
	Options   []option   `json:"options"`
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
	Attachments []attachment     `json:"attachments"`
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
	Attachments []attachment `json:"attachments"`
}

type attachment struct {
	ID           string  `json:"id"`
	FileName     string  `json:"file_name"`
	ContentType  string  `json:"content_type"`
	Size         int64   `json:"size"`
	SHA256       string  `json:"sha256"`
	Caption      *string `json:"caption"`
	PrimaryPhoto bool    `json:"primary_photo"`
}

type value struct {
	Attribute attribute       `json:"attribute"`
	Value     json.RawMessage `json:"value"`
	Unit      *unit           `json:"unit"`
	Display   *display        `json:"display"`
	IsDefault bool            `json:"is_default"`
}

// itemRow is an item in item_list (and, without stock, inside a stock row).
type itemRow struct {
	ID         string      `json:"id"`
	Code       string      `json:"code"`
	Name       string      `json:"name"`
	Class      string      `json:"class"`
	UnitGroup  *unitGroup  `json:"unit_group"`
	Stock      *stockTotal `json:"stock"`
	Incomplete bool        `json:"incomplete"`
	Photo      *attachment `json:"photo"`
}

type stockTotal struct {
	Total     json.Number `json:"total"`
	Unit      *unit       `json:"unit"`
	Display   *display    `json:"display"`
	Uncounted bool        `json:"uncounted"`
}

type item struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Name        string       `json:"name"`
	Class       class        `json:"class"`
	UnitGroup   *unitGroup   `json:"unit_group"`
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
	Quantity    *json.Number `json:"quantity"`
	Display     *display     `json:"display"`
	Values      []value      `json:"values"`
	Missing     []ref        `json:"missing"`
	Attachments []attachment `json:"attachments"`
}

type stock struct {
	ID          string       `json:"id"`
	Code        string       `json:"code"`
	Item        itemRow      `json:"item"`
	Location    string       `json:"location"`
	Quantity    *json.Number `json:"quantity"`
	Unit        *unit        `json:"unit"`
	Display     *display     `json:"display"`
	Values      []value      `json:"values"`
	Missing     []ref        `json:"missing"`
	Attachments []attachment `json:"attachments"`
}

type page[T any] struct {
	Total  int `json:"total"`
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
	Rows   []T `json:"rows"`
}

type tenant struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Hostname string `json:"hostname"`
}

type account struct {
	ID               string  `json:"id"`
	Email            string  `json:"email"`
	HasPassword      bool    `json:"has_password"`
	DataPrivilege    string  `json:"data_privilege"`
	ModelPrivilege   string  `json:"model_privilege"`
	AccountPrivilege string  `json:"account_privilege"`
	HistoryPrivilege string  `json:"history_privilege"`
	Deleted          bool    `json:"deleted"`
	Tenant           *tenant `json:"tenant"`
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
