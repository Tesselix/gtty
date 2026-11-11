// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"fmt"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Which commands are kept, and the file (pure, tested by rules_test.go).

const keep = 500 // commands kept, the ones used last

// excluded are never kept: the look-arounds, in any part of the line.
var excluded = set("cd", "pushd", "popd", "ls", "ll", "la", "l", "lsd", "exa", "eza", "gls", "dir", "vdir", "find")

// wrappers are skipped in front of the command, with their own options.
var wrappers = set("sudo", "doas", "env", "time", "nohup", "nice", "command", "builtin", "exec")

// wrapperArg: wrapper options that take the next word.
var wrapperArg = map[string]map[string]bool{
	"sudo": set("-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"),
	"doas": set("-u", "-C"),
	"env":  set("-u", "-C", "-S", "-P"),
	"nice": set("-n"),
}

const separators = "|&;\n()"

func set(names ...string) map[string]bool {
	m := map[string]bool{}
	for _, n := range names {
		m[n] = true
	}
	return m
}

// word: raw as typed, val with the quotes and backslashes taken off.
type word struct{ raw, val string }

// segments are the line's parts.
func segments(line string) [][]word {
	var parts [][]word
	var words []word
	var raw, val strings.Builder
	var quote rune
	inWord := false
	rs := []rune(line)
	for i := 0; i < len(rs); i++ {
		ch := rs[i]
		switch {
		case quote != 0:
			raw.WriteRune(ch)
			if ch == quote {
				quote = 0
			} else if ch == '\\' && quote == '"' && i+1 < len(rs) {
				i++
				raw.WriteRune(rs[i])
				val.WriteRune(rs[i])
			} else {
				val.WriteRune(ch)
			}
		case ch == '\'' || ch == '"':
			quote = ch
			raw.WriteRune(ch)
			inWord = true
		case ch == '\\' && i+1 < len(rs):
			i++
			raw.WriteRune(ch)
			raw.WriteRune(rs[i])
			if rs[i] != '\n' {
				val.WriteRune(rs[i])
			}
			inWord = true
		case ch == ' ' || ch == '\t' || strings.ContainsRune(separators, ch):
			if inWord {
				words = append(words, word{raw.String(), val.String()})
				raw.Reset()
				val.Reset()
				inWord = false
			}
			if strings.ContainsRune(separators, ch) && len(words) > 0 {
				parts = append(parts, words)
				words = nil
			}
		default:
			raw.WriteRune(ch)
			val.WriteRune(ch)
			inWord = true
		}
	}
	if inWord {
		words = append(words, word{raw.String(), val.String()})
	}
	if len(words) > 0 {
		parts = append(parts, words)
	}
	return parts
}

var assignment = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

func isFlag(raw string) bool { return len(raw) >= 2 && raw[0] == '-' && raw != "--" }

// worth: is this command line worth keeping? See ../README.md.
func worth(line string) bool {
	if strings.TrimSpace(line) == "" || line[0] == ' ' || line[0] == '\t' {
		return false
	}
	flagged := false
	for _, words := range segments(line) {
		i := 0
		// Assignments and wrappers in front, with the wrappers' options.
		for i < len(words) {
			if assignment.MatchString(words[i].raw) {
				i++
				continue
			}
			name := path.Base(words[i].val)
			if !wrappers[name] {
				break
			}
			i++
			for i < len(words) && isFlag(words[i].raw) {
				if wrapperArg[name][words[i].raw] {
					i += 2
				} else {
					i++
				}
			}
		}
		if i >= len(words) {
			continue
		}
		if excluded[path.Base(words[i].val)] {
			return false
		}
		for _, w := range words[i+1:] {
			if isFlag(w.raw) {
				flagged = true
			}
		}
	}
	return flagged
}

// entry is one kept command.
type entry struct {
	count int
	last  int64
	cmd   string
}

var escaper = strings.NewReplacer(`\`, `\\`, "\t", `\t`, "\n", `\n`, "\r", `\r`)

func unescape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			switch s[i] {
			case 't':
				b.WriteByte('\t')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			default:
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func byUse(e []entry) {
	sort.SliceStable(e, func(a, b int) bool {
		if e[a].last != e[b].last {
			return e[a].last < e[b].last
		}
		return e[a].count < e[b].count
	})
}

// parse reads the file's lines "count<TAB>last<TAB>command", oldest use first.
func parse(text string) []entry {
	var out []entry
	for _, line := range strings.Split(text, "\n") {
		f := strings.SplitN(line, "\t", 3)
		if len(f) != 3 {
			continue
		}
		n, err1 := strconv.Atoi(f[0])
		last, err2 := strconv.ParseInt(f[1], 10, 64)
		if err1 != nil || err2 != nil || n < 0 || last < 0 {
			continue
		}
		out = append(out, entry{n, last, unescape(f[2])})
	}
	byUse(out)
	return out
}

func format(entries []entry) string {
	var b strings.Builder
	for _, e := range entries {
		fmt.Fprintf(&b, "%d\t%d\t%s\n", e.count, e.last, escaper.Replace(e.cmd))
	}
	return b.String()
}

// record counts one more use of cmd; keeps the keep used last.
func record(entries []entry, cmd string, now int64) []entry {
	found := false
	for i := range entries {
		if entries[i].cmd == cmd {
			entries[i].count++
			entries[i].last = max(entries[i].last, now)
			found = true
			break
		}
	}
	if !found {
		entries = append(entries, entry{1, now, cmd})
	}
	byUse(entries)
	if len(entries) > keep {
		entries = entries[len(entries)-keep:]
	}
	return entries
}
