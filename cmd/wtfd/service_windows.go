package main

import (
	"context"
	"fmt"
	"strings"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
)

// eventSource is the name wtfd logs under in the Windows Event Log
// (Application). "wtfd service install" registers it.
const eventSource = "wtfd"

// runService runs wtfd as a Windows service when the Service Control
// Manager started it, and reports false otherwise. The service's command
// line is an ordinary one ("wtfd serve --files-directory …"). Output goes
// to the Event Log, as a service has no console.
func runService(args []string) (int, bool) {
	isService, err := svc.IsWindowsService()
	if err != nil || !isService {
		return 0, false
	}
	elog, err := eventlog.Open(eventSource)
	if err != nil {
		return exitFailure, true
	}
	defer elog.Close()

	s := &service{
		run: func(ctx context.Context) int {
			return run(ctx, args, eventWriter{elog, eventInfo}, eventWriter{elog, eventError})
		},
	}
	if err := svc.Run(eventSource, s); err != nil {
		elog.Error(1, fmt.Sprintf("wtfd: running as a service: %v", err))
		return exitFailure, true
	}
	return s.code, true
}

// service answers the Service Control Manager while run runs. Stop and
// Shutdown cancel run's context, which stops "serve" as SIGTERM does.
type service struct {
	run  func(ctx context.Context) int
	code int // run's exit code
}

func (s *service) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan int, 1)
	go func() { done <- s.run(ctx) }()
	running := svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	status <- running

	for {
		select {
		case s.code = <-done:
			// A failure is reported as a service-specific exit code, so
			// that the service's recovery actions apply to it (with
			// "sc.exe failureflag wtfd 1").
			if s.code != exitOK {
				return true, uint32(s.code)
			}
			return false, 0
		case r := <-requests:
			switch r.Cmd {
			case svc.Interrogate:
				status <- r.CurrentStatus
			case svc.Stop, svc.Shutdown:
				// serve waits up to 30 seconds for requests to finish.
				status <- svc.Status{State: svc.StopPending, WaitHint: 35_000}
				cancel()
			}
		}
	}
}

// The levels of Event Log entries.
const (
	eventInfo = iota
	eventWarning
	eventError
)

// eventWriter writes each Write as one Event Log entry. A log line's level
// (slog's "level=WARN") picks the entry's level; other text gets fallback,
// which is an error for what would have gone to stderr.
type eventWriter struct {
	log      *eventlog.Log
	fallback int
}

func (w eventWriter) Write(p []byte) (int, error) {
	text := strings.TrimRight(string(p), "\r\n")
	var err error
	switch eventLevel(text, w.fallback) {
	case eventError:
		err = w.log.Error(1, text)
	case eventWarning:
		err = w.log.Warning(1, text)
	default:
		err = w.log.Info(1, text)
	}
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

// eventLevel is the Event Log level of text: that of its slog level, or
// fallback for text that isn't a log line.
func eventLevel(text string, fallback int) int {
	_, rest, ok := strings.Cut(text, " level=")
	if !ok || !strings.HasPrefix(text, "time=") {
		return fallback
	}
	level, _, _ := strings.Cut(rest, " ")
	switch {
	case strings.HasPrefix(level, "ERROR"):
		return eventError
	case strings.HasPrefix(level, "WARN"):
		return eventWarning
	default:
		return eventInfo
	}
}
