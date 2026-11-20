# cli

A small command-line framework: commands and subcommands, flags, positional arguments, help
pages, and error messages. It knows nothing about profiling: `nusku-cli` (in
[`src/`](../src/README.md)) is built on it, and any Zig program could be.

You describe the commands as data, and `execute` does the parsing, help and errors. Your code
only runs when the command line is valid.

## Public API

Everything is in `root.zig`.

```zig
const cli = @import("cli");

const hello: cli.Command = .{
    .name = "hello",
    .short = "Say hello",                         // one line, in the parent's command list
    .long = "Says hello to someone, or to the world.",
    .flags = &.{
        .{ .name = "name", .short = 'n', .help = "Who to greet", .default = "world" },
        .{ .name = "times", .kind = .int, .default = "1", .env = "HELLO_TIMES" },
        .{ .name = "loud", .kind = .bool },
    },
    .args = .none,
    .run = run,
};

fn run(ctx: *cli.Context) anyerror!void {
    const times = ctx.getInt("times");
    if (times < 1) return ctx.usageFail("--times must be 1 or more (got {d})", .{times});
    for (0..@intCast(times)) |_| try ctx.stdout.print("hello, {s}\n", .{ctx.getString("name")});
}

const root: cli.Command = .{ .name = "tool", .subcommands = &.{&hello} };

pub fn main(init: std.process.Init) u8 {
    // ... argv without the program name, stdout and stderr writers ...
    return cli.execute(&root, argv, .{
        .io = init.io,
        .allocator = gpa,
        .stdout = &out.interface,
        .stderr = &err.interface,
        .version = "tool 1.0",
    });
}
```

| | |
|---|---|
| `Command` | `name`, `aliases`, `short`, `long`, `usage_args`, `flags`, `persistent_flags` (given to every subcommand too), `subcommands`, `args`, `hidden`, `run` |
| `Flag` | `name`, `short`, `kind` (`bool`, `string`, `int`), `help`, `default`, `env` (read when the flag is not given), `required` |
| `ArgsRule` | how many positional arguments: `any`, `none`, `exact`, `min`, `max`, `range` |
| `Context` | what `run` gets: `getString`, `getInt`, `getBool`, `isSet`, the positional `args`, `stdout`, `stderr`, an arena `allocator`, `io` |
| `ctx.fail(fmt, args)` | report an error (`tool: ...`) and exit 1 |
| `ctx.usageFail(fmt, args)` | report a misuse and point at `--help` (exit 2) |
| `execute(root, argv, options)` | parse, then run the command or print help or the error; returns the exit code |
| `parse(...)` | only the parsing, for tests or for a different runner |

`--help`/`-h` exist on every command, and `--version` when `version` is set. Help pages are
generated from the same data: usage, commands, flags with defaults and `[env: ...]`, then
the global flags.

## Architecture

| File | |
|---|---|
| `command.zig` | the types: `Command`, `Flag`, `ArgsRule`, `Context` |
| `parser.zig` | argv into the command it names, its positional arguments and its flag values |
| `help.zig` | help pages |
| `errors.zig` | the error messages and exit codes: 1 for a failure, 2 for a misuse |
| `execute.zig` | parse, then help, error or run |

## Tests

`zig build test` from the repository's root.
