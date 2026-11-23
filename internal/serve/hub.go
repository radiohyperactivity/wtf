package serve

import (
	"encoding/json"
	"sync"
)

// hub is the open event streams (GET /me/events), by session id
// (sessionID), and which account each of those sessions is: an event goes
// to the streams of one session (send), as the camera's do, or to those of
// every session of an account (sendAccount), as a change of its
// preferences does. It lives in wtfd's memory; a stream that reconnects
// after a restart is registered again.
type hub struct {
	mu       sync.Mutex
	streams  map[string]map[*stream]bool // session → its open streams
	accounts map[string]map[string]bool  // account → its sessions with open streams
	account  map[string]string           // session with open streams → its account
	closed   bool                        // wtfd is shutting down
}

func newHub() *hub {
	return &hub{
		streams:  map[string]map[*stream]bool{},
		accounts: map[string]map[string]bool{},
		account:  map[string]string{},
	}
}

// event is one server-sent event: its name, and its data, JSON.
type event struct {
	name string
	data []byte
}

// eventData is v as an event's data.
func eventData(name string, v any) event {
	data, _ := json.Marshal(v)
	return event{name: name, data: data}
}

// stream is one open event stream of a session. Events wait in a short
// queue; a stream that falls that far behind is ended, and its app asks
// again for what it missed when it reconnects.
type stream struct {
	events chan event
	done   chan struct{}
	ended  bool // done is closed; the hub's lock guards it
}

func (st *stream) end() {
	if !st.ended {
		st.ended = true
		close(st.done)
	}
}

// open registers a new event stream of session, which is account's. It is
// nil when wtfd is shutting down.
func (h *hub) open(session, account string) *stream {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return nil
	}
	st := &stream{events: make(chan event, 16), done: make(chan struct{})}
	if h.streams[session] == nil {
		h.streams[session] = map[*stream]bool{}
	}
	h.streams[session][st] = true
	if h.accounts[account] == nil {
		h.accounts[account] = map[string]bool{}
	}
	h.accounts[account][session] = true
	h.account[session] = account
	return st
}

// close unregisters an event stream of session that has ended. A session
// without streams is no longer one of its account's.
func (h *hub) close(session string, st *stream) {
	h.mu.Lock()
	defer h.mu.Unlock()
	st.end()
	delete(h.streams[session], st)
	if len(h.streams[session]) > 0 {
		return
	}
	delete(h.streams, session)
	account := h.account[session]
	delete(h.account, session)
	delete(h.accounts[account], session)
	if len(h.accounts[account]) == 0 {
		delete(h.accounts, account)
	}
}

// send queues e on every open stream of session.
func (h *hub) send(session string, e event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sendLocked(session, e)
}

// sendTo queues e on st alone, as on a stream just opened, unless it has
// ended.
func (h *hub) sendTo(st *stream, e event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !st.ended {
		queue(st, e)
	}
}

// sendAccount queues e on every open stream of every session of account.
func (h *hub) sendAccount(account string, e event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for session := range h.accounts[account] {
		h.sendLocked(session, e)
	}
}

// sendLocked is send, with the lock held.
func (h *hub) sendLocked(session string, e event) {
	for st := range h.streams[session] {
		queue(st, e)
	}
}

// queue puts e on st's queue, or ends st when its queue is full; the lock
// is held.
func queue(st *stream, e event) {
	select {
	case st.events <- e:
	default:
		st.end()
	}
}

// end ends the streams of session, one that has ended.
func (h *hub) end(session string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for st := range h.streams[session] {
		st.end()
	}
}

// shutdown ends every stream, and refuses new ones, as wtfd stops.
func (h *hub) shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for _, streams := range h.streams {
		for st := range streams {
			st.end()
		}
	}
}
