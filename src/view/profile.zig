//! A profile as text: `write` for a terminal (a header, the top functions, the call tree),
//! `live_write` while it runs, and `folded_write` for flame graph tools.
//!
//!      nusku  app [pid 4242] · 5.0 s · 495 samples at 99 Hz · duration reached
//!
//!      Top functions  by self time, 20 of 57 that ran
//!        SELF               TOTAL              FUNCTION
//!        49.4% ████▉        49.4% ████▉        hot_leaf  app
//!
//!      Call tree  outermost frame first, hiding branches under 1.0%
//!       100.0%  run
//!        49.4%  ├─ hot
//!        49.4%  │  hot_leaf
//!        30.3%  └─ warm
//!        30.3%     recurse ↻

const std = @import("std");
const server = @import("server");
const protocol = @import("shared").protocol;
const term = @import("../term/term.zig");

const assert = std.debug.assert;
const Style = term.Style;
const Writer = std.Io.Writer;
const Frame = server.Frame;
const Profile = server.Profile;

pub const Summary = struct {
    pid: u32,
    /// The process's name, when it is known.
    name: ?[]const u8 = null,
    /// How long the run took, from start to stop.
    elapsed_ms: u64 = 0,
    /// Null while the run goes: the live view.
    reason: ?protocol.RunStop,
};

pub const Options = struct {
    /// Rows of the function table.
    top: usize = 20,
    /// Call tree branches under this share, in tenths of a percent, are hidden.
    cutoff_tenths: u64 = 10,
    color: bool = false,
};

pub fn write(
    w: *Writer,
    arena: std.mem.Allocator,
    profile: *const Profile,
    summary: Summary,
    options: Options,
) !void {
    const style = Style{ .color = options.color };
    _ = try header_write(w, style, profile, summary);
    if (profile.samples == 0) {
        try w.print("\n  {s}No samples:{s} the process was never on a CPU while it was " ++
            "profiled.\n", .{ style.on(term.yellow), style.off() });
        return;
    }
    var names = Names{ .arena = arena };
    const functions = try functions_rank(arena, &names, profile.stacks);
    _ = try functions_write(w, style, functions, profile.samples, options.top);

    var tree = try Tree.build(arena, &names, profile.stacks);
    try tree.write(w, style, profile.samples, options.cutoff_tenths);
}

/// The header and the top functions so far, drawn over the last view of `lines_before` lines.
/// Returns the lines it drew.
pub fn live_write(
    w: *Writer,
    arena: std.mem.Allocator,
    profile: *const Profile,
    summary: Summary,
    options: Options,
    lines_before: usize,
) !usize {
    assert(summary.reason == null);
    try term.lines_erase(w, lines_before);
    const style = Style{ .color = options.color };
    var lines = try header_write(w, style, profile, summary);
    if (profile.samples == 0) {
        try w.print("\n  {s}waiting for samples\u{2026}{s}\n", .{
            style.on(term.dim),
            style.off(),
        });
        return lines + 2;
    }
    var names = Names{ .arena = arena };
    const functions = try functions_rank(arena, &names, profile.stacks);
    lines += try functions_write(w, style, functions, profile.samples, options.top);
    try w.flush();
    return lines;
}

/// One stack per line, outermost frame first: "outer;...;inner count". A stack whose walk
/// stopped early starts with "[incomplete]". A named kernel frame ends in "_[k]", as flame
/// graph tools mark them; an unnamed one is "[kernel]".
pub fn folded_write(w: *Writer, arena: std.mem.Allocator, profile: *const Profile) !void {
    var names = Names{ .arena = arena };
    for (profile.stacks) |stack| {
        if (stack.frames.len == 0) continue;
        if (!stack.complete) try w.writeAll("[incomplete];");
        var position = stack.frames.len;
        while (position > 0) {
            position -= 1;
            const frame = stack.frames[position];
            try w.writeAll(try names.of(frame));
            if (frame.kernel and frame.function != null) try w.writeAll("_[k]");
            if (position > 0) try w.writeByte(';');
        }
        try w.print(" {d}\n", .{stack.samples});
    }
}

// ------------------------------------------------------------------------------------- header

/// Returns the lines it wrote.
fn header_write(w: *Writer, style: Style, profile: *const Profile, summary: Summary) !usize {
    const lines: usize = 2;
    const separator = " \u{00b7} ";
    try w.print("\n  {s}nusku{s}  ", .{ style.on(term.bold_cyan), style.off() });
    if (summary.name) |name| try w.print("{s}{s}{s} ", .{ style.on(term.bold), name, style.off() });
    try w.print("{s}[pid {d}]{s}{s}", .{ style.on(term.dim), summary.pid, separator, style.off() });
    try w.print("{d}.{d} s", .{ summary.elapsed_ms / 1000, summary.elapsed_ms % 1000 / 100 });
    try w.print("{s}{s}{s}", .{ style.on(term.dim), separator, style.off() });
    try w.print("{d} samples at {d} Hz", .{ profile.samples, profile.sample_hz });
    const reason = summary.reason orelse {
        try w.print("{s}{s}live \u{00b7} Ctrl-C to stop{s}\n", .{
            style.on(term.dim),
            separator,
            style.off(),
        });
        return lines + try losses_write(w, style, profile);
    };
    try w.print("{s}{s}{s}{s}\n", .{
        style.on(term.dim),
        separator,
        style.off(),
        switch (reason) {
            .duration => "duration reached",
            .target_exited => "process exited",
            .cancelled => "interrupted",
        },
    });
    return lines + try losses_write(w, style, profile);
}

/// The samples and reports lost, if any. Returns the lines it wrote.
fn losses_write(w: *Writer, style: Style, profile: *const Profile) !usize {
    var lines: usize = 0;
    if (profile.samples_lost > 0) {
        try w.print("  {s}! {d} samples lost: the kernel's buffer was full{s}\n", .{
            style.on(term.yellow),
            profile.samples_lost,
            style.off(),
        });
        lines += 1;
    }
    if (profile.windows_rejected > 0) {
        try w.print("  {s}! {d} reports lost: too big to keep{s}\n", .{
            style.on(term.yellow),
            profile.windows_rejected,
            style.off(),
        });
        lines += 1;
    }
    return lines;
}

// ------------------------------------------------------------------------------------- functions

const Function = struct {
    name: []const u8,
    /// The file name of its binary.
    module: ?[]const u8,
    self: u64,
    total: u64,
};

/// Most self time first. A function counts once per stack in its total, however deep.
fn functions_rank(
    arena: std.mem.Allocator,
    names: *Names,
    stacks: []const server.SymbolStack,
) ![]Function {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var functions: std.ArrayList(Function) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;

    for (stacks) |stack| {
        seen.clearRetainingCapacity();
        for (stack.frames, 0..) |frame, position| {
            const name = try names.of(frame);
            const entry = try index.getOrPut(arena, name);
            if (!entry.found_existing) {
                entry.value_ptr.* = functions.items.len;
                try functions.append(arena, .{
                    .name = name,
                    .module = module_of(frame),
                    .self = 0,
                    .total = 0,
                });
            }
            const function = &functions.items[entry.value_ptr.*];
            if (position == 0) function.self += stack.samples;
            if (name_seen(seen.items, name)) continue;
            try seen.append(arena, name);
            function.total += stack.samples;
        }
    }
    std.mem.sortUnstable(Function, functions.items, {}, function_more);
    return functions.items;
}

fn name_seen(seen: []const []const u8, name: []const u8) bool {
    for (seen) |other| {
        if (same(other, name)) return true;
    }
    return false;
}

fn function_more(_: void, a: Function, b: Function) bool {
    if (a.self != b.self) return a.self > b.self;
    if (a.total != b.total) return a.total > b.total;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Only the functions that ran: those that only called others are in the call tree. Returns
/// the lines it wrote.
fn functions_write(
    w: *Writer,
    style: Style,
    functions: []const Function,
    samples: u64,
    top: usize,
) !usize {
    var running: usize = 0;
    while (running < functions.len and functions[running].self > 0) running += 1;
    const shown = functions[0..@min(running, top)];
    try w.print("\n  {s}Top functions{s}", .{ style.on(term.bold), style.off() });
    try w.print("  {s}by self time, {d} of {d} that ran{s}\n", .{
        style.on(term.dim),
        shown.len,
        running,
        style.off(),
    });
    try w.print("    {s}{s:<17}  {s:<17}  {s}{s}\n", .{
        style.on(term.dim),
        "SELF",
        "TOTAL",
        "FUNCTION",
        style.off(),
    });
    for (shown) |function| {
        try w.writeAll("    ");
        try share_write(w, style, function.self, samples, true);
        try w.writeAll("  ");
        if (function.module == null and function.name[0] == '[') {
            // Unnamed code shares one label: its total would sum unrelated places.
            try w.print("{s}     \u{2013}{s}           ", .{ style.on(term.dim), style.off() });
        } else {
            try share_write(w, style, function.total, samples, true);
        }
        try w.writeAll("  ");
        try term.text_cut_write(w, function.name, name_width_max);
        if (function.module) |module| {
            try w.print("  {s}{s}{s}", .{ style.on(term.dim), module, style.off() });
        }
        try w.writeByte('\n');
    }
    return 3 + shown.len;
}

// ------------------------------------------------------------------------------------- call tree

/// The stacks merged from the outermost frame in: a node is a function on a path. A function
/// that calls itself is one node.
const Tree = struct {
    arena: std.mem.Allocator,
    /// Node 0 is the root, above every outermost frame.
    nodes: std.ArrayList(Node),

    const Node = struct {
        name: []const u8,
        module: ?[]const u8,
        total: u64 = 0,
        self: u64 = 0,
        recursive: bool = false,
        children: std.ArrayList(u32) = .empty,
    };

    /// Where stacks whose walk stopped early hang: their outer frames are unknown.
    const incomplete = "[walk stopped]";

    fn build(arena: std.mem.Allocator, names: *Names, stacks: []const server.SymbolStack) !Tree {
        var tree = Tree{ .arena = arena, .nodes = .empty };
        try tree.nodes.append(arena, .{ .name = "", .module = null });
        for (stacks) |stack| try tree.add(names, stack);
        for (tree.nodes.items) |*node| {
            std.mem.sortUnstable(u32, node.children.items, &tree, child_more);
        }
        return tree;
    }

    fn add(tree: *Tree, names: *Names, stack: server.SymbolStack) !void {
        var current: u32 = 0;
        tree.nodes.items[0].total += stack.samples;
        if (!stack.complete) current = try tree.step(current, incomplete, null, stack.samples);

        var position = stack.frames.len;
        while (position > 0) {
            position -= 1;
            const frame = stack.frames[position];
            const name = try names.of(frame);
            if (current != 0 and same(tree.nodes.items[current].name, name)) {
                tree.nodes.items[current].recursive = true;
                continue;
            }
            current = try tree.step(current, name, module_of(frame), stack.samples);
        }
        tree.nodes.items[current].self += stack.samples;
    }

    /// The child named `name`, made if new, with `samples` more through it.
    fn step(tree: *Tree, parent: u32, name: []const u8, module: ?[]const u8, samples: u64) !u32 {
        const child = for (tree.nodes.items[parent].children.items) |child| {
            if (same(tree.nodes.items[child].name, name)) break child;
        } else child: {
            const index: u32 = @intCast(tree.nodes.items.len);
            try tree.nodes.append(tree.arena, .{ .name = name, .module = module });
            try tree.nodes.items[parent].children.append(tree.arena, index);
            break :child index;
        };
        tree.nodes.items[child].total += samples;
        return child;
    }

    fn child_more(tree: *const Tree, a: u32, b: u32) bool {
        return tree.nodes.items[a].total > tree.nodes.items[b].total;
    }

    fn write(tree: *const Tree, w: *Writer, style: Style, samples: u64, cutoff_tenths: u64) !void {
        try w.print("\n  {s}Call tree{s}", .{ style.on(term.bold), style.off() });
        try w.print("  {s}outermost frame first, hiding branches under {d}.{d}%{s}\n", .{
            style.on(term.dim),
            cutoff_tenths / 10,
            cutoff_tenths % 10,
            style.off(),
        });
        const context = Context{ .w = w, .style = style, .samples = samples };
        try tree.children_write(&context, 0, "", cutoff_tenths);
    }

    const Context = struct { w: *Writer, style: Style, samples: u64 };

    /// A single child continues in the same column; several branch out, and the hidden ones
    /// are summed.
    fn children_write(
        tree: *const Tree,
        context: *const Context,
        parent: u32,
        prefix: []const u8,
        cutoff_tenths: u64,
    ) !void {
        const children = tree.nodes.items[parent].children.items;
        var shown: usize = 0;
        var hidden_samples: u64 = 0;
        for (children) |child| {
            if (tenths(tree.nodes.items[child].total, context.samples) >= cutoff_tenths) {
                shown += 1;
            } else {
                hidden_samples += tree.nodes.items[child].total;
            }
        }
        const hidden = children.len - shown;
        const branches = shown + @intFromBool(hidden > 0) > 1;

        for (children[0..shown], 0..) |child, position| {
            const last = position + 1 == shown and hidden == 0;
            const head = if (!branches) "" else if (last) tee_last else tee;
            const rest = if (!branches) "" else if (last) "   " else bar_vertical;
            try tree.node_write(context, child, parent, prefix, head);
            const deeper = try std.mem.concat(tree.arena, u8, &.{ prefix, rest });
            try tree.children_write(context, child, deeper, cutoff_tenths);
        }
        if (hidden > 0) {
            const w = context.w;
            try w.writeAll("  ");
            try share_write(w, context.style, hidden_samples, context.samples, false);
            try w.print("  {s}{s}{s}\u{2026} {d} more{s}\n", .{
                context.style.on(term.dim),
                prefix,
                if (branches) tee_last else "",
                hidden,
                context.style.off(),
            });
        }
    }

    const tee = "\u{251c}\u{2500} ";
    const tee_last = "\u{2514}\u{2500} ";
    const bar_vertical = "\u{2502}  ";

    fn node_write(
        tree: *const Tree,
        context: *const Context,
        index: u32,
        parent: u32,
        prefix: []const u8,
        head: []const u8,
    ) !void {
        const w = context.w;
        const style = context.style;
        const node = &tree.nodes.items[index];
        try w.writeAll("  ");
        try share_write(w, style, node.total, context.samples, false);
        try w.writeAll("  ");
        if (prefix.len + head.len > 0) {
            try w.print("{s}{s}{s}{s}", .{ style.on(term.dim), prefix, head, style.off() });
        }
        try term.text_cut_write(w, node.name, name_width_max);
        if (node.recursive) try w.print(" {s}\u{21bb}{s}", .{ style.on(term.cyan), style.off() });
        if (node.self > 0 and node.children.items.len > 0) {
            const share = tenths(node.self, context.samples);
            try w.print("  {s}self {d}.{d}%{s}", .{
                style.on(term.dim),
                share / 10,
                share % 10,
                style.off(),
            });
        }
        // The binary, where the path changes binary.
        const parent_module = tree.nodes.items[parent].module;
        if (node.module) |module| {
            const changed = parent_module == null or !std.mem.eql(u8, parent_module.?, module);
            if (changed) try w.print("  {s}{s}{s}", .{ style.on(term.dim), module, style.off() });
        }
        try w.writeByte('\n');
    }
};

// ------------------------------------------------------------------------------------- shares

/// `part` of `whole` in tenths of a percent.
fn tenths(part: u64, whole: u64) u64 {
    assert(whole > 0);
    assert(part <= whole);
    return part * 1000 / whole;
}

/// The share in 6 columns, colored by heat, and if `bar` a bar of 10 columns.
fn share_write(w: *Writer, style: Style, part: u64, whole: u64, bar: bool) !void {
    const share = tenths(part, whole);
    try w.writeAll(style.heat(share, 250));
    try percent_write(w, part, whole);
    if (bar) {
        try w.writeByte(' ');
        try term.bar_write(w, share, 10);
    }
    try w.writeAll(style.off());
}

fn percent_write(w: *Writer, part: u64, whole: u64) !void {
    const share = tenths(part, whole);
    try w.print("{d:>3}.{d}%", .{ share / 10, share % 10 });
}

const name_width_max = 72;

// ------------------------------------------------------------------------------------- names

/// A frame's label: its function, else its binary (`[libc.so.6]`), else its kind. Each is made
/// once, so equal labels are the same slice.
const Names = struct {
    arena: std.mem.Allocator,
    labels: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn of(names: *Names, frame: Frame) ![]const u8 {
        if (frame.function) |function| return names.intern(function, function);
        if (frame.kernel) return "[kernel]";
        const module = frame.module orelse return "[unknown]";
        const entry = try names.labels.getOrPut(names.arena, module);
        if (!entry.found_existing) {
            entry.value_ptr.* = try std.fmt.allocPrint(names.arena, "[{s}]", .{
                std.fs.path.basename(module),
            });
        }
        return entry.value_ptr.*;
    }

    /// The first slice seen with this text.
    fn intern(names: *Names, key: []const u8, label: []const u8) ![]const u8 {
        const entry = try names.labels.getOrPut(names.arena, key);
        if (!entry.found_existing) entry.value_ptr.* = label;
        return entry.value_ptr.*;
    }
};

fn same(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

/// A named frame's binary: an unnamed frame has it in its label.
fn module_of(frame: Frame) ?[]const u8 {
    if (frame.function == null) return null;
    const module = frame.module orelse return null;
    return std.fs.path.basename(module);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn named(function: []const u8) Frame {
    return .{ .address = 1, .kernel = false, .function = function, .module = "/bin/app" };
}

const unnamed_test = Frame{ .address = 0x7f00, .kernel = false, .module = "/usr/lib/libc.so.6" };
// Innermost first: main -> walk -> walk -> leaf.
const first_test = [_]Frame{ named("leaf"), named("walk"), named("walk"), named("main") };
const second_test = [_]Frame{ unnamed_test, named("main") };
const third_test = [_]Frame{ named("rare"), named("main") };
const fourth_test = [_]Frame{named("lost")};
const stacks_test = [_]server.SymbolStack{
    .{ .samples = 6, .frames = &first_test, .complete = true },
    .{ .samples = 2, .frames = &second_test, .complete = true },
    .{ .samples = 1, .frames = &third_test, .complete = true },
    .{ .samples = 1, .frames = &fourth_test, .complete = false },
};
const profile_test = Profile{
    .sample_hz = 99,
    .samples = 10,
    .samples_lost = 2,
    .windows_rejected = 0,
    .stacks = &stacks_test,
};

fn report_test(arena: std.mem.Allocator, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&out.writer, arena, &profile_test, .{
        .pid = 42,
        .name = "app",
        .elapsed_ms = 5040,
        .reason = .duration,
    }, options);
    return out.written();
}

fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "the header and the function table: self and total, recursion counted once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try report_test(arena.allocator(), .{});

    const header = "nusku  app [pid 42] \u{00b7} 5.0 s \u{00b7} 10 samples at 99 Hz";
    try testing.expect(has(text, header));
    try testing.expect(has(text, "duration reached"));
    try testing.expect(has(text, "! 2 samples lost"));
    // leaf: 60% self and total, bars of six full blocks.
    const six = " 60.0% " ++ "\u{2588}" ** 6 ++ "    ";
    try testing.expect(has(text, six ++ "  " ++ six ++ "  leaf  app\n"));
    // walk only called others: it is in the call tree, not here.
    try testing.expect(!has(text, "  walk  app\n"));
    try testing.expect(has(text, "4 of 4 that ran"));
    // Code without names has its self time, and no total.
    try testing.expect(has(text, "\u{2013}" ++ " " ** 13 ++ "[libc.so.6]\n"));
    try testing.expect(!has(text, "\x1b[")); // No colors unless asked.
}

test "the call tree: one column for a path, branches indented, recursion folded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try report_test(arena.allocator(), .{ .cutoff_tenths = 150 });

    // Two roots: main, and the stack whose walk stopped (under the cutoff: summed).
    try testing.expect(has(text, " 90.0%  \u{251c}\u{2500} main  app\n"));
    // main branches: walk, folded as it called itself, then the libc frame; rare is hidden.
    try testing.expect(has(text, " 60.0%  \u{2502}  \u{251c}\u{2500} walk \u{21bb}\n"));
    try testing.expect(has(text, " 60.0%  \u{2502}  \u{2502}  leaf\n"));
    try testing.expect(has(text, " 20.0%  \u{2502}  \u{251c}\u{2500} [libc.so.6]\n"));
    try testing.expect(has(text, " 10.0%  \u{2502}  \u{2514}\u{2500} \u{2026} 1 more\n"));
    try testing.expect(has(text, " 10.0%  \u{2514}\u{2500} \u{2026} 1 more\n"));
}

test "colors when asked, and the folded form for tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const colored = try report_test(arena.allocator(), .{ .color = true });
    try testing.expect(has(colored, term.red ++ " 60.0%"));

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try folded_write(&out.writer, arena.allocator(), &profile_test);
    try testing.expectEqualStrings(
        \\main;walk;walk;leaf 6
        \\main;[libc.so.6] 2
        \\main;rare 1
        \\[incomplete];lost 1
        \\
    , out.written());
}

test "the folded form marks kernel frames, named or not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frames = [_]Frame{
        .{ .address = 0xffffffff81000100, .kernel = true, .function = "clear_user" },
        .{ .address = 0xffffffff81000200, .kernel = true },
        .{ .address = 0x7100, .kernel = false, .function = "read_loop" },
    };
    const stacks = [_]server.SymbolStack{.{ .samples = 3, .frames = &frames, .complete = true }};
    const profile = Profile{
        .sample_hz = 99,
        .samples = 3,
        .samples_lost = 0,
        .windows_rejected = 0,
        .stacks = &stacks,
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try folded_write(&out.writer, arena.allocator(), &profile);
    try testing.expectEqualStrings("read_loop;[kernel];clear_user_[k] 3\n", out.written());
}

test "a profile with no samples says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty = Profile{
        .sample_hz = 99,
        .samples = 0,
        .samples_lost = 0,
        .windows_rejected = 0,
        .stacks = &.{},
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try write(&out.writer, arena.allocator(), &empty, .{ .pid = 1, .reason = .target_exited }, .{});
    try testing.expect(has(out.written(), "No samples"));
}

test "the live view: header and functions, drawn over the last view" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const summary = Summary{ .pid = 42, .name = "app", .elapsed_ms = 1200, .reason = null };

    const first = try live_write(&out.writer, arena.allocator(), &profile_test, summary, .{}, 0);
    const text = out.written();
    try testing.expect(has(text, "1.2 s"));
    try testing.expect(has(text, "live \u{00b7} Ctrl-C to stop"));
    try testing.expect(has(text, "leaf  app"));
    try testing.expect(!has(text, "Call tree")); // Only at the end.
    // As many lines as it says: the next view goes up by that many.
    try testing.expectEqual(std.mem.count(u8, text, "\n"), first);

    out.clearRetainingCapacity();
    _ = try live_write(&out.writer, arena.allocator(), &profile_test, summary, .{}, first);
    var up: [16]u8 = undefined;
    const expected = try std.fmt.bufPrint(&up, "\x1b[{d}F\x1b[J", .{first});
    try testing.expect(std.mem.startsWith(u8, out.written(), expected));
}
