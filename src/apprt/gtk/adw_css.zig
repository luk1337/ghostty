//! Filtering of libadwaita's stylesheet for use with a forced GTK theme.
//!
//! libadwaita doesn't load its stylesheet when a GTK theme is forced
//! (GTK_THEME), so widgets that only exist in libadwaita (dialogs, toasts,
//! the tab overview, ...) are unstyled with themes not made for libadwaita.
//! Loading the whole stylesheet underneath the theme leaks libadwaita's
//! styling into everything the theme only partially styles (headerbars,
//! popovers, window decorations, ...). Instead, we keep only the rules that
//! target libadwaita-only widgets, plus libadwaita's color definitions.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Selectors are kept if they contain one of these node names or classes.
/// These are libadwaita-only widgets that GTK themes don't style.
const tokens = [_][]const u8{
    // AdwDialog and its subclasses (AdwAlertDialog, AdwAboutDialog).
    "dialog-host",
    "sheet",
    "alert",
    "about",
    "message-area",
    "response-area",
    "boxed-list",
    "app-version",
    // AdwToast
    "toast",
    // AdwTabOverview
    "taboverview",
    "tabthumbnail",
    "tabgrid",
};

pub const Options = struct {
    /// Whether to use libadwaita's dark style. libadwaita's dark colors are
    /// in `prefers-color-scheme` media queries, but GTK doesn't know the
    /// preferred color scheme when a theme is forced, so we resolve these
    /// media queries ourselves.
    dark: bool,
};

/// Filter libadwaita's stylesheet. Each top-level statement (rule or
/// at-rule) is handled on its own; statements that span multiple lines are
/// joined into one line first. Statements we don't understand are dropped.
pub fn filter(alloc: Allocator, css: []const u8, opts: Options) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var statement: std.ArrayList(u8) = .empty;
    defer statement.deinit(alloc);

    var it: StatementIterator = .{ .css = css };
    while (it.next()) |raw| {
        // Join multi-line statements into a single line.
        statement.clearRetainingCapacity();
        for (raw) |c| try statement.append(alloc, switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        });
        const line = std.mem.trim(u8, statement.items, " ");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "@define-color") or
            std.mem.startsWith(u8, line, "@keyframes"))
        {
            try appendLine(alloc, &out, line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "@media")) {
            // "@media (query) { <statements> }"
            const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            if (line[line.len - 1] != '}') continue;
            const query = std.mem.trim(u8, line["@media".len..open], " ");
            const inner = try filter(alloc, line[open + 1 .. line.len - 1], opts);
            defer alloc.free(inner);
            if (inner.len == 0) continue;

            // Resolve color scheme queries ourselves by either dropping
            // them or applying their contents unconditionally.
            const scheme: ?bool = if (std.mem.eql(u8, query, "(prefers-color-scheme: dark)"))
                true
            else if (std.mem.eql(u8, query, "(prefers-color-scheme: light)"))
                false
            else
                null;
            if (scheme) |dark| {
                if (dark == opts.dark) try out.appendSlice(alloc, inner);
                continue;
            }

            try out.appendSlice(alloc, line[0 .. open + 1]);
            try out.append(alloc, '\n');
            try out.appendSlice(alloc, inner);
            try out.appendSlice(alloc, "}\n");
            continue;
        }

        if (line[0] == '@' or line[0] == '/') continue;
        if (std.mem.count(u8, line, "{") != 1) continue;
        const rule = try filterRule(alloc, line) orelse continue;
        defer alloc.free(rule);
        try appendLine(alloc, &out, rule);
    }

    return out.toOwnedSlice(alloc);
}

/// Iterates over the top-level statements of a stylesheet: either a block
/// (which ends with the closing brace that returns to the top level) or a
/// statement ending with a semicolon at the top level (e.g. @define-color).
/// Comments are skipped.
const StatementIterator = struct {
    css: []const u8,
    pos: usize = 0,

    fn next(self: *StatementIterator) ?[]const u8 {
        // Skip whitespace and comments between statements.
        while (self.pos < self.css.len) {
            if (std.ascii.isWhitespace(self.css[self.pos])) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, self.css[self.pos..], "/*")) {
                const end = std.mem.indexOfPos(u8, self.css, self.pos + 2, "*/") orelse {
                    self.pos = self.css.len;
                    return null;
                };
                self.pos = end + 2;
            } else break;
        }
        if (self.pos >= self.css.len) return null;

        const start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.css.len) : (self.pos += 1) {
            switch (self.css[self.pos]) {
                '{' => depth += 1,
                '}' => {
                    depth -|= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        return self.css[start..self.pos];
                    }
                },
                ';' => if (depth == 0) {
                    self.pos += 1;
                    return self.css[start..self.pos];
                },
                else => {},
            }
        }

        // Unterminated statement, drop it.
        return null;
    }
};

fn appendLine(alloc: Allocator, out: *std.ArrayList(u8), line: []const u8) Allocator.Error!void {
    try out.appendSlice(alloc, line);
    try out.append(alloc, '\n');
}

/// Filter the selectors of a single "selectors { declarations }" rule,
/// returning the rule with only the matching selectors, or null if none
/// match. The caller owns the returned memory.
fn filterRule(alloc: Allocator, rule: []const u8) Allocator.Error!?[]u8 {
    const open = std.mem.indexOfScalar(u8, rule, '{') orelse return null;
    const selectors = rule[0..open];
    const block = rule[open..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Split on top-level commas (not inside parentheses).
    var depth: usize = 0;
    var start: usize = 0;
    for (selectors, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        ',' => if (depth == 0) {
            try appendSelector(alloc, &out, selectors[start..i]);
            start = i + 1;
        },
        else => {},
    };
    try appendSelector(alloc, &out, selectors[start..]);

    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }

    try out.append(alloc, ' ');
    try out.appendSlice(alloc, block);
    return try out.toOwnedSlice(alloc);
}

fn appendSelector(alloc: Allocator, out: *std.ArrayList(u8), raw: []const u8) Allocator.Error!void {
    const selector = std.mem.trim(u8, raw, " ");
    if (!matches(selector)) return;
    if (out.items.len > 0) try out.appendSlice(alloc, ", ");
    try out.appendSlice(alloc, selector);
}

/// Returns true if the selector applies to libadwaita-only widgets, or is
/// the root (which holds libadwaita's CSS variables).
fn matches(selector: []const u8) bool {
    if (std.mem.eql(u8, selector, ":root")) return true;

    var i: usize = 0;
    while (i < selector.len) {
        if (!isIdent(selector[i])) {
            i += 1;
            continue;
        }

        // Read a whole identifier (node name or class name).
        const start = i;
        while (i < selector.len and isIdent(selector[i])) i += 1;
        const ident = selector[start..i];

        // Skip identifiers inside pseudo-classes like :not(...) since
        // they don't select the widget.
        if (start > 0 and selector[start - 1] == ':') continue;
        if (insideParens(selector, start)) continue;

        for (tokens) |token| {
            if (std.mem.eql(u8, ident, token)) return true;
        }
    }

    return false;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn insideParens(selector: []const u8, pos: usize) bool {
    var depth: usize = 0;
    for (selector[0..pos]) |c| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        else => {},
    };
    return depth > 0;
}

test "keeps libadwaita-only rules" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input =
        \\@define-color window_bg_color #222226;
        \\:root { --window-radius: 15px; }
        \\window.csd { border-radius: var(--window-radius); }
        \\headerbar { min-height: 47px; }
        \\toast { background: #505053; }
        \\window.messagedialog, dialog-host > dialog.alert sheet { background-color: red; }
        \\button:not(.alert) { color: blue; }
        \\@media (prefers-color-scheme: dark) { @define-color window_bg_color #000; }
        \\@media (prefers-color-scheme: light) { @define-color window_bg_color #fff; }
        \\@media (prefers-contrast: more) { toast { box-shadow: none; } }
        \\@media (prefers-contrast: more) { popover { outline: none; } }
        \\@keyframes spin { to { transform: rotate(1turn); } }
        \\:root { --a: color-mix(
        \\  in srgb, red, blue
        \\  ); --b: red; }
        \\/* comment */
        \\
    ;

    const output = try filter(alloc, input, .{ .dark = true });
    defer alloc.free(output);

    try testing.expectEqualStrings(
        \\@define-color window_bg_color #222226;
        \\:root { --window-radius: 15px; }
        \\toast { background: #505053; }
        \\dialog-host > dialog.alert sheet { background-color: red; }
        \\@define-color window_bg_color #000;
        \\@media (prefers-contrast: more) {
        \\toast { box-shadow: none; }
        \\}
        \\@keyframes spin { to { transform: rotate(1turn); } }
        \\:root { --a: color-mix(   in srgb, red, blue   ); --b: red; }
        \\
    , output);
}
