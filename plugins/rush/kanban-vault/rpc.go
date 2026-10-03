package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"sync"
)

// rush speaks JSON-RPC 2.0 to a plugin on fd 3, each message a 4-byte
// big-endian length and then that many bytes of JSON.

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return e.Message }

const (
	codeInvalidParams = -32602
	codeNoMethod      = -32601
)

type message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// handler answers a request from rush, or takes a notification.
type handler func(ctx context.Context, method string, params json.RawMessage) (any, error)

// conn is the plugin's end of its connection to rush.
type conn struct {
	rw io.ReadWriteCloser
	h  handler

	wmu sync.Mutex

	pmu     sync.Mutex
	nextID  int
	pending map[string]chan message

	done chan struct{}
}

func newConn(rw io.ReadWriteCloser, h handler) *conn {
	c := &conn{rw: rw, h: h, pending: map[string]chan message{}, done: make(chan struct{})}
	go c.read()
	return c
}

// Done closes when rush closes the connection.
func (c *conn) Done() <-chan struct{} { return c.done }

func (c *conn) Close() error { return c.rw.Close() }

// Call calls rush and decodes its result into out (nil to ignore it).
func (c *conn) Call(ctx context.Context, method string, params, out any) error {
	p, err := json.Marshal(params)
	if err != nil {
		return err
	}
	c.pmu.Lock()
	c.nextID++
	id := strconv.Itoa(c.nextID)
	ch := make(chan message, 1)
	c.pending[id] = ch
	c.pmu.Unlock()
	defer func() {
		c.pmu.Lock()
		delete(c.pending, id)
		c.pmu.Unlock()
	}()
	if err := c.send(message{ID: json.RawMessage(id), Method: method, Params: p}); err != nil {
		return err
	}
	select {
	case m := <-ch:
		if m.Error != nil {
			return m.Error
		}
		if out == nil || len(m.Result) == 0 {
			return nil
		}
		return json.Unmarshal(m.Result, out)
	case <-ctx.Done():
		return ctx.Err()
	case <-c.done:
		return errors.New("rush closed the connection")
	}
}

func (c *conn) send(m message) error {
	m.JSONRPC = "2.0"
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	buf := make([]byte, 4+len(b))
	binary.BigEndian.PutUint32(buf, uint32(len(b)))
	copy(buf[4:], b)
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err = c.rw.Write(buf)
	return err
}

func (c *conn) read() {
	defer close(c.done)
	r := bufio.NewReader(c.rw)
	for {
		var hdr [4]byte
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			return
		}
		body := make([]byte, binary.BigEndian.Uint32(hdr[:]))
		if _, err := io.ReadFull(r, body); err != nil {
			return
		}
		var m message
		if json.Unmarshal(body, &m) != nil {
			continue
		}
		if m.Method == "" {
			c.pmu.Lock()
			ch := c.pending[string(m.ID)]
			c.pmu.Unlock()
			if ch != nil {
				ch <- m
			}
			continue
		}
		// Notifications run in order; requests concurrently.
		if len(m.ID) == 0 {
			_, _ = c.h(context.Background(), m.Method, m.Params)
			continue
		}
		go func() {
			res, err := c.h(context.Background(), m.Method, m.Params)
			out := message{ID: m.ID}
			if err != nil {
				var re *rpcError
				if !errors.As(err, &re) {
					re = &rpcError{Code: -32000, Message: err.Error()}
				}
				out.Error = re
			} else {
				if res == nil {
					res = map[string]any{}
				}
				b, err := json.Marshal(res)
				if err != nil {
					out.Error = &rpcError{Code: -32000, Message: fmt.Sprint("result: ", err)}
				}
				out.Result = b
			}
			_ = c.send(out)
		}()
	}
}
