package cli

import (
	"fmt"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// Interactive prompts. They are used only when stdin and stderr are a
// terminal; otherwise missing data is a usage error, as before.
//
// Missing required arguments and flags are asked for. Once the user has been
// asked for something, the session counts as interactive and optional data
// is offered too (the item's unit, the attributes of its class, a
// stock quantity), where Enter skips it.

// ask reads one value with completion from p. Required values are asked for
// again until something is entered.
func (e *env) ask(p param, args []string) (string, error) {
	return e.askLabel(p.name+": ", p, args)
}

func (e *env) askLabel(label string, p param, args []string) (string, error) {
	e.prompted = true
	var complete prompt.Completer
	if p.complete != nil {
		complete = func(input string) []string { return p.complete(e, args, input, true) }
	}
	for {
		v, err := e.term.ReadLine(label, "", complete)
		if err != nil {
			return "", err
		}
		if v = strings.TrimSpace(v); v != "" || p.optional {
			return v, nil
		}
	}
}

// askMissing asks for the required positional arguments that were not given.
func (e *env) askMissing(cmd *command, args *[]string) error {
	if e.term == nil {
		return nil
	}
	for i := len(*args); i < len(cmd.params) && !cmd.params[i].optional; i++ {
		v, err := e.ask(cmd.params[i], *args)
		if err != nil {
			return err
		}
		*args = append(*args, v)
	}
	return nil
}

// need asks for a required flag that was not given, or reports it missing.
func (e *env) need(value *string, flagName string, p param, args []string) error {
	if *value != "" {
		return nil
	}
	if e.term == nil {
		return usagef("--%s is required", flagName)
	}
	v, err := e.ask(p, args)
	*value = v
	return err
}

// offer asks for optional data in an interactive session; Enter skips it.
func (e *env) offer(label string, p param, args []string) (string, error) {
	if e.term == nil || !e.prompted {
		return "", nil
	}
	p.optional = true
	return e.askLabel(label+": ", p, args)
}

// askValues asks for attribute values of a class: item values, or with
// perUnit the values of a stock row. Required attributes without a value or
// default are always asked for (with a terminal); in an interactive session
// all others are offered too, required ones first.
func (e *env) askValues(classID string, perUnit bool, values object) error {
	if e.term == nil {
		return nil
	}
	interactive := e.prompted
	var c class
	if err := e.get("/classes/"+classID, nil, &c); err != nil {
		return err
	}
	var list []classAttribute
	for _, a := range c.Attributes {
		if _, given := values[a.Attribute.ID]; a.PerUnit == perUnit && !given {
			list = append(list, a)
		}
	}
	for _, required := range []bool{true, false} {
		for _, ca := range list {
			if ca.Required != required {
				continue
			}
			hasDefault := len(ca.Default) > 0 && string(ca.Default) != "null"
			must := ca.Required && !hasDefault
			if !must && !interactive {
				continue
			}
			v, err := e.askValue(ca, must)
			if err != nil {
				return err
			}
			if v != nil {
				values[ca.Attribute.ID] = v
			}
		}
	}
	return nil
}

// askValue reads one attribute value until it parses; nil means skipped.
func (e *env) askValue(ca classAttribute, must bool) (any, error) {
	a := ca.Attribute
	label := a.Name
	switch {
	case ca.DefaultDisplay != nil:
		label += " [" + formatDisplay(ca.DefaultDisplay) + "]"
	case len(ca.Default) > 0 && string(ca.Default) != "null":
		label += " [" + formatJSONValue(ca.Default) + "]"
	case must:
		label += " (required)"
	}
	if hint := valueHint(a); hint != "" {
		label += " " + hint
	}
	p := param{optional: !must, complete: func(e *env, _ []string, cur string, _ bool) []string {
		return e.valueCandidates(&a, cur)
	}}
	for {
		text, err := e.askLabel(label+": ", p, nil)
		if err != nil {
			return nil, err
		}
		if text == "" {
			return nil, nil
		}
		v, err := e.parseValue(&a, text)
		if err == nil {
			return v, nil
		}
		fmt.Fprintf(e.stderr, "%v\n", err)
	}
}

// valueHint tells what kind of value is expected.
func valueHint(a attribute) string {
	switch {
	case a.Unit != nil:
		return "(" + a.Unit.Symbol + ", or another unit of " + a.Unit.Family.Name + ")"
	case a.Datatype == "date":
		return "(YYYY-MM-DD, today, +N[d|w|m|y])"
	case a.Datatype == "boolean":
		return "(yes/no)"
	case a.Datatype == "choice":
		return "(Tab Tab: options)"
	}
	return ""
}
