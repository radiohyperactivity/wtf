package schema

import (
	"strings"
	"testing"
	"testing/fstest"

	"github.com/radiohyperactivity/wtf/db"
)

func TestEmbeddedScriptsLoad(t *testing.T) {
	migrations, repeatables, err := loadScripts(db.Scripts)
	if err != nil {
		t.Fatal(err)
	}
	if len(migrations) == 0 || len(repeatables) == 0 {
		t.Fatalf("got %d migrations and %d repeatable scripts", len(migrations), len(repeatables))
	}
	if !strings.HasPrefix(repeatables[0].sql, "-- ") || !strings.Contains(repeatables[0].sql, "CREATE SCHEMA util;") {
		t.Errorf("the first repeatable script must create the util schema, got %s", repeatables[0].name)
	}
}

func TestLoadScripts(t *testing.T) {
	file := func(s string) *fstest.MapFile { return &fstest.MapFile{Data: []byte(s)} }

	tests := []struct {
		name    string
		fs      fstest.MapFS
		wantErr string
	}{
		{
			name: "ok",
			fs: fstest.MapFS{
				"migrations/0001_a.sql": file("SELECT 1;"),
				"migrations/0002_b.sql": file("SELECT 2;"),
				"repeatable/10_x.sql":   file("SELECT 3;"),
			},
		},
		{
			name: "gap",
			fs: fstest.MapFS{
				"migrations/0001_a.sql": file(""),
				"migrations/0003_c.sql": file(""),
				"repeatable/10_x.sql":   file(""),
			},
			wantErr: "expected version 0002",
		},
		{
			name: "bad name",
			fs: fstest.MapFS{
				"migrations/1_a.sql":  file(""),
				"repeatable/10_x.sql": file(""),
			},
			wantErr: "does not match",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, err := loadScripts(tt.fs)
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case tt.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tt.wantErr)):
				t.Fatalf("got error %v, want one containing %q", err, tt.wantErr)
			}
		})
	}
}

func TestChecksumIgnoresLineEndings(t *testing.T) {
	lf := fstest.MapFS{
		"migrations/0001_a.sql": {Data: []byte("SELECT 1;\nSELECT 2;\n")},
		"repeatable/10_x.sql":   {Data: []byte("")},
	}
	crlf := fstest.MapFS{
		"migrations/0001_a.sql": {Data: []byte("SELECT 1;\r\nSELECT 2;\r\n")},
		"repeatable/10_x.sql":   {Data: []byte("")},
	}
	a, _, err := loadScripts(lf)
	if err != nil {
		t.Fatal(err)
	}
	b, _, err := loadScripts(crlf)
	if err != nil {
		t.Fatal(err)
	}
	if string(a[0].checksum) != string(b[0].checksum) {
		t.Error("CRLF and LF versions have different checksums")
	}
}

func TestVerify(t *testing.T) {
	migrations := []script{
		{name: "0001_a.sql", version: 1, checksum: []byte{1}},
		{name: "0002_b.sql", version: 2, checksum: []byte{2}},
	}
	tests := []struct {
		name    string
		applied []appliedMigration
		wantErr string
	}{
		{name: "fresh"},
		{name: "partial", applied: []appliedMigration{{1, "0001_a.sql", []byte{1}}}},
		{name: "changed", applied: []appliedMigration{{1, "0001_a.sql", []byte{9}}}, wantErr: "was changed"},
		{name: "renamed", applied: []appliedMigration{{1, "0001_old.sql", []byte{1}}}, wantErr: "now named"},
		{
			name: "newer database",
			applied: []appliedMigration{
				{1, "0001_a.sql", []byte{1}}, {2, "0002_b.sql", []byte{2}}, {3, "0003_c.sql", []byte{3}},
			},
			wantErr: "use a newer wtfd",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := verify(migrations, tt.applied)
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case tt.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tt.wantErr)):
				t.Fatalf("got error %v, want one containing %q", err, tt.wantErr)
			}
		})
	}
}
