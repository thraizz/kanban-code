// kanban-vault is a rush plugin that keeps secrets out of what you send:
// before a message holding one goes, it asks whether to save it to Kanban
// Code's vault, then under what name, saves it with kv, and the message
// goes with {{vault:NAME}} in its place. Detection is package secrets
// (LangWatch's redaction rules); the questions are rush's intercept asks,
// the answers ui.intercept.answer. A rush that can't show a line to type
// gets one question, with the name in it.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/langwatch/kanban-code/plugins/rush/kanban-vault/secrets"
)

// rules is what the vault tells an agent about a secret pasted into a
// prompt.
const rules = "Pasted into a chat prompt by the user; use it only for the task that prompt asks for, never print or copy it."

// namesFor is how long the vault's names, as last listed, are good for
// naming a secret in a question. A save lists them again first.
const namesFor = time.Minute

// vault is Kanban Code's vault, as the plugin uses it.
type vault interface {
	Names(ctx context.Context) ([]string, error)
	Add(ctx context.Context, name, value string) error
}

type app struct {
	conn  *conn
	vault vault

	mu      sync.Mutex
	names   []string
	namesAt time.Time
	listing bool
	asked   map[string]asked           // questions out, by id
	letGo   map[string]map[string]bool // secrets you said to send as they are, by box
	saved   map[string][32]byte        // what this run saved, by name: the value's hash
}

// asked is a question out about one secret: whether to save it, naming
// under what name to (typed, with why not, when the last one wasn't
// taken), or, failed, whether to send it as it is. Without input, the one
// question is to save it under name.
type asked struct {
	box, value, kind, suggested, name string
	failed, naming                    bool
	typed, why                        string
}

// vaultName is a name the plugin saves a secret under: an environment
// variable's, which is how kv run hands it to a command.
var vaultName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// maxName is the longest name the vault takes.
const maxName = 128

func main() {
	ipc := os.NewFile(3, "rush")
	if ipc == nil {
		fmt.Fprintln(os.Stderr, "run me from rush: I talk on fd 3")
		os.Exit(2)
	}
	<-serve(ipc).Done()
}

// serve runs the plugin on its connection to rush.
func serve(rw io.ReadWriteCloser) *conn {
	a := newApp(nil)
	ready := make(chan struct{})
	c := newConn(rw, func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		<-ready
		return a.handle(ctx, method, params)
	})
	a.conn, a.vault = c, kvExec{c}
	close(ready)
	return c
}

func newApp(v vault) *app {
	return &app{vault: v, asked: map[string]asked{}, letGo: map[string]map[string]bool{}, saved: map[string][32]byte{}}
}

func (a *app) handle(ctx context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "initialize":
		return map[string]any{}, nil
	case "tools.list":
		return map[string]any{"tools": []any{}}, nil
	case "ui.settings":
		return nil, nil
	case "ui.event":
		var ev uiEvent
		if json.Unmarshal(params, &ev) == nil {
			a.event(ev)
		}
		return nil, nil
	case "ui.intercept":
		var in intercept
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, &rpcError{Code: codeInvalidParams, Message: err.Error()}
		}
		return a.intercept(in), nil
	case "ui.intercept.answer":
		var in struct {
			intercept
			ID    string `json:"id"`
			Key   string `json:"key"`
			Value string `json:"value"`
		}
		if err := json.Unmarshal(params, &in); err != nil {
			return nil, &rpcError{Code: codeInvalidParams, Message: err.Error()}
		}
		return a.answer(ctx, in.intercept, in.ID, in.Key, in.Value), nil
	}
	return nil, &rpcError{Code: codeNoMethod, Message: "method not found: " + method}
}

// event lists the vault's names as soon as a secret is typed, so the
// question when it's sent can name it at once; a box sent or cleared
// forgets the secrets let go from it.
func (a *app) event(ev uiEvent) {
	box := ""
	if ev.Session != nil {
		box = ev.Session.ID
	}
	switch ev.Kind {
	case evInputChanged:
		if len(secrets.Find(ev.Text)) > 0 {
			a.listSoon()
		}
	case evInputSent, evInputCleared:
		a.mu.Lock()
		delete(a.letGo, box)
		a.mu.Unlock()
	}
}

// listSoon lists the vault's names in the background, unless they're
// fresh or already being listed.
func (a *app) listSoon() {
	a.mu.Lock()
	if a.listing || time.Since(a.namesAt) < namesFor {
		a.mu.Unlock()
		return
	}
	a.listing = true
	a.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		names, err := a.vault.Names(ctx)
		a.mu.Lock()
		defer a.mu.Unlock()
		a.listing = false
		if err == nil {
			a.names, a.namesAt = names, time.Now()
		}
	}()
}

// next is the first secret in text not let go from box.
func (a *app) next(box, text string) *secrets.Detected {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, d := range secrets.Find(text) {
		if !a.letGo[box][d.Value] {
			return &d
		}
	}
	return nil
}

// intercept asks about the first secret in the message, if there's one.
// It must answer at once, so a name it offers is free among the names
// last listed; a save checks again.
func (a *app) intercept(in intercept) interceptResult {
	d := a.next(in.Box, in.Text)
	if d == nil {
		return interceptResult{Action: "allow"}
	}
	a.listSoon()
	return a.offer(in, *d, interceptResult{})
}

// offer asks whether to save d, with the changes so far. The name comes
// in a question of its own, after a yes; a rush that can't show a line to
// type is asked about the first free name instead.
func (a *app) offer(in intercept, d secrets.Detected, changes interceptResult) interceptResult {
	q := asked{box: in.Box, value: d.Value, kind: d.Kind, suggested: d.SuggestedName}
	what := fmt.Sprintf("%s (%s)", hint(d.Value), strings.ReplaceAll(d.Kind, "_", " "))
	if slices.Contains(in.Asks, askInput) {
		changes.Question = "Save this secret to the vault?"
		changes.Detail = what + " is in your message · saved, it goes as a {{vault:NAME}} reference under the name you give it next, and agents use it through kv run"
	} else {
		q.name = a.free(q)
		changes.Question = "Save as vault secret " + q.name + "?"
		changes.Detail = fmt.Sprintf("your message has a secret: %s · saved, it goes as %s and agents use it through kv run", what, secrets.Ref(q.name))
	}
	changes.Action, changes.ID = "ask", a.remember(q)
	changes.Choices = []askChoice{{Key: "y", Label: "save it", Enter: true}, {Key: "n", Label: "send as is", Esc: true}}
	return changes
}

// free is the name to offer for q's secret: the one this run saved the
// same value under, else the first free one after the name suggested,
// among the names last listed.
func (a *app) free(q asked) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	sum := sha256.Sum256([]byte(q.value))
	for name, was := range a.saved {
		if was == sum {
			return name
		}
	}
	return secrets.UniqueName(q.suggested, a.names)
}

// naming asks for the name to save q's secret under, in a line that
// starts as q.typed: esc goes back to whether to save it.
func (a *app) naming(q asked) interceptResult {
	q.naming = true
	return interceptResult{Action: "ask", ID: a.remember(q),
		Question: "Name for the secret " + hint(q.value),
		Detail:   "the message goes with {{vault:NAME}} in its place · letters, digits and _, as an environment variable's",
		Input:    &askLine{Value: q.typed, Error: q.why, Enter: "save"},
		Choices:  []askChoice{{Key: "b", Label: "back", Esc: true}}}
}

// failed says why the secret couldn't be saved, and asks to send the
// message as it is or go back to it.
func (a *app) failed(q asked, err error, changes interceptResult) interceptResult {
	q.failed = true
	changes.Action, changes.ID = "ask", a.remember(q)
	changes.Question = "Couldn't save the secret to the vault"
	changes.Detail = err.Error()
	changes.Choices = []askChoice{{Key: "y", Label: "send as is"}, {Key: "n", Label: "back to the box", Esc: true}}
	return changes
}

func (a *app) remember(q asked) string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	id := hex.EncodeToString(b)
	a.mu.Lock()
	a.asked[id] = q
	a.mu.Unlock()
	return id
}

// answer acts on what was chosen in a question. To whether to save: y
// asks for the name (or, with no line to type, saves under the name
// offered) and n lets the secret go as it is. To the name: enter saves
// under what was typed and puts its reference in the secret's place, esc
// goes back. Then the next secret in the message is asked about, if
// there's one.
func (a *app) answer(ctx context.Context, in intercept, id, key, value string) interceptResult {
	a.mu.Lock()
	q, ok := a.asked[id]
	delete(a.asked, id)
	a.mu.Unlock()
	if !ok {
		return interceptResult{Action: "block", Reason: "the question was from before a restart: send it again"}
	}
	letGo := func() {
		a.mu.Lock()
		if a.letGo[q.box] == nil {
			a.letGo[q.box] = map[string]bool{}
		}
		a.letGo[q.box][q.value] = true
		a.mu.Unlock()
	}
	d := secrets.Detected{Value: q.value, Kind: q.kind, SuggestedName: q.suggested}
	switch {
	case q.failed && key == "y", !q.failed && !q.naming && key == "n":
		letGo()
		return a.then(in, interceptResult{})
	case q.failed:
		return interceptResult{Action: "block", Reason: "not sent; it's still in the box"}
	case q.naming && key != keyEnter:
		return a.offer(in, d, interceptResult{})
	case q.naming:
		q.typed, q.why = strings.TrimSpace(value), ""
		if q.why = badName(q.typed); q.why != "" {
			return a.naming(q)
		}
		q.name = q.typed
	case key != "y":
		return interceptResult{Action: "block", Reason: "no such answer: " + key}
	case slices.Contains(in.Asks, askInput):
		q.typed = a.free(q)
		return a.naming(q)
	}
	names, err := a.vault.Names(ctx)
	if err != nil {
		return a.failed(q, err, interceptResult{})
	}
	sum := sha256.Sum256([]byte(q.value))
	a.mu.Lock()
	a.names, a.namesAt = names, time.Now()
	was, mine := a.saved[q.name]
	a.mu.Unlock()
	if slices.Contains(names, q.name) {
		switch {
		case mine && was == sum:
			// Saved under this name already, by this run: the same secret again.
			return a.then(in, swap(in.Text, q.value, q.name))
		case q.naming:
			q.why = q.name + " is already in the vault: give this one another name"
			return a.naming(q)
		default:
			// Taken since it was offered: offer the next free one.
			return a.offer(in, d, interceptResult{})
		}
	}
	if err := a.vault.Add(ctx, q.name, q.value); err != nil {
		return a.failed(q, err, interceptResult{})
	}
	a.mu.Lock()
	a.names = append(slices.Clone(a.names), q.name)
	a.saved[q.name] = sum
	a.mu.Unlock()
	a.notify("saved " + q.name + " to the vault")
	return a.then(in, swap(in.Text, q.value, q.name))
}

// badName is why name can't be a secret's, or "" when it can.
func badName(name string) string {
	switch {
	case name == "":
		return "give it a name"
	case len(name) > maxName:
		return fmt.Sprintf("a name is at most %d characters", maxName)
	case !vaultName.MatchString(name):
		return "a name is letters, digits and _, and doesn't start with a digit"
	}
	return ""
}

// then is changes to in's text, asking about the next secret left in it
// if there's one.
func (a *app) then(in intercept, changes interceptResult) interceptResult {
	if d := a.next(in.Box, changes.apply(in.Text)); d != nil {
		return a.offer(in, *d, changes)
	}
	if len(changes.Replace) == 0 && changes.Append == "" {
		return interceptResult{Action: "allow"}
	}
	changes.Action = "rewrite"
	return changes
}

// swap is the change that puts name's reference in place of value in
// text, with the line on using it at the end: secrets.Replace, said as a
// replacement and what it appends, so rush keeps the box's paste chips.
func swap(text, value, name string) interceptResult {
	whole := secrets.Replace(text, value, name)
	replaced := strings.ReplaceAll(text, value, secrets.Ref(name))
	return interceptResult{Replace: []replacement{{Old: value, New: secrets.Ref(name)}}, Append: strings.TrimPrefix(whole, replaced)}
}

func (a *app) notify(text string) {
	if a.conn == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = a.conn.Call(ctx, "ui.notify", map[string]any{"text": text}, nil)
	}()
}

// hint names a secret without showing it: its first 4 characters and its
// length.
func hint(v string) string {
	r := []rune(v)
	return fmt.Sprintf("%s… %d chars", string(r[:min(4, len(r))]), len(r))
}

// kvExec is the vault through Kanban Code's kv CLI, which rush runs for
// the plugin as you (the manifest's exec), with your environment.
type kvExec struct{ conn *conn }

type execOut struct {
	Code   int    `json:"code"`
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
}

func (k kvExec) run(ctx context.Context, stdin string, args ...string) (string, error) {
	var out execOut
	if err := k.conn.Call(ctx, "exec", map[string]any{"name": "kv", "args": args, "stdin": stdin}, &out); err != nil {
		if msg := err.Error(); strings.Contains(msg, "fork/exec") && strings.Contains(msg, "no such file") {
			return "", errors.New("kv isn't installed: Kanban Code installs it in ~/.local/bin")
		}
		return "", err
	}
	if out.Code != 0 {
		if s := strings.TrimSpace(out.Stderr); s != "" {
			return out.Stdout, errors.New(strings.TrimPrefix(s, "kv: "))
		}
		return out.Stdout, fmt.Errorf("kv %s exited %d", args[0], out.Code)
	}
	return out.Stdout, nil
}

func (k kvExec) Names(ctx context.Context) ([]string, error) {
	out, err := k.run(ctx, "", "ls", "--json")
	if err != nil {
		return nil, err
	}
	var list []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil {
		return nil, fmt.Errorf("kv ls: %w", err)
	}
	names := make([]string, 0, len(list))
	for _, s := range list {
		names = append(names, s.Name)
	}
	slices.Sort(names)
	return names, nil
}

func (k kvExec) Add(ctx context.Context, name, value string) error {
	_, err := k.run(ctx, value, "add", name, "--tier", "judged", "--rules", rules)
	return err
}
