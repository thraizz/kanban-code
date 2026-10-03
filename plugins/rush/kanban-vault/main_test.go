package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/langwatch/kanban-code/plugins/rush/kanban-vault/secrets"
)

type fakeVault struct {
	mu     sync.Mutex
	names  []string
	added  map[string]string
	lsErr  error
	addErr error
}

func (v *fakeVault) Names(context.Context) ([]string, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return slices.Clone(v.names), v.lsErr
}

func (v *fakeVault) setNames(names ...string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.names = names
}

func (v *fakeVault) Add(_ context.Context, name, value string) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.addErr != nil {
		return v.addErr
	}
	if v.added == nil {
		v.added = map[string]string{}
	}
	v.added[name] = value
	v.names = append(v.names, name)
	return nil
}

var key = "sk-proj-" + strings.Repeat("Ab3dEf7gHi2jKlMn", 3)

func TestNothingToAskAbout(t *testing.T) {
	a := newApp(&fakeVault{})
	if r := a.intercept(intercept{Text: "set OPENAI_API_KEY=sk-1234 and <your-key>"}); r.Action != "allow" {
		t.Fatalf("got %+v", r)
	}
}

// The name offered can be taken by the time you say y: the save offers
// the next free one instead.
func TestTakenNameIsOfferedAgain(t *testing.T) {
	v := &fakeVault{}
	a := newApp(v)
	ask := a.intercept(intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key})
	if ask.Question != "Save as vault secret OPENAI_API_KEY?" {
		t.Fatalf("ask %+v", ask)
	}
	v.setNames("OPENAI_API_KEY")
	again := a.answer(context.Background(), intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key}, ask.ID, "y")
	if again.Action != "ask" || again.Question != "Save as vault secret OPENAI_API_KEY_2?" || len(v.added) != 0 {
		t.Fatalf("again %+v", again)
	}
	done := a.answer(context.Background(), intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key}, again.ID, "y")
	if done.Action != "rewrite" || v.added["OPENAI_API_KEY_2"] != key {
		t.Fatalf("done %+v, added %v", done, v.added)
	}
	if got := done.apply("OPENAI_API_KEY=" + key); got != secrets.Replace("OPENAI_API_KEY="+key, key, "OPENAI_API_KEY_2") {
		t.Fatalf("sent %q", got)
	}
	// The next secret's question knows the name just saved.
	if next := a.intercept(intercept{Box: "s1", Text: "OPENAI_API_KEY=" + key + "x"}); next.Question != "Save as vault secret OPENAI_API_KEY_3?" {
		t.Fatalf("next %+v", next)
	}
}

// A secret you let go isn't asked about again in that box until it's sent
// or cleared.
func TestLetGoUntilSent(t *testing.T) {
	a := newApp(&fakeVault{})
	in := intercept{Box: "s1", Text: "use " + key}
	ask := a.intercept(in)
	if r := a.answer(context.Background(), in, ask.ID, "n"); r.Action != "allow" {
		t.Fatalf("n = %+v", r)
	}
	if r := a.intercept(in); r.Action != "allow" {
		t.Fatalf("asked again: %+v", r)
	}
	if r := a.intercept(intercept{Box: "s2", Text: in.Text}); r.Action != "ask" {
		t.Fatal("another box is asked")
	}
	a.event(uiEvent{Kind: evInputSent, Session: &uiSession{ID: "s1"}})
	if r := a.intercept(in); r.Action != "ask" {
		t.Fatal("sent, the box is asked about again")
	}
}

func TestMissingVault(t *testing.T) {
	a := newApp(&fakeVault{lsErr: errors.New("kv isn't installed: Kanban Code installs it in ~/.local/bin")})
	in := intercept{Text: "use " + key}
	ask := a.intercept(in)
	r := a.answer(context.Background(), in, ask.ID, "y")
	if r.Action != "ask" || r.Question != "Couldn't save the secret to the vault" || !strings.Contains(r.Detail, "kv isn't installed") {
		t.Fatalf("got %+v", r)
	}
	if back := a.answer(context.Background(), in, r.ID, "n"); back.Action != "block" {
		t.Fatalf("n after a failure = %+v", back)
	}
}

func TestStaleQuestion(t *testing.T) {
	a := newApp(&fakeVault{})
	if r := a.answer(context.Background(), intercept{Text: key}, "nope", "y"); r.Action != "block" {
		t.Fatalf("got %+v", r)
	}
}

func TestHint(t *testing.T) {
	if h := hint(key); h != "sk-p… 56 chars" {
		t.Fatal(h)
	}
}

// swap says secrets.Replace as a replacement and what it appends, a usage
// line under one already there.
func TestSwap(t *testing.T) {
	text := "a " + key
	once := swap(text, key, "A").apply(text)
	if once != secrets.Replace(text, key, "A") {
		t.Fatalf("once %q", once)
	}
	other := "ghp_" + strings.Repeat("Zq7Wx3Rt9", 4)
	twice := swap(once+" "+other, other, "B")
	if !strings.HasPrefix(twice.Append, "\n") || twice.apply(once+" "+other) != secrets.Replace(once+" "+other, other, "B") {
		t.Fatalf("twice %+v", twice)
	}
}

// The plugin over its connection, with the test as rush: a pasted key is
// asked about, y saves it with kv (run by rush's exec, given the key on
// stdin) and the message goes with its reference and the line on using it.
func TestOverTheWire(t *testing.T) {
	mine, theirs := net.Pipe()
	plug := serve(theirs)
	t.Cleanup(func() { mine.Close(); plug.Close() })

	var mu sync.Mutex
	stored := map[string]string{"OPENAI_API_KEY": "taken"}
	var notes []string
	rush := newConn(mine, func(_ context.Context, method string, params json.RawMessage) (any, error) {
		mu.Lock()
		defer mu.Unlock()
		switch method {
		case "exec":
			var in struct {
				Name  string   `json:"name"`
				Args  []string `json:"args"`
				Stdin string   `json:"stdin"`
			}
			_ = json.Unmarshal(params, &in)
			if in.Name != "kv" {
				return nil, errors.New("not in the manifest: " + in.Name)
			}
			switch in.Args[0] {
			case "ls":
				var list []map[string]string
				for n := range stored {
					list = append(list, map[string]string{"name": n})
				}
				b, _ := json.Marshal(list)
				return execOut{Stdout: string(b)}, nil
			case "add":
				if !slices.Contains(in.Args, "judged") {
					return execOut{Code: 2, Stderr: "kv: no tier"}, nil
				}
				stored[in.Args[1]] = in.Stdin
				return execOut{}, nil
			}
			return execOut{Code: 2, Stderr: "kv: no such command"}, nil
		case "ui.notify":
			var in struct{ Text string }
			_ = json.Unmarshal(params, &in)
			notes = append(notes, in.Text)
			return map[string]any{}, nil
		}
		return nil, errors.New("unexpected " + method)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	text := "deploy with " + key + " please"
	var ask interceptResult
	if err := rush.Call(ctx, "ui.intercept", intercept{Hook: "before-send", UI: "main", Box: "s1", Text: text}, &ask); err != nil {
		t.Fatal(err)
	}
	if ask.Action != "ask" || !strings.HasPrefix(ask.Question, "Save as vault secret OPENAI_API_KEY") || strings.Contains(ask.Detail, key) {
		t.Fatalf("ask = %+v", ask)
	}
	// Asked before the vault's names were listed, it offers the name again
	// once a save finds it taken.
	res := ask
	for range 2 {
		q := res
		answer := map[string]any{"hook": "before-send", "ui": "main", "box": "s1", "text": q.apply(text), "id": q.ID, "key": "y"}
		if err := rush.Call(ctx, "ui.intercept.answer", answer, &res); err != nil {
			t.Fatal(err)
		}
		if res.Action != "ask" {
			break
		}
		if res.Question != "Save as vault secret OPENAI_API_KEY_2?" {
			t.Fatalf("offered again = %+v", res)
		}
	}
	sent := res.apply(text)
	if res.Action != "rewrite" || strings.Contains(sent, key) || !strings.Contains(sent, "deploy with {{vault:OPENAI_API_KEY_2}} please") ||
		!strings.Contains(sent, "kv run OPENAI_API_KEY_2") {
		t.Fatalf("after y = %+v", res)
	}
	mu.Lock()
	defer mu.Unlock()
	if stored["OPENAI_API_KEY_2"] != key {
		t.Fatalf("kv was given %q", stored["OPENAI_API_KEY_2"])
	}
}
