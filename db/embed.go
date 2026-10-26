// Package db embeds the SQL scripts that "wtfd schema" applies to the
// database: versioned migrations in migrations/ and repeatable scripts in
// repeatable/. See WTFD.md.
package db

import "embed"

// Scripts holds migrations/*.sql and repeatable/*.sql.
//
//go:embed migrations/*.sql repeatable/*.sql
var Scripts embed.FS
