package main

import (
	"context"
	"testing"
	"time"

	"golang.org/x/sys/windows/svc"
)

func TestServiceStop(t *testing.T) {
	s := &service{run: func(ctx context.Context) int {
		<-ctx.Done()
		return exitOK
	}}
	requests := make(chan svc.ChangeRequest)
	status := make(chan svc.Status, 10)
	type result struct {
		specific bool
		code     uint32
	}
	finished := make(chan result)
	go func() {
		specific, code := s.Execute(nil, requests, status)
		finished <- result{specific, code}
	}()

	if st := <-status; st.State != svc.StartPending {
		t.Fatalf("first state %v, want start pending", st.State)
	}
	if st := <-status; st.State != svc.Running || st.Accepts != svc.AcceptStop|svc.AcceptShutdown {
		t.Fatalf("second status %+v, want running, accepting stop and shutdown", st)
	}
	requests <- svc.ChangeRequest{Cmd: svc.Stop}
	select {
	case r := <-finished:
		if r.specific || r.code != 0 {
			t.Errorf("exit %+v, want none", r)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Stop didn't end the service")
	}
	if st := <-status; st.State != svc.StopPending {
		t.Errorf("state after Stop %v, want stop pending", st.State)
	}
}

func TestServiceFailure(t *testing.T) {
	s := &service{run: func(context.Context) int { return exitFailure }}
	status := make(chan svc.Status, 10)
	specific, code := s.Execute(nil, make(chan svc.ChangeRequest), status)
	if !specific || code != exitFailure || s.code != exitFailure {
		t.Errorf("exit (%v, %d), code %d; want a service-specific %d", specific, code, s.code, exitFailure)
	}
}

func TestEventLevel(t *testing.T) {
	for _, c := range []struct {
		text string
		want int
	}{
		{`time=2026-11-05T10:00:00.000+01:00 level=INFO msg=listening action=serve`, eventInfo},
		{`time=2026-11-05T10:00:00.000+01:00 level=DEBUG msg=request`, eventInfo},
		{`time=2026-11-05T10:00:00.000+01:00 level=WARN msg="slow query"`, eventWarning},
		{`time=2026-11-05T10:00:00.000+01:00 level=ERROR msg=failed error="level=INFO"`, eventError},
		{`wtfd serve: unexpected argument "x"`, eventError},
	} {
		if got := eventLevel(c.text, eventError); got != c.want {
			t.Errorf("eventLevel(%q) = %d, want %d", c.text, got, c.want)
		}
	}
}
