// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Package gtty is the gtty SDK for Go (standard library only).
//
// AI assistants: read AGENTS.md first; examples/hosts is a complete
// extension.
//
// An extension is a value with any of these methods (each optional):
//
//	OnGttyStart(ext *gtty.Ext) error       once, when it starts
//	OnWindowStart(win *gtty.Window) error  each window: open ones, then new
//	OnWindowClose(win *gtty.Window) error  a notice: the window is gone
//	OnGttyClose(ext *gtty.Ext) error       a notice: gtty is closing
//	OnEvent(win *gtty.Window, ev *gtty.Event) error
//
// and main calls gtty.Run(ext). gtty starts the program
// (docs/protocol.md); callbacks run one at a time on Run's goroutine.
// Log may be called from any goroutine; nothing else may.
package gtty

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"

	"sync"
)

// APIVersion is the protocol version this SDK speaks.
const APIVersion = 1

// M is an update or part of one: a key left out stays as it is, a nil
// value clears it.
type M = map[string]any

// The errors gtty answers calls with; compare with errors.Is.
var (
	ErrWindowClosed  = errors.New("WindowClosed")
	ErrNoChip        = errors.New("NoChip")
	ErrBadName       = errors.New("BadName")
	ErrNoFile        = errors.New("NoFile")
	ErrFileInUse     = errors.New("FileInUse")
	ErrFileClosed    = errors.New("FileClosed")
	ErrStorageFull   = errors.New("StorageFull")
	ErrStorageFailed = errors.New("StorageFailed")
)

var errorsByName = map[string]error{}

func init() {
	for _, e := range []error{ErrWindowClosed, ErrNoChip, ErrBadName, ErrNoFile, ErrFileInUse, ErrFileClosed, ErrStorageFull, ErrStorageFailed} {
		errorsByName[e.Error()] = e
	}
}

// Part is one part of a text; empty fields take gtty's default.
type Part struct {
	String string `json:"string"`
	Fg     string `json:"fg,omitempty"` // "#rrggbb"; see RGB
	Bk     string `json:"bk,omitempty"`
	Size   int    `json:"size,omitempty"` // percent, 50-200
	Bold   bool   `json:"bold,omitempty"`
	Stroke bool   `json:"stroke,omitempty"` // a line through the text
}

// RGB is a color 0xrrggbb as gtty takes it.
func RGB(c uint32) string { return fmt.Sprintf("#%06x", c&0xffffff) }

// Text is a text of parts (at most 8). A plain string works wherever a
// text goes, too: gtty.Text(gtty.Part{String: "a"}, gtty.Part{String: "b", Bold: true}).
func Text(parts ...Part) []Part {
	if len(parts) > 8 {
		parts = parts[:8]
	}
	return parts
}

// ButtonClick is a button pressed. For a dialog ID is ok, cancel, yes, no,
// or kill / timeout (the dialog is already closed, no Fields).
type ButtonClick struct {
	ID       string       `json:"id"`
	Text     string       `json:"text"`
	Data     string       `json:"data"`
	Function string       `json:"function"`
	Fields   []FieldValue `json:"fields"`
	Command  bool         `json:"command"`
}

// FieldValue is a dialog widget's value: a string, or a bool for a check box.
type FieldValue struct {
	ID    string `json:"id"`
	Value any    `json:"value"`
}

// Field is a text box's or drop box's value.
func (b *ButtonClick) Field(id string) (string, bool) {
	for _, f := range b.Fields {
		if s, ok := f.Value.(string); ok && f.ID == id {
			return s, true
		}
	}
	return "", false
}

// Checked is a check box's value.
func (b *ButtonClick) Checked(id string) bool {
	for _, f := range b.Fields {
		if v, ok := f.Value.(bool); ok && f.ID == id {
			return v
		}
	}
	return false
}

// Event is what reaches OnEvent. Kind: window_changed, command_started, key
// or button_click (Button set).
type Event struct {
	EventID uint32 `json:"eventId"`
	Kind    string `json:"kind"`
	Folder  string `json:"folder"`
	Branch  string `json:"branch"`
	Remote  bool   `json:"remote"`
	Command string `json:"command"`
	// key: its name, what it typed, the modifier keys (Cmd: ⌘ / Super).
	Key    string       `json:"key"`
	Text   string       `json:"text"`
	Ctrl   bool         `json:"ctrl"`
	Shift  bool         `json:"shift"`
	Alt    bool         `json:"alt"`
	Cmd    bool         `json:"cmd"`
	Button *ButtonClick `json:"button"`
}

// Action handles a click; Dispatch calls the one the click names.
type Action func(win *Window, b *ButtonClick) error

// Dispatch is the central on-click: actions[ev.Button.Function].
func Dispatch(actions map[string]Action, win *Window, ev *Event) error {
	if ev.Button == nil {
		return nil
	}
	f, ok := actions[ev.Button.Function]
	if !ok {
		return fmt.Errorf("no function %q in actions", ev.Button.Function)
	}
	return f(win, ev.Button)
}

type conn struct {
	sock      net.Conn
	r         *bufio.Reader
	mu        sync.Mutex
	pending   []map[string]json.RawMessage
	nextID    uint32
	currentEv uint32
}

var c *conn

func (cn *conn) send(msg M) {
	b, err := json.Marshal(msg)
	if err != nil {
		return
	}
	cn.mu.Lock()
	defer cn.mu.Unlock()
	_, _ = cn.sock.Write(append(b, '\n')) // gtty gone: the read loop ends
}

func (cn *conn) read() (map[string]json.RawMessage, error) {
	for {
		line, err := cn.r.ReadBytes('\n')
		if err != nil {
			return nil, err
		}
		var m map[string]json.RawMessage
		if json.Unmarshal(line, &m) == nil {
			return m, nil
		}
	}
}

func (cn *conn) next() (map[string]json.RawMessage, error) {
	if len(cn.pending) > 0 {
		m := cn.pending[0]
		cn.pending = cn.pending[1:]
		return m, nil
	}
	return cn.read()
}

func str(m map[string]json.RawMessage, k string) string {
	var s string
	_ = json.Unmarshal(m[k], &s)
	return s
}

func num(m map[string]json.RawMessage, k string) uint32 {
	var n uint32
	_ = json.Unmarshal(m[k], &n)
	return n
}

func (cn *conn) call(win uint32, op string, fields M, out any) error {
	cn.nextID++
	id := cn.nextID
	msg := M{"t": "call", "id": id, "win": win, "op": op}
	for k, v := range fields {
		msg[k] = v
	}
	cn.send(msg)
	for {
		m, err := cn.read()
		if err != nil {
			return ErrWindowClosed
		}
		if str(m, "t") != "reply" || num(m, "id") != id {
			cn.pending = append(cn.pending, m)
			continue
		}
		if e, ok := m["error"]; ok {
			var name string
			_ = json.Unmarshal(e, &name)
			if known, ok := errorsByName[name]; ok {
				return known
			}
			return ErrStorageFailed
		}
		if out != nil {
			if err := json.Unmarshal(m["value"], out); err != nil {
				return ErrStorageFailed
			}
		}
		return nil
	}
}

// UI sets what the window shows of this extension.
type UI struct{ w *Window }

// Set sets one of chip, peek, epeek or dialog:
// win.UI.Set(gtty.M{"chip": gtty.M{"text": "main"}}). A key left out stays,
// nil clears it; gtty.M{"peek": nil} removes the peek. Errors in the update
// go to `gtty ext logs`.
func (u *UI) Set(update M) error {
	if len(update) != 1 {
		return errors.New("UI.Set: one of chip, peek, epeek or dialog")
	}
	for k := range update {
		if k != "chip" && k != "peek" && k != "epeek" && k != "dialog" {
			return errors.New("UI.Set: one of chip, peek, epeek or dialog")
		}
	}
	return u.w.post("set", update)
}

// SetDisplayMode shows "chip" (closing this extension's peek or epeek),
// "peek" or "epeek". Opened while handling the user's click, it gets the
// keyboard.
func (u *UI) SetDisplayMode(mode string) error {
	if mode != "chip" && mode != "peek" && mode != "epeek" {
		return errors.New("mode: chip, peek or epeek")
	}
	return u.w.post("mode", M{"mode": mode, "ev": c.currentEv})
}

// ShowDialog shows the dialog set with Set.
func (u *UI) ShowDialog() error { return u.w.post("showDialog", M{"ev": c.currentEv}) }

// CloseDialog closes it: the buttons only report. Not after kill or
// timeout: it's gone already.
func (u *UI) CloseDialog() error { return u.w.post("closeDialog", nil) }

// Events registers for events; clicks come without.
type Events struct{ w *Window }

// Register: "window_changed", "command_started" or "key".
func (e *Events) Register(kind string) error {
	if kind == "button_click" {
		return nil
	}
	if kind != "window_changed" && kind != "command_started" && kind != "key" {
		return fmt.Errorf("unknown event %q", kind)
	}
	return e.w.post("register", M{"event": kind})
}

// Unregister undoes Register.
func (e *Events) Unregister(kind string) error {
	if kind == "button_click" {
		return nil
	}
	return e.w.post("unregister", M{"event": kind})
}

// File is a file open in a storage.
type File struct {
	w      *Window
	handle uint32
	open   bool
}

// Read reads up to max bytes; an empty slice at the end.
func (f *File) Read(max int) ([]byte, error) {
	if max < 1 {
		max = 1
	}
	if max > 1<<20 {
		max = 1 << 20
	}
	var s string
	if err := c.call(f.w.ID, "read", M{"handle": f.handle, "max": max}, &s); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(s)
}

// ReadAll reads to the end.
func (f *File) ReadAll() ([]byte, error) {
	var out []byte
	for {
		p, err := f.Read(1 << 20)
		if err != nil {
			return out, err
		}
		if len(p) == 0 {
			return out, nil
		}
		out = append(out, p...)
	}
}

// Write appends data.
func (f *File) Write(data []byte) error {
	for i := 0; i < len(data) || i == 0; i += 1 << 20 {
		end := i + 1<<20
		if end > len(data) {
			end = len(data)
		}
		if err := c.call(f.w.ID, "write", M{"handle": f.handle, "data": base64.StdEncoding.EncodeToString(data[i:end])}, nil); err != nil {
			return err
		}
		if end == len(data) {
			break
		}
	}
	return nil
}

// Close closes it; a file opened for writing takes the old one's place now.
func (f *File) Close() error {
	if !f.open {
		return nil
	}
	f.open = false
	return c.call(f.w.ID, "close", M{"handle": f.handle}, nil)
}

// Storage is win.Ephemeral (this instance's files, gone with the window)
// or win.Stateful (the extension's, shared by all its instances). Names
// are plain file names.
type Storage struct {
	w    *Window
	kind string
}

func (s *Storage) open(name, mode string, timeoutMs int) (*File, error) {
	var h uint32
	if err := c.call(s.w.ID, "open", M{"storage": s.kind, "name": name, "mode": mode, "timeout": timeoutMs}, &h); err != nil {
		return nil, err
	}
	return &File{w: s.w, handle: h, open: true}, nil
}

// OpenWrite waits up to timeoutMs for the file (0: tries once). Writing
// replaces the whole file, at Close; until then nobody else can use it.
func (s *Storage) OpenWrite(name string, timeoutMs int) (*File, error) {
	return s.open(name, "write", timeoutMs)
}

// OpenRead waits up to timeoutMs while someone writes it. No such file:
// ErrNoFile.
func (s *Storage) OpenRead(name string, timeoutMs int) (*File, error) {
	return s.open(name, "read", timeoutMs)
}

// Delete removes a file.
func (s *Storage) Delete(name string, timeoutMs int) error {
	return c.call(s.w.ID, "delete", M{"storage": s.kind, "name": name, "timeout": timeoutMs}, nil)
}

// List is the file names.
func (s *Storage) List() ([]string, error) {
	var names []string
	err := c.call(s.w.ID, "list", M{"storage": s.kind}, &names)
	return names, err
}

// Window is the connection to one window.
type Window struct {
	ID        uint32
	UI        *UI
	Events    *Events
	Ephemeral *Storage
	Stateful  *Storage
	closed    bool
}

func newWindow(id uint32) *Window {
	w := &Window{ID: id}
	w.UI = &UI{w}
	w.Events = &Events{w}
	w.Ephemeral = &Storage{w, "ephemeral"}
	w.Stateful = &Storage{w, "stateful"}
	return w
}

func (w *Window) post(t string, fields M) error {
	if w.closed {
		return ErrWindowClosed
	}
	msg := M{"t": t, "win": w.ID}
	for k, v := range fields {
		msg[k] = v
	}
	c.send(msg)
	return nil
}

// Shell is the shell in front (bash inside zsh: bash); if something else
// is in front, the window's own shell.
func (w *Window) Shell() (string, error) {
	var s string
	err := c.call(w.ID, "shell", nil, &s)
	return s, err
}

// Log writes a line in `gtty ext logs` with this window's id. Level:
// debug, info, warn or err. Safe from any goroutine.
func (w *Window) Log(level, message string) { logLine(w.ID, level, message) }

// Ext is the extension, for OnGttyStart and OnGttyClose.
type Ext struct{ Name string }

// Log writes a line about no window.
func (e *Ext) Log(level, message string) { logLine(0, level, message) }

func logLine(win uint32, level, message string) {
	switch level {
	case "debug", "info", "warn", "err":
	default:
		level = "info"
	}
	if len(message) > 4096 {
		message = message[:4096]
	}
	c.send(M{"t": "log", "win": win, "level": level, "message": message})
}

// devSocket is where an extension gtty didn't start connects:
// GTTY_EXT_SOCKET, else the newest gtty's shared address (only when the
// folder is this user's alone).
func devSocket() string {
	if p := os.Getenv("GTTY_EXT_SOCKET"); p != "" {
		return p
	}
	tmp := os.Getenv("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	folder := fmt.Sprintf("%s/gtty-dev-%d", strings.TrimRight(tmp, "/"), os.Getuid())
	fi, err := os.Lstat(folder)
	if err != nil || !fi.IsDir() || fi.Mode().Perm()&0o077 != 0 {
		return ""
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != os.Getuid() {
		return ""
	}
	return folder + "/ext.sock"
}

// connect gives gtty's socket on GTTY_EXT_FD, or the developer socket when
// an IDE started it (debugging true).
func connect() (sock net.Conn, debugging bool, err error) {
	if fd := os.Getenv("GTTY_EXT_FD"); fd != "" {
		n, err := strconv.Atoi(fd)
		if err != nil {
			return nil, false, err
		}
		sock, err := net.FileConn(os.NewFile(uintptr(n), "gtty"))
		return sock, false, err
	}
	if p := devSocket(); p != "" {
		if sock, err := net.Dial("unix", p); err == nil {
			return sock, true, nil
		}
	}
	return nil, false, errors.New("no gtty to connect to: start gtty first (or set GTTY_EXT_SOCKET, see `gtty ext socket`)")
}

func report(win uint32, callback string, err error) {
	if err == nil || errors.Is(err, ErrWindowClosed) {
		return
	}
	logLine(win, "err", callback+" returned "+err.Error())
}

// Run runs the extension until gtty closes; nil then.
func Run(ext any) error {
	sock, debugging, err := connect()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return err
	}
	c = &conn{sock: sock, r: bufio.NewReaderSize(sock, 1<<16)}
	if debugging {
		// Started by an IDE: say which extension this is.
		dir, _ := os.Getwd()
		c.send(M{"t": "attach", "api": APIVersion, "name": os.Getenv("GTTY_EXT_NAME"), "dir": dir})
	}
	name := os.Getenv("GTTY_EXT_NAME")
	windows := map[uint32]*Window{}
	for {
		m, err := c.next()
		if err != nil {
			return nil
		}
		win := num(m, "win")
		switch str(m, "t") {
		case "refused":
			err := fmt.Errorf("gtty refused the connection: %s", str(m, "reason"))
			fmt.Fprintln(os.Stderr, err)
			return err
		case "hello":
			if num(m, "api") != APIVersion {
				err := fmt.Errorf("gtty speaks extension API %d, this SDK %d", num(m, "api"), APIVersion)
				fmt.Fprintln(os.Stderr, err)
				return err
			}
			if n := str(m, "name"); n != "" {
				name = n
			}
		case "gttyStart":
			if f, ok := ext.(interface{ OnGttyStart(*Ext) error }); ok {
				report(0, "OnGttyStart", f.OnGttyStart(&Ext{Name: name}))
			}
		case "gttyClose":
			if f, ok := ext.(interface{ OnGttyClose(*Ext) error }); ok {
				report(0, "OnGttyClose", f.OnGttyClose(&Ext{Name: name}))
			}
			sock.Close()
			return nil
		case "windowStart":
			w := newWindow(win)
			windows[win] = w
			if f, ok := ext.(interface{ OnWindowStart(*Window) error }); ok {
				report(win, "OnWindowStart", f.OnWindowStart(w))
			}
		case "windowClose":
			w := windows[win]
			if w == nil {
				continue
			}
			delete(windows, win)
			w.closed = true
			if f, ok := ext.(interface{ OnWindowClose(*Window) error }); ok {
				report(win, "OnWindowClose", f.OnWindowClose(w))
			}
		case "event":
			w := windows[win]
			f, ok := ext.(interface{ OnEvent(*Window, *Event) error })
			if w == nil || !ok {
				continue
			}
			var ev Event
			if json.Unmarshal(m["event"], &ev) != nil {
				continue
			}
			c.currentEv = ev.EventID
			report(win, "OnEvent", f.OnEvent(w, &ev))
			c.currentEv = 0
		}
	}
}
