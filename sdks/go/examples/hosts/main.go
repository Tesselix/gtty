// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Hosts is a complete extension: a chip that keeps a list of hosts. It
// uses every part of the SDK and is checked by
// sdks/conformance/fake_gtty.py, so it can't fall behind. Start a new
// extension from a copy of this folder and manifest.json; `go build`
// makes the program gtty starts.
package main

import (
	"errors"
	"os"
	"strings"

	gtty "github.com/Tesselix/gtty/sdks/go"
)

const file = "hosts.txt"

// hosts keeps per-window state: OnWindowStart runs once per window.
type hosts struct {
	filters map[uint32]string
}

func (h *hosts) OnWindowStart(win *gtty.Window) error {
	h.filters[win.ID] = ""
	if err := win.Events.Register("window_changed"); err != nil {
		return err
	}
	// Keys: F6 opens the list. The key still reaches the program too.
	if err := win.Events.Register("key"); err != nil {
		return err
	}
	// A UI needs a chip. Hover opens nothing by itself: onhover does.
	if err := win.UI.Set(gtty.M{"chip": gtty.M{"text": "hosts", "onhover": "open"}}); err != nil {
		return err
	}
	if err := win.UI.Set(gtty.M{"peek": gtty.M{
		"expand":     true,
		"onexpand":   "refresh",
		"text":       gtty.Text(gtty.Part{String: "hosts", Bold: true}),
		"postButton": gtty.M{"dots": "horizontal", "onclick": "about"},
	}}); err != nil {
		return err
	}
	return h.setList(win)
}

func (h *hosts) OnWindowClose(win *gtty.Window) error {
	delete(h.filters, win.ID)
	return nil
}

func (h *hosts) OnEvent(win *gtty.Window, ev *gtty.Event) error {
	switch ev.Kind {
	case "button_click":
		return gtty.Dispatch(h.actions(), win, ev)
	case "window_changed":
		return win.UI.Set(gtty.M{"chip": gtty.M{"dimmed": ev.Remote}})
	case "key":
		if ev.Key == "f6" && !(ev.Ctrl || ev.Shift || ev.Alt || ev.Cmd) {
			return win.UI.SetDisplayMode("epeek")
		}
	}
	return nil
}

// readHosts is the hosts file's text; no file yet: an empty list.
func readHosts(win *gtty.Window) (string, error) {
	f, err := win.Stateful.OpenRead(file, 200)
	if errors.Is(err, gtty.ErrNoFile) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := f.ReadAll()
	return string(b), err
}

var rowMenu = []gtty.M{{"id": "connect", "text": "Connect"}, {"id": "remove", "text": "Remove"}}

func (h *hosts) setList(win *gtty.Window) error {
	flt := h.filters[win.ID]
	text, err := readHosts(win)
	if err != nil {
		return err
	}
	rows := []gtty.M{}
	for _, host := range strings.Split(text, "\n") {
		if host == "" {
			continue
		}
		// gtty doesn't filter: the extension decides what the text means.
		at := 0
		if flt != "" {
			at = strings.Index(strings.ToLower(host), strings.ToLower(flt))
			if at < 0 {
				continue
			}
		}
		var label any = host
		if flt != "" {
			// Mark the letters that match.
			label = gtty.Text(
				gtty.Part{String: host[:at]},
				gtty.Part{String: host[at : at+len(flt)], Fg: gtty.RGB(0x202020), Bk: gtty.RGB(0xe0b040)},
				gtty.Part{String: host[at+len(flt):]},
			)
		}
		rows = append(rows, gtty.M{
			"id": host, "text": label, "onclick": "pick", "data": host,
			"postButton": gtty.M{"dots": "vertical", "onclick": "rowMenu", "items": rowMenu},
		})
	}
	return win.UI.Set(gtty.M{"epeek": gtty.M{
		"frame": gtty.M{
			"text":   "hosts",
			"filter": gtty.M{"hint": "filter hosts", "onclick": "filter"},
			"right":  []gtty.M{{"icon": "save", "text": "add", "onclick": "askHost"}},
		},
		"lines":    rows,
		"selected": 0,
		"empty":    "no hosts",
	}})
}

// actions: every onclick / onhover / onexpand name is a key here.
func (h *hosts) actions() map[string]gtty.Action {
	return map[string]gtty.Action{
		"open": func(win *gtty.Window, b *gtty.ButtonClick) error {
			win.Log("debug", "opening the peek")
			return win.UI.SetDisplayMode("peek")
		},
		// Other windows may have added hosts.
		"refresh": func(win *gtty.Window, b *gtty.ButtonClick) error { return h.setList(win) },
		"filter": func(win *gtty.Window, b *gtty.ButtonClick) error {
			h.filters[win.ID] = b.Text
			return h.setList(win)
		},
		"pick": func(win *gtty.Window, b *gtty.ButtonClick) error {
			if err := win.UI.Set(gtty.M{"chip": gtty.M{"text": b.Data}}); err != nil {
				return err
			}
			return win.UI.SetDisplayMode("chip") // gtty only reports: close it here
		},
		// A ⋮ pick: b.ID is the item's.
		"rowMenu": func(win *gtty.Window, b *gtty.ButtonClick) error {
			if b.ID == "connect" {
				return win.UI.SetDisplayMode("chip")
			}
			return nil
		},
		"about": func(win *gtty.Window, b *gtty.ButtonClick) error {
			shell, err := win.Shell()
			if err != nil {
				return err
			}
			if err := win.UI.Set(gtty.M{"dialog": gtty.M{
				"title": "About hosts", "layout": "form", "timeout": 20, "buttons": "ok", "onclick": "closeIt",
				"fields": []gtty.M{{"id": "info", "type": "label", "label": "running under " + shell}},
			}}); err != nil {
				return err
			}
			return win.UI.ShowDialog()
		},
		"closeIt": func(win *gtty.Window, b *gtty.ButtonClick) error {
			// After kill and timeout the dialog is already gone.
			if b.ID != "kill" && b.ID != "timeout" {
				return win.UI.CloseDialog()
			}
			return nil
		},
		"askHost": func(win *gtty.Window, b *gtty.ButtonClick) error {
			if err := win.UI.Set(gtty.M{"dialog": gtty.M{
				"title": "Add a host", "layout": "form", "timeout": 30, "buttons": "okcancel", "onclick": "addHost",
				"fields": []gtty.M{
					{"id": "host", "type": "text", "label": "Host", "value": ""},
					{"id": "pin", "type": "checkbox", "label": "Show on the chip", "value": false},
					{"id": "kind", "type": "dropdown", "label": "Kind", "value": "ssh", "options": []string{"ssh", "mosh"}, "filter": false},
				},
			}}); err != nil {
				return err
			}
			return win.UI.ShowDialog()
		},
		"addHost": func(win *gtty.Window, b *gtty.ButtonClick) error {
			if b.ID == "kill" || b.ID == "timeout" {
				return nil
			}
			if b.ID == "ok" {
				host, _ := b.Field("host")
				// To reject input, update the dialog and leave it open.
				if host == "" {
					return win.UI.Set(gtty.M{"dialog": gtty.M{"error": "enter a host"}})
				}
				old, err := readHosts(win)
				if err != nil {
					return err
				}
				// A write replaces the whole file, at Close.
				f, err := win.Stateful.OpenWrite(file, 200)
				if err != nil {
					return err
				}
				if err := f.Write([]byte(old + host + "\n")); err != nil {
					f.Close()
					return err
				}
				if err := f.Close(); err != nil {
					return err
				}
				if b.Checked("pin") {
					if err := win.UI.Set(gtty.M{"chip": gtty.M{"text": host}}); err != nil {
						return err
					}
				}
				if err := h.setList(win); err != nil {
					return err
				}
			}
			return win.UI.CloseDialog() // the buttons only report
		},
	}
}

func main() {
	// Run says why on stderr when it fails (no gtty, refused).
	if err := gtty.Run(&hosts{filters: map[uint32]string{}}); err != nil {
		os.Exit(1)
	}
}
