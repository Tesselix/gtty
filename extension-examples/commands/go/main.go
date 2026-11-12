// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// commands: a chip that keeps the commands you run (all but the
// very common ones: cd, ls, pwd, …). A click on one copies it. See ../README.md.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	gtty "github.com/Tesselix/gtty/sdks/go"
)

const (
	file   = "commands.tsv"
	shown  = 200 // lines in the list at most
	waitMs = 300 // storage timeout
)

// commands keeps per-window state: OnWindowStart runs once per window.
type commands struct {
	filters map[uint32]string
}

func (h *commands) OnWindowStart(win *gtty.Window) error {
	h.filters[win.ID] = ""
	if err := win.Events.Register("command_started"); err != nil {
		return err
	}
	// A click and the mouse resting on the chip both open the list.
	if err := win.UI.Set(gtty.M{"chip": gtty.M{"text": "commands", "onclick": "open", "onhover": "open"}}); err != nil {
		return err
	}
	entries, err := load(win)
	if err != nil {
		return err
	}
	return h.setList(win, entries)
}

func (h *commands) OnWindowClose(win *gtty.Window) error {
	delete(h.filters, win.ID)
	return nil
}

func (h *commands) OnEvent(win *gtty.Window, ev *gtty.Event) error {
	switch ev.Kind {
	case "button_click":
		return gtty.Dispatch(h.actions(), win, ev)
	case "command_started":
		if !worth(ev.Command) {
			return nil
		}
		entries, err := load(win)
		if err == nil {
			err = save(win, record(entries, strings.TrimSpace(ev.Command), time.Now().Unix()))
		}
		if errors.Is(err, gtty.ErrFileInUse) {
			win.Log("warn", "commands.tsv busy: a command not kept")
			return nil
		}
		return err
	}
	return nil
}

// ---- storage ----

func load(win *gtty.Window) ([]entry, error) {
	f, err := win.Stateful.OpenRead(file, waitMs)
	if errors.Is(err, gtty.ErrNoFile) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := f.ReadAll()
	if err != nil {
		return nil, err
	}
	return parse(string(b)), nil
}

func save(win *gtty.Window, entries []entry) error {
	f, err := win.Stateful.OpenWrite(file, waitMs)
	if err != nil {
		return err
	}
	if err := f.Write([]byte(format(entries))); err != nil {
		f.Close()
		return err
	}
	return f.Close() // the write takes the old file's place here
}

// ---- the clipboard: the SDK can't type into a window ----

// copyText returns "" when copied, else why not.
func copyText(text string) string {
	var tools [][]string
	if runtime.GOOS == "darwin" {
		tools = append(tools, []string{"pbcopy"})
	} else {
		if os.Getenv("WAYLAND_DISPLAY") != "" {
			tools = append(tools, []string{"wl-copy"})
		}
		tools = append(tools, []string{"xclip", "-selection", "clipboard"}, []string{"xsel", "--clipboard", "--input"})
	}
	for _, argv := range tools {
		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.Stdin = strings.NewReader(text)
		if cmd.Run() == nil {
			return ""
		}
	}
	return "no clipboard tool (pbcopy, wl-copy, xclip, xsel)"
}

var paste = map[bool]string{true: "⌘V", false: "Ctrl+Shift+V"}[runtime.GOOS == "darwin"]

// ---- the list ----

var oneLine = strings.NewReplacer("\r\n", " ⏎ ", "\n", " ⏎ ", "\t", " ")

// lowerASCII keeps byte offsets, so a match marks the right letters.
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

func (h *commands) setList(win *gtty.Window, entries []entry) error {
	flt := lowerASCII(h.filters[win.ID])
	rows := []gtty.M{}
	for _, e := range entries {
		text := oneLine.Replace(e.cmd)
		at := 0
		if flt != "" {
			if at = strings.Index(lowerASCII(text), flt); at < 0 {
				continue
			}
		}
		parts := []gtty.Part{{String: text}}
		if flt != "" {
			// Mark the letters that match.
			parts = []gtty.Part{
				{String: text[:at]},
				{String: text[at : at+len(flt)], Fg: gtty.RGB(0x202020), Bk: gtty.RGB(0xe0b040)},
				{String: text[at+len(flt):]},
			}
		}
		if e.count > 1 {
			parts = append(parts, gtty.Part{String: fmt.Sprintf("  ×%d", e.count), Fg: gtty.RGB(0x8a8a8a)})
		}
		rows = append(rows, gtty.M{
			"id": fmt.Sprint(len(rows)), "text": gtty.Text(parts...), "onclick": "pick", "data": e.cmd,
			"postButton": gtty.M{"dots": "vertical", "onclick": "rowMenu", "items": []gtty.M{
				{"id": "copy", "text": "Copy", "data": e.cmd},
				{"id": "forget", "text": "Forget", "data": e.cmd},
			}},
		})
	}
	if len(rows) > shown {
		rows = rows[len(rows)-shown:]
	}
	empty := "no commands yet: run one"
	if flt != "" {
		empty = "no commands match"
	}
	return win.UI.Set(gtty.M{"epeek": gtty.M{
		"frame":    gtty.M{"text": "commands", "filter": gtty.M{"hint": "filter commands", "onclick": "filter"}},
		"lines":    rows,
		"selected": max(len(rows)-1, 0), // the newest, next to the chip
		"empty":    empty,
		"footer":   "a click copies it, " + paste + " pastes it",
		"state":    "idle",
		"message":  []string{},
	}})
}

func copyIt(win *gtty.Window, cmd string) error {
	if why := copyText(cmd); why != "" {
		win.Log("warn", why)
		return win.UI.Set(gtty.M{"epeek": gtty.M{"state": "err", "message": []string{why}}})
	}
	return win.UI.Set(gtty.M{"epeek": gtty.M{"state": "ok", "message": []string{"copied: " + paste + " pastes it"}}})
}

// actions: every onclick / onhover name is a key here.
func (h *commands) actions() map[string]gtty.Action {
	reload := func(win *gtty.Window) error {
		entries, err := load(win) // other windows may have added commands
		if err != nil {
			return err
		}
		return h.setList(win, entries)
	}
	return map[string]gtty.Action{
		"open": func(win *gtty.Window, b *gtty.ButtonClick) error {
			if err := reload(win); err != nil {
				return err
			}
			return win.UI.SetDisplayMode("epeek")
		},
		"filter": func(win *gtty.Window, b *gtty.ButtonClick) error {
			h.filters[win.ID] = b.Text
			return reload(win)
		},
		"pick": func(win *gtty.Window, b *gtty.ButtonClick) error { return copyIt(win, b.Data) },
		// A ⋮ pick: b.ID is the item's.
		"rowMenu": func(win *gtty.Window, b *gtty.ButtonClick) error {
			switch b.ID {
			case "copy":
				return copyIt(win, b.Data)
			case "forget":
				entries, err := load(win)
				if err != nil {
					return err
				}
				kept := entries[:0]
				for _, e := range entries {
					if e.cmd != b.Data {
						kept = append(kept, e)
					}
				}
				if err := save(win, kept); err != nil {
					return err
				}
				return h.setList(win, kept)
			}
			return nil
		},
	}
}

func main() {
	// Run says why on stderr when it fails (no gtty, refused).
	if err := gtty.Run(&commands{filters: map[uint32]string{}}); err != nil {
		os.Exit(1)
	}
}
