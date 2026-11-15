// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

// The rules (../cases.tsv) and the file.

func TestCases(t *testing.T) {
	b, err := os.ReadFile("../cases.tsv")
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		want, cmd, _ := strings.Cut(line, "\t")
		cmd = strings.NewReplacer(`\n`, "\n", `\t`, "\t", `\s`, " ").Replace(cmd)
		if got := worth(cmd); got != (want == "keep") {
			t.Errorf("worth(%q) = %v, want %s", cmd, got, want)
		}
		n++
	}
	if n <= 30 {
		t.Errorf("only %d cases", n)
	}
}

func TestRoundTrip(t *testing.T) {
	e := []entry{{1, 10, "a -x"}, {3, 20, "printf -v x 'a\tb\\n'\necho -n done"}}
	if got := parse(format(e)); !reflect.DeepEqual(got, e) {
		t.Errorf("got %q", got)
	}
}

func TestBadLines(t *testing.T) {
	if got := parse("x\t1\ta\n2\t5\tb -c\n\n"); !reflect.DeepEqual(got, []entry{{2, 5, "b -c"}}) {
		t.Errorf("got %q", got)
	}
}

func TestRecord(t *testing.T) {
	e := record(nil, "a -x", 10)
	e = record(e, "b -y", 11)
	e = record(e, "a -x", 12)
	if !reflect.DeepEqual(e, []entry{{1, 11, "b -y"}, {2, 12, "a -x"}}) {
		t.Errorf("got %v", e)
	}
}

func TestKeepsTheUsedLast(t *testing.T) {
	var e []entry
	for i := 0; i < keep+5; i++ {
		e = record(e, fmt.Sprintf("c -%d", i), int64(i))
	}
	if len(e) != keep || e[0].cmd != "c -5" {
		t.Errorf("len %d, first %q", len(e), e[0].cmd)
	}
}
