package serve

import "testing"

// An event for an account goes to every stream of every session of it,
// and to no other account's; a session whose last stream closed is no
// longer one of its account's.
func TestHubAccounts(t *testing.T) {
	h := newHub()
	pc := h.open("pc", "anna")
	tab1 := h.open("browser", "anna")
	tab2 := h.open("browser", "anna")
	other := h.open("phone", "bob")

	h.sendAccount("anna", eventData("preferences", map[string]string{}))
	for _, st := range []*stream{pc, tab1, tab2} {
		if got := next(t, st); got != "preferences {}" {
			t.Fatalf("preferences: %s", got)
		}
	}
	none(t, other)

	// One session's event goes to its streams alone.
	h.send("browser", eventData("changed", map[string]string{"path": "/items/1"}))
	next(t, tab1)
	next(t, tab2)
	none(t, pc)

	h.close("browser", tab1)
	if !h.accounts["anna"]["browser"] {
		t.Fatal("the browser has a stream still")
	}
	h.close("browser", tab2)
	h.close("pc", pc)
	if len(h.accounts) != 1 || len(h.account) != 1 || len(h.streams) != 1 {
		t.Fatalf("after closing: %v %v %v", h.accounts, h.account, h.streams)
	}

	// An ended session's streams end, and so does every stream at shutdown,
	// after which none opens.
	h.end("phone")
	if !other.ended {
		t.Fatal("the ended session's stream is open")
	}
	late := h.open("pc", "anna")
	h.shutdown()
	if !late.ended || h.open("pc", "anna") != nil {
		t.Fatal("open after shutdown")
	}
}
