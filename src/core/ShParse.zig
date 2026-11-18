// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A small parser for the shell startup files (bash / zsh): enough of the
//! grammar to follow what they define — simple commands, `&&` / `||`,
//! pipelines, `if`, `for`, `while` / `until`, `case`, `{ }`, `( )`,
//! functions — for EnvTrace.zig. Words stay raw (quotes and `$…` kept);
//! the tracer expands them. Redirections and heredoc bodies are dropped.
//!
//! It never fails on a file: a statement it can't read is skipped up to
//! the next line (`Program.errors` counts them), so the rest of the file
//! is still traced.

const std = @import("std");

pub const Tok = struct {
    kind: Kind,
    text: []const u8,
    line: u32,

    pub const Kind = enum { word, op, redir, newline, eof };
};

/// Split `src` into tokens (the last one `.eof`).
pub fn lex(a: std.mem.Allocator, src: []const u8) ![]Tok {
    var l: Lexer = .{ .src = src };
    var out: std.ArrayList(Tok) = .empty;
    while (true) {
        const t = l.next();
        try out.append(a, t);
        if (t.kind == .eof) break;
    }
    return out.toOwnedSlice(a);
}

const Heredoc = struct { delim: []const u8, dash: bool };

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    line: u32 = 1,
    here: [8]Heredoc = undefined,
    n_here: usize = 0,
    /// The next word is a heredoc's delimiter (`<<` / `<<-` came).
    want_delim: ?bool = null,

    fn peekAt(l: *const Lexer, k: usize) u8 {
        return if (l.i + k < l.src.len) l.src[l.i + k] else 0;
    }

    fn next(l: *Lexer) Tok {
        while (true) {
            while (l.i < l.src.len and (l.src[l.i] == ' ' or l.src[l.i] == '\t' or l.src[l.i] == '\r')) l.i += 1;
            if (l.i + 1 < l.src.len and l.src[l.i] == '\\' and l.src[l.i + 1] == '\n') {
                l.i += 2;
                l.line += 1;
                continue;
            }
            break;
        }
        if (l.i >= l.src.len) return .{ .kind = .eof, .text = "", .line = l.line };
        const ch = l.src[l.i];
        if (ch == '#') {
            while (l.i < l.src.len and l.src[l.i] != '\n') l.i += 1;
            return l.next();
        }
        if (ch == '\n') {
            const line = l.line;
            l.i += 1;
            l.line += 1;
            l.skipHeredocs();
            return .{ .kind = .newline, .text = "\n", .line = line };
        }
        // An fd before a redirection (`2>`, `1>&2`): dropped with it.
        if (std.ascii.isDigit(ch)) {
            var k: usize = 0;
            while (std.ascii.isDigit(l.peekAt(k))) k += 1;
            const after = l.peekAt(k);
            if ((after == '<' or after == '>') and l.peekAt(k + 1) != '(') l.i += k;
        }
        const c0 = l.src[l.i];
        // Process substitution is a word: `<(cmd)`.
        if ((c0 == '<' or c0 == '>') and l.peekAt(1) == '(') return l.word();
        const ops = [_][]const u8{ ";;&", ";;", ";&", ";|", "&&", "||", "|&", ";", "&", "|", "(", ")" };
        const redirs = [_][]const u8{ "&>>", "&>", "<<<", "<<-", "<<", ">>", ">&", "<&", ">|", "<>", "<", ">" };
        for (redirs) |r| if (std.mem.startsWith(u8, l.src[l.i..], r)) {
            l.i += r.len;
            if (std.mem.eql(u8, r, "<<")) l.want_delim = false;
            if (std.mem.eql(u8, r, "<<-")) l.want_delim = true;
            return .{ .kind = .redir, .text = r, .line = l.line };
        };
        for (ops) |o| if (std.mem.startsWith(u8, l.src[l.i..], o)) {
            l.i += o.len;
            return .{ .kind = .op, .text = o, .line = l.line };
        };
        return l.word();
    }

    fn word(l: *Lexer) Tok {
        const start = l.i;
        const line = l.line;
        while (l.i < l.src.len) {
            const ch = l.src[l.i];
            switch (ch) {
                ' ', '\t', '\r', '\n', ';', '&', '|', ')' => break,
                '<', '>' => if (l.i == start and l.peekAt(1) == '(') {
                    l.i += 1;
                    l.balanced('(', ')');
                } else break,
                '(' => {
                    // An array (`a=(…)`, `path+=(…)`), a glob qualifier
                    // (`*(N)`) or an extglob group (`@(…)`): part of the word.
                    const prev = if (l.i > start) l.src[l.i - 1] else 0;
                    if (prev == '=' or prev == '*' or prev == '?' or prev == ']' or prev == '@' or prev == '!' or prev == '+') {
                        l.balanced('(', ')');
                    } else break;
                },
                '\\' => {
                    if (l.peekAt(1) == '\n') l.line += 1;
                    l.i = @min(l.i + 2, l.src.len);
                },
                '\'' => l.single(),
                '"' => l.double(),
                '`' => l.backtick(),
                '$' => l.dollar(),
                else => l.i += 1,
            }
        }
        const text = l.src[start..l.i];
        if (l.want_delim) |dash| {
            l.want_delim = null;
            if (l.n_here < l.here.len) {
                l.here[l.n_here] = .{ .delim = unquote(text), .dash = dash };
                l.n_here += 1;
            }
        }
        return .{ .kind = .word, .text = text, .line = line };
    }

    /// At `'`: to just after the closing one.
    fn single(l: *Lexer) void {
        l.i += 1;
        while (l.i < l.src.len and l.src[l.i] != '\'') : (l.i += 1) {
            if (l.src[l.i] == '\n') l.line += 1;
        }
        l.i = @min(l.i + 1, l.src.len);
    }

    /// At `"`: to just after the closing one.
    fn double(l: *Lexer) void {
        l.i += 1;
        while (l.i < l.src.len) {
            switch (l.src[l.i]) {
                '"' => {
                    l.i += 1;
                    return;
                },
                '\\' => {
                    if (l.peekAt(1) == '\n') l.line += 1;
                    l.i = @min(l.i + 2, l.src.len);
                },
                '`' => l.backtick(),
                '$' => l.dollar(),
                '\n' => {
                    l.line += 1;
                    l.i += 1;
                },
                else => l.i += 1,
            }
        }
    }

    fn backtick(l: *Lexer) void {
        l.i += 1;
        while (l.i < l.src.len and l.src[l.i] != '`') {
            if (l.src[l.i] == '\\') l.i += 1 else if (l.src[l.i] == '\n') l.line += 1;
            l.i += 1;
        }
        l.i = @min(l.i + 1, l.src.len);
    }

    /// At `$`: `$(…)`, `$((…))`, `${…}`, `$'…'` or a plain `$name`.
    fn dollar(l: *Lexer) void {
        switch (l.peekAt(1)) {
            '(' => {
                l.i += 1;
                l.balanced('(', ')');
            },
            '{' => {
                l.i += 1;
                l.balanced('{', '}');
            },
            '\'' => {
                l.i += 2;
                while (l.i < l.src.len and l.src[l.i] != '\'') {
                    if (l.src[l.i] == '\\') l.i += 1 else if (l.src[l.i] == '\n') l.line += 1;
                    l.i += 1;
                }
                l.i = @min(l.i + 1, l.src.len);
            },
            else => l.i += 1,
        }
    }

    /// At `open`: to just after its matching `close` (quotes inside skipped).
    fn balanced(l: *Lexer, open: u8, close: u8) void {
        var depth: usize = 0;
        while (l.i < l.src.len) {
            const ch = l.src[l.i];
            if (ch == open) {
                depth += 1;
                l.i += 1;
            } else if (ch == close) {
                l.i += 1;
                depth -= 1;
                if (depth == 0) return;
            } else switch (ch) {
                '\'' => l.single(),
                '"' => l.double(),
                '`' => l.backtick(),
                '\\' => l.i = @min(l.i + 2, l.src.len),
                '\n' => {
                    l.line += 1;
                    l.i += 1;
                },
                else => l.i += 1,
            }
        }
    }

    /// After a line feed: the bodies of the heredocs started on that line.
    fn skipHeredocs(l: *Lexer) void {
        for (l.here[0..l.n_here]) |h| {
            while (l.i < l.src.len) {
                const eol = std.mem.indexOfScalarPos(u8, l.src, l.i, '\n') orelse l.src.len;
                var text = l.src[l.i..eol];
                if (h.dash) text = std.mem.trimStart(u8, text, "\t");
                text = std.mem.trimEnd(u8, text, "\r");
                l.i = @min(eol + 1, l.src.len);
                l.line += 1;
                if (std.mem.eql(u8, text, h.delim)) break;
            }
        }
        l.n_here = 0;
    }
};

/// Just after the quoted part or `$…` construct that starts at `src[i]`
/// (`'…'`, `"…"`, `` `…` ``, `$(…)`, `${…}`, `$'…'`): EnvTrace's expansion
/// finds its pieces with the lexer's own rules.
pub fn spanEnd(src: []const u8, i: usize) usize {
    var l: Lexer = .{ .src = src, .i = i };
    switch (src[i]) {
        '\'' => l.single(),
        '"' => l.double(),
        '`' => l.backtick(),
        '$' => l.dollar(),
        else => l.i += 1,
    }
    return @max(l.i, i + 1);
}

/// A heredoc delimiter without its quotes (`'EOF'`, `"EOF"`, `\EOF`).
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    if (s.len >= 1 and s[0] == '\\') return s[1..];
    return s;
}

// ------------------------------------------------------------ the tree

pub const List = []const AndOr;

pub const AndOr = struct {
    first: Pipeline,
    rest: []const Link,
};

pub const Link = struct {
    op: enum { and_, or_ },
    p: Pipeline,
};

pub const Pipeline = struct {
    bang: bool = false,
    cmds: []const Cmd,
};

pub const Cmd = union(enum) {
    simple: Simple,
    if_: If,
    for_: For,
    loop: Loop,
    case_: Case,
    group: List,
    subshell: List,
    func: Func,
    /// zsh's anonymous function, `() { … }`: runs at once.
    anon: List,
};

pub const Simple = struct {
    words: []const []const u8,
    line: u32,
};

pub const If = struct {
    conds: []const List,
    bodies: []const List,
    else_: ?List,
};

pub const For = struct {
    name: []const u8,
    /// null: `for x; do` (the positional parameters).
    words: ?[]const []const u8,
    body: List,
    line: u32,
};

pub const Loop = struct {
    until: bool,
    cond: List,
    body: List,
};

pub const Case = struct {
    word: []const u8,
    items: []const CaseItem,
    line: u32,
};

pub const CaseItem = struct {
    pats: []const []const u8,
    body: List,
};

pub const Func = struct {
    name: []const u8,
    body: *const Cmd,
};

pub const Program = struct {
    list: List,
    /// Statements skipped because they couldn't be read.
    errors: u32,
};

/// Parse a whole file (or `eval`'s text). Allocations in `a` (an arena).
pub fn parse(a: std.mem.Allocator, src: []const u8) !Program {
    var p: Parser = .{ .a = a, .toks = try lex(a, src) };
    var all: std.ArrayList(AndOr) = .empty;
    while (true) {
        const l = try p.list(&.{});
        try all.appendSlice(a, l);
        if (p.peek().kind == .eof) break;
        // A stray `)`, `;;`: skip it.
        p.errors += 1;
        p.pos += 1;
    }
    return .{ .list = try all.toOwnedSlice(a), .errors = p.errors };
}

const ParseError = error{ Syntax, OutOfMemory };

const Parser = struct {
    a: std.mem.Allocator,
    toks: []const Tok,
    pos: usize = 0,
    errors: u32 = 0,
    depth: u32 = 0,

    fn peek(p: *const Parser) Tok {
        return p.toks[@min(p.pos, p.toks.len - 1)];
    }

    fn peekN(p: *const Parser, n: usize) Tok {
        return p.toks[@min(p.pos + n, p.toks.len - 1)];
    }

    fn isWord(t: Tok, w: []const u8) bool {
        return t.kind == .word and std.mem.eql(u8, t.text, w);
    }

    fn isOp(t: Tok, o: []const u8) bool {
        return t.kind == .op and std.mem.eql(u8, t.text, o);
    }

    fn skipNewlines(p: *Parser) void {
        while (p.peek().kind == .newline) p.pos += 1;
    }

    fn expectWord(p: *Parser, w: []const u8) ParseError!void {
        p.skipNewlines();
        if (!isWord(p.peek(), w)) return error.Syntax;
        p.pos += 1;
    }

    /// Statements up to a reserved word in `stop` (at a command's start),
    /// `)`, a `case` item's end or the end of the file. A statement that
    /// can't be read is skipped to the next line.
    fn list(p: *Parser, stop: []const []const u8) error{OutOfMemory}!List {
        var out: std.ArrayList(AndOr) = .empty;
        while (true) {
            while (p.peek().kind == .newline or isOp(p.peek(), ";") or isOp(p.peek(), "&")) p.pos += 1;
            const t = p.peek();
            if (t.kind == .eof) break;
            if (t.kind == .op and (std.mem.eql(u8, t.text, ")") or std.mem.startsWith(u8, t.text, ";;") or std.mem.eql(u8, t.text, ";&") or std.mem.eql(u8, t.text, ";|"))) break;
            if (t.kind == .word) {
                var stopped = false;
                for (stop) |s| if (std.mem.eql(u8, t.text, s)) {
                    stopped = true;
                };
                if (stopped) break;
            }
            const at = p.pos;
            const ao = p.andOr() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => {
                    p.errors += 1;
                    if (p.pos == at) p.pos += 1;
                    while (p.peek().kind != .newline and p.peek().kind != .eof) p.pos += 1;
                    continue;
                },
            };
            try out.append(p.a, ao);
        }
        return out.toOwnedSlice(p.a);
    }

    fn andOr(p: *Parser) ParseError!AndOr {
        const first = try p.pipeline();
        var rest: std.ArrayList(Link) = .empty;
        while (true) {
            const t = p.peek();
            const op: @FieldType(Link, "op") = if (isOp(t, "&&")) .and_ else if (isOp(t, "||")) .or_ else break;
            p.pos += 1;
            p.skipNewlines();
            try rest.append(p.a, .{ .op = op, .p = try p.pipeline() });
        }
        return .{ .first = first, .rest = try rest.toOwnedSlice(p.a) };
    }

    fn pipeline(p: *Parser) ParseError!Pipeline {
        var bang = false;
        if (isWord(p.peek(), "!")) {
            bang = true;
            p.pos += 1;
        }
        var cmds: std.ArrayList(Cmd) = .empty;
        try cmds.append(p.a, try p.command());
        while (isOp(p.peek(), "|") or isOp(p.peek(), "|&")) {
            p.pos += 1;
            p.skipNewlines();
            try cmds.append(p.a, try p.command());
        }
        return .{ .bang = bang, .cmds = try cmds.toOwnedSlice(p.a) };
    }

    /// Redirections after a compound command (`done < file`).
    fn skipRedirs(p: *Parser) void {
        while (p.peek().kind == .redir) {
            p.pos += 1;
            if (p.peek().kind == .word) p.pos += 1;
        }
    }

    fn command(p: *Parser) ParseError!Cmd {
        if (p.depth > 200) return error.Syntax;
        p.depth += 1;
        defer p.depth -= 1;
        const t = p.peek();
        if (isOp(t, "(")) {
            // zsh's anonymous function: `() { … }`.
            if (isOp(p.peekN(1), ")")) {
                p.pos += 2;
                p.skipNewlines();
                const body = try p.command();
                return switch (body) {
                    .group => |g| .{ .anon = g },
                    else => error.Syntax,
                };
            }
            p.pos += 1;
            const l = try p.list(&.{});
            if (!isOp(p.peek(), ")")) return error.Syntax;
            p.pos += 1;
            p.skipRedirs();
            return .{ .subshell = l };
        }
        if (t.kind != .word) return error.Syntax;
        const w = t.text;
        if (std.mem.eql(u8, w, "if")) return p.ifCmd();
        if (std.mem.eql(u8, w, "for") or std.mem.eql(u8, w, "foreach")) return p.forCmd();
        if (std.mem.eql(u8, w, "while") or std.mem.eql(u8, w, "until")) {
            p.pos += 1;
            const cond = try p.list(&.{"do"});
            try p.expectWord("do");
            const body = try p.list(&.{"done"});
            try p.expectWord("done");
            p.skipRedirs();
            return .{ .loop = .{ .until = w[0] == 'u', .cond = cond, .body = body } };
        }
        if (std.mem.eql(u8, w, "case")) return p.caseCmd();
        if (std.mem.eql(u8, w, "{")) {
            p.pos += 1;
            const l = try p.list(&.{"}"});
            try p.expectWord("}");
            p.skipRedirs();
            return .{ .group = l };
        }
        if (std.mem.eql(u8, w, "function")) {
            p.pos += 1;
            const name = p.peek();
            if (name.kind != .word) return error.Syntax;
            p.pos += 1;
            if (isOp(p.peek(), "(") and isOp(p.peekN(1), ")")) p.pos += 2;
            p.skipNewlines();
            const body = try p.a.create(Cmd);
            body.* = try p.command();
            return .{ .func = .{ .name = name.text, .body = body } };
        }
        // `name () body`
        if (isOp(p.peekN(1), "(") and isOp(p.peekN(2), ")")) {
            p.pos += 3;
            p.skipNewlines();
            const body = try p.a.create(Cmd);
            body.* = try p.command();
            return .{ .func = .{ .name = w, .body = body } };
        }
        return p.simple();
    }

    fn simple(p: *Parser) ParseError!Cmd {
        const line = p.peek().line;
        var words: std.ArrayList([]const u8) = .empty;
        const dbl = isWord(p.peek(), "[[");
        while (true) {
            const t = p.peek();
            switch (t.kind) {
                .word => {
                    try words.append(p.a, t.text);
                    p.pos += 1;
                    if (dbl and std.mem.eql(u8, t.text, "]]")) break;
                },
                .redir => {
                    // `[[ a < b ]]` compares; elsewhere a redirection.
                    if (dbl) {
                        try words.append(p.a, t.text);
                        p.pos += 1;
                        continue;
                    }
                    p.pos += 1;
                    if (p.peek().kind == .word) p.pos += 1;
                },
                .op => {
                    if (dbl and (std.mem.eql(u8, t.text, "&&") or std.mem.eql(u8, t.text, "||") or std.mem.eql(u8, t.text, "(") or std.mem.eql(u8, t.text, ")"))) {
                        try words.append(p.a, t.text);
                        p.pos += 1;
                        continue;
                    }
                    break;
                },
                .newline, .eof => break,
            }
        }
        if (words.items.len == 0) {
            // Only redirections: nothing to run.
            if (p.peek().kind == .op and !isOp(p.peek(), ";") and !isOp(p.peek(), "&")) return error.Syntax;
        }
        return .{ .simple = .{ .words = try words.toOwnedSlice(p.a), .line = line } };
    }

    fn ifCmd(p: *Parser) ParseError!Cmd {
        p.pos += 1; // if
        var conds: std.ArrayList(List) = .empty;
        var bodies: std.ArrayList(List) = .empty;
        var else_: ?List = null;
        while (true) {
            try conds.append(p.a, try p.list(&.{"then"}));
            try p.expectWord("then");
            try bodies.append(p.a, try p.list(&.{ "elif", "else", "fi" }));
            p.skipNewlines();
            const t = p.peek();
            if (isWord(t, "elif")) {
                p.pos += 1;
                continue;
            }
            if (isWord(t, "else")) {
                p.pos += 1;
                else_ = try p.list(&.{"fi"});
            }
            try p.expectWord("fi");
            break;
        }
        p.skipRedirs();
        return .{ .if_ = .{ .conds = try conds.toOwnedSlice(p.a), .bodies = try bodies.toOwnedSlice(p.a), .else_ = else_ } };
    }

    fn forCmd(p: *Parser) ParseError!Cmd {
        const line = p.peek().line;
        p.pos += 1;
        const name = p.peek();
        if (name.kind != .word) return error.Syntax; // `for ((…))`
        p.pos += 1;
        var words: ?[]const []const u8 = null;
        p.skipNewlines();
        if (isWord(p.peek(), "in")) {
            p.pos += 1;
            var ws: std.ArrayList([]const u8) = .empty;
            while (p.peek().kind == .word) : (p.pos += 1) try ws.append(p.a, p.peek().text);
            words = try ws.toOwnedSlice(p.a);
        } else if (isOp(p.peek(), "(")) {
            // zsh: `for x (a b c) …`
            p.pos += 1;
            var ws: std.ArrayList([]const u8) = .empty;
            while (p.peek().kind == .word or p.peek().kind == .newline) : (p.pos += 1) {
                if (p.peek().kind == .word) try ws.append(p.a, p.peek().text);
            }
            if (!isOp(p.peek(), ")")) return error.Syntax;
            p.pos += 1;
            words = try ws.toOwnedSlice(p.a);
        }
        while (isOp(p.peek(), ";") or p.peek().kind == .newline) p.pos += 1;
        var body: List = undefined;
        if (isWord(p.peek(), "do")) {
            p.pos += 1;
            body = try p.list(&.{"done"});
            try p.expectWord("done");
        } else if (isWord(p.peek(), "{")) {
            const g = try p.command();
            body = g.group;
        } else return error.Syntax;
        p.skipRedirs();
        return .{ .for_ = .{ .name = name.text, .words = words, .body = body, .line = line } };
    }

    fn caseCmd(p: *Parser) ParseError!Cmd {
        const line = p.peek().line;
        p.pos += 1;
        const word = p.peek();
        if (word.kind != .word) return error.Syntax;
        p.pos += 1;
        try p.expectWord("in");
        var items: std.ArrayList(CaseItem) = .empty;
        while (true) {
            p.skipNewlines();
            if (isWord(p.peek(), "esac")) {
                p.pos += 1;
                break;
            }
            if (p.peek().kind == .eof) return error.Syntax;
            if (isOp(p.peek(), "(")) p.pos += 1;
            var pats: std.ArrayList([]const u8) = .empty;
            while (true) {
                const t = p.peek();
                if (t.kind != .word) return error.Syntax;
                try pats.append(p.a, t.text);
                p.pos += 1;
                if (isOp(p.peek(), "|")) {
                    p.pos += 1;
                    continue;
                }
                break;
            }
            if (!isOp(p.peek(), ")")) return error.Syntax;
            p.pos += 1;
            const body = try p.list(&.{"esac"});
            const t = p.peek();
            if (t.kind == .op and (std.mem.startsWith(u8, t.text, ";;") or std.mem.eql(u8, t.text, ";&") or std.mem.eql(u8, t.text, ";|"))) p.pos += 1;
            try items.append(p.a, .{ .pats = try pats.toOwnedSlice(p.a), .body = body });
        }
        p.skipRedirs();
        return .{ .case_ = .{ .word = word.text, .items = try items.toOwnedSlice(p.a), .line = line } };
    }
};

// ------------------------------------------------------------ tests

test "words keep their quotes; comments and redirections go" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prog = try parse(arena.allocator(), "export PATH=\"$HOME/bin:$PATH\" # mine\nalias ll='ls -l' 2>/dev/null\n");
    try std.testing.expectEqual(@as(usize, 2), prog.list.len);
    const s0 = prog.list[0].first.cmds[0].simple;
    try std.testing.expectEqualStrings("export", s0.words[0]);
    try std.testing.expectEqualStrings("PATH=\"$HOME/bin:$PATH\"", s0.words[1]);
    const s1 = prog.list[1].first.cmds[0].simple;
    try std.testing.expectEqual(@as(usize, 2), s1.words.len);
    try std.testing.expectEqualStrings("ll='ls -l'", s1.words[1]);
    try std.testing.expectEqual(@as(u32, 2), s1.line);
}

test "compound commands, heredocs and recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\if [ -d "$HOME/bin" ]; then
        \\  PATH="$HOME/bin:$PATH"
        \\elif true; then :; else
        \\  X=1
        \\fi
        \\cat <<EOF
        \\export NOT_THIS=1
        \\EOF
        \\for i in /etc/profile.d/*.sh; do
        \\  [ -r "$i" ] && . "$i"
        \\done
        \\case $- in *i*) ;; *) return;; esac
        \\pathmunge () {
        \\  PATH=$PATH:$1
        \\}
        \\for ((i=0;i<3;i++)); do :; done
        \\path=(/opt/bin $path)
        \\export LAST=1
    ;
    const prog = try parse(arena.allocator(), src);
    const l = prog.list;
    try std.testing.expect(l[0].first.cmds[0] == .if_);
    try std.testing.expectEqual(@as(usize, 2), l[0].first.cmds[0].if_.conds.len);
    try std.testing.expect(l[0].first.cmds[0].if_.else_ != null);
    // The heredoc body is not a command.
    try std.testing.expectEqualStrings("cat", l[1].first.cmds[0].simple.words[0]);
    try std.testing.expect(l[2].first.cmds[0] == .for_);
    try std.testing.expect(l[3].first.cmds[0] == .case_);
    try std.testing.expectEqual(@as(usize, 2), l[3].first.cmds[0].case_.items.len);
    try std.testing.expect(l[4].first.cmds[0] == .func);
    try std.testing.expect(prog.errors > 0); // the C-style for
    const last = l[l.len - 1].first.cmds[0].simple;
    try std.testing.expectEqualStrings("LAST=1", last.words[1]);
    try std.testing.expectEqual(@as(u32, 18), last.line);
    const arr = l[l.len - 2].first.cmds[0].simple;
    try std.testing.expectEqualStrings("path=(/opt/bin $path)", arr.words[0]);
}

test "[[ ]] keeps && and <; and-or lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prog = try parse(arena.allocator(), "[[ -f a && -r a ]] && source a || true\nsource <(kubectl completion zsh)\n");
    const ao = prog.list[0];
    try std.testing.expectEqual(@as(usize, 7), ao.first.cmds[0].simple.words.len);
    try std.testing.expectEqual(@as(usize, 2), ao.rest.len);
    try std.testing.expectEqualStrings("<(kubectl completion zsh)", prog.list[1].first.cmds[0].simple.words[1]);
}
