// Package openapi embeds the OpenAPI description of the REST API, served by
// "wtfd serve" at GET /openapi.yaml.
package openapi

import _ "embed"

// Spec is openapi.yaml.
//
//go:embed openapi.yaml
var Spec []byte
