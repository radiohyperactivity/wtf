// Package openapi embeds the OpenAPI description of the REST API, served by
// "wtfd serve" at GET /api/v1/openapi, as JSON or, when asked for, as YAML
// (JSON is valid YAML).
package openapi

import _ "embed"

// Spec is openapi.json.
//
//go:embed openapi.json
var Spec []byte
