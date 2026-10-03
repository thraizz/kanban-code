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
