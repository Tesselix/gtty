# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
"""The rules (../cases.tsv) and the file. Run: python3 test_commands.py"""

import os
import unittest

import commands

CASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cases.tsv")


def cases():
    with open(CASES, encoding="utf-8") as f:
        for line in f.read().split("\n"):
            if not line or line.startswith("#"):
                continue
            want, _, cmd = line.partition("\t")
            yield want == "keep", cmd.replace("\\n", "\n").replace("\\t", "\t").replace("\\s", " ")


class Rules(unittest.TestCase):
    def test_cases(self):
        n = 0
        for keep, cmd in cases():
            with self.subTest(cmd=cmd):
                self.assertEqual(commands.worth(cmd), keep)
            n += 1
        self.assertGreater(n, 30)


class File(unittest.TestCase):
    def test_round_trip(self):
        entries = [[1, 10, "a -x"], [3, 20, "printf -v x 'a\tb\\n'\necho -n done"]]
        self.assertEqual(commands.parse(commands.format_entries(entries)), entries)

    def test_bad_lines_skipped(self):
        self.assertEqual(commands.parse("x\t1\ta\n2\t5\tb -c\n\n"), [[2, 5, "b -c"]])

    def test_record(self):
        e = commands.record([], "a -x", 10)
        e = commands.record(e, "b -y", 11)
        e = commands.record(e, "a -x", 12)
        self.assertEqual(e, [[1, 11, "b -y"], [2, 12, "a -x"]])

    def test_keeps_the_used_last(self):
        e = []
        for i in range(commands.KEEP + 5):
            e = commands.record(e, "c -%d" % i, i)
        self.assertEqual(len(e), commands.KEEP)
        self.assertEqual(e[0][2], "c -5")


if __name__ == "__main__":
    unittest.main()
