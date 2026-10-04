package main

import "strings"

// The parts of rush's plugin protocol this plugin uses, as rush sends and
// takes them (plugins/skills/write-rush-plugin/references/protocol.md in
// the rush repo).

// Input events, with the "input" capability.
const (
	evInputChanged = "input.changed"
	evInputSent    = "input.sent"
	evInputCleared = "input.cleared"
)

type uiSession struct {
	ID string `json:"id"`
}

type uiEvent struct {
	Kind    string     `json:"kind"`
	Session *uiSession `json:"session"`
	Text    string     `json:"text"`
}

// intercept is a message about to go: Box is whose message box it's in,
// a session's id or "" for the Prompt.
type intercept struct {
	Hook string `json:"hook"`
	UI   string `json:"ui"`
	Box  string `json:"box"`
	Text string `json:"text"`
	// Asks are the kinds of ask the window shows beside one with choices;
	// an older rush sends none.
	Asks []string `json:"asks,omitempty"`
}

// askInput, in an intercept's Asks, is an ask with a line of text to type,
// answered with keyEnter and what was typed.
const (
	askInput = "input"
	keyEnter = "enter"
)

// askLine is the line of text an ask has you type: what it starts as, why
// what was typed last wasn't taken, and what enter does with it.
type askLine struct {
	Value string `json:"value,omitempty"`
	Error string `json:"error,omitempty"`
	Enter string `json:"enter,omitempty"`
}

type interceptResult struct {
	Action   string        `json:"action"`
	Text     string        `json:"text,omitempty"`
	Replace  []replacement `json:"replace,omitempty"`
	Append   string        `json:"append,omitempty"`
	Reason   string        `json:"reason,omitempty"`
	ID       string        `json:"id,omitempty"`
	Question string        `json:"question,omitempty"`
	Detail   string        `json:"detail,omitempty"`
	Choices  []askChoice   `json:"choices,omitempty"`
	Input    *askLine      `json:"input,omitempty"`
}

type replacement struct {
	Old string `json:"old"`
	New string `json:"new"`
}

type askChoice struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Enter bool   `json:"enter,omitempty"`
	Esc   bool   `json:"esc,omitempty"`
}

// apply is text as r leaves it, as rush applies a rewrite.
func (r interceptResult) apply(text string) string {
	if r.Text != "" {
		return r.Text
	}
	for _, p := range r.Replace {
		if p.Old != "" {
			text = strings.ReplaceAll(text, p.Old, p.New)
		}
	}
	return text + r.Append
}
