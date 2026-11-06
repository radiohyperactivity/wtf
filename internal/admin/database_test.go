package admin

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
)

// The example exchange of RFC 7677, section 3: user "user", password
// "pencil". The server's signature in it proves the server key.
func TestScramVerifier(t *testing.T) {
	salt, _ := base64.StdEncoding.DecodeString("W22ZaJ0SNY7soEsUEjb6gQ==")
	v := scramVerifier("pencil", salt)

	head, keys, ok := strings.Cut(v, "$")
	if !ok || head != "SCRAM-SHA-256" {
		t.Fatalf("verifier %q doesn't start with SCRAM-SHA-256$", v)
	}
	params, keyPair, _ := strings.Cut(keys, "$")
	if params != "4096:W22ZaJ0SNY7soEsUEjb6gQ==" {
		t.Errorf("iterations and salt %q", params)
	}
	storedB64, serverB64, _ := strings.Cut(keyPair, ":")
	serverKey, _ := base64.StdEncoding.DecodeString(serverB64)
	storedKey, _ := base64.StdEncoding.DecodeString(storedB64)

	const authMessage = "n=user,r=rOprNGfwEbeRWgbNEkqO," +
		"r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096," +
		"c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
	mac := hmac.New(sha256.New, serverKey)
	mac.Write([]byte(authMessage))
	if got := base64.StdEncoding.EncodeToString(mac.Sum(nil)); got != "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=" {
		t.Errorf("server signature %s, want RFC 7677's", got)
	}

	// The client's proof is its key XOR a signature with the stored key;
	// the stored key is the hash of the client's key.
	proof, _ := base64.StdEncoding.DecodeString("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
	mac = hmac.New(sha256.New, storedKey)
	mac.Write([]byte(authMessage))
	signature := mac.Sum(nil)
	clientKey := make([]byte, len(proof))
	for i := range proof {
		clientKey[i] = proof[i] ^ signature[i]
	}
	if sum := sha256.Sum256(clientKey); !hmac.Equal(sum[:], storedKey) {
		t.Error("the stored key doesn't match RFC 7677's client proof")
	}

	if a, b := scramVerifier("pencil", nil), scramVerifier("pencil", nil); a == b {
		t.Error("two verifiers without a salt are the same; the salt isn't random")
	}
}

func TestCheckPassword(t *testing.T) {
	for p, ok := range map[string]bool{
		"short":                 false,
		"long enough":           true,
		"with: colons \\ and '": true,
		"blåbærsyltetøy":        false,
		"tab\there!":            false,
	} {
		if err := CheckPassword(p); (err == nil) != ok {
			t.Errorf("CheckPassword(%q) = %v", p, err)
		}
	}
}

func TestScript(t *testing.T) {
	d := NewDatabase{Name: "wtf", DBAUser: "wtf_dba", APIUser: "wtf_api", ICULocale: "nb", APIConnectionLimit: 20,
		DBAPassword: "never printed", APIPassword: "never printed"}
	s := d.Script("postgres")
	for _, want := range []string{
		`CREATE ROLE "wtf_dba"`,
		"CONNECTION LIMIT 20;",
		`\password "wtf_dba"`,
		`OWNER           "wtf_dba"`,
		`ICU_LOCALE      'nb';`,
		`ALTER ROLE "wtf_api" IN DATABASE "wtf" SET statement_timeout = '30s';`,
		`\connect "wtf"`,
		`SET ROLE "wtf_dba";`,
		`GRANT CONNECT ON DATABASE "wtf" TO "wtf_api";`,
		"REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;",
		"RESET ROLE;",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("script lacks %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "PASSWORD") || strings.Contains(s, "never printed") {
		t.Errorf("script has a password:\n%s", s)
	}
	// The order matters: the roles before the database, and the default
	// privileges before any function exists.
	if strings.Index(s, "CREATE ROLE") > strings.Index(s, "CREATE DATABASE") ||
		strings.Index(s, "CREATE DATABASE") > strings.Index(s, `\connect`) {
		t.Errorf("script out of order:\n%s", s)
	}
	quoted := NewDatabase{Name: `my "db"`, ICULocale: "it's"}
	if s := quoted.createStatement(); !strings.Contains(s, `"my ""db"""`) || !strings.Contains(s, `'it''s'`) {
		t.Errorf("names not quoted: %s", s)
	}
}
