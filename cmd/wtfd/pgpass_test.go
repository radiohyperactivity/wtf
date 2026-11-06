package main

import "testing"

func TestPgpassLine(t *testing.T) {
	got := pgpassLine("db.example", 5432, "wtf", "wtf_api", `pa:ss\word`)
	if want := `db.example:5432:wtf:wtf_api:pa\:ss\\word`; got != want {
		t.Errorf("pgpassLine = %q, want %q", got, want)
	}
}

func TestMergePgpass(t *testing.T) {
	old := "# mine\r\n" +
		"other:5432:x:y:keep\r\n" +
		`db:5432:wtf:wtf_api:old\:one` + "\r\n"
	got := mergePgpass(old, []string{
		"db:5432:wtf:wtf_dba:new-dba",
		"db:5432:wtf:wtf_api:new-api",
	})
	want := "# mine\n" +
		"other:5432:x:y:keep\n" +
		"db:5432:wtf:wtf_api:new-api\n" +
		"db:5432:wtf:wtf_dba:new-dba\n"
	if got != want {
		t.Errorf("mergePgpass =\n%s\nwant\n%s", got, want)
	}
	if got := mergePgpass("", []string{"a:1:b:c:d"}); got != "a:1:b:c:d\n" {
		t.Errorf("into an empty file: %q", got)
	}
}
