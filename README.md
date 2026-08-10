# PtySessions.jl

[![CI](https://github.com/quinnj/PtySessions.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/quinnj/PtySessions.jl/actions/workflows/CI.yml)

Run commands in pseudo-terminal (PTY) sessions from Julia and interact with
them programmatically — the moral equivalent of Python's
[pexpect](https://pexpect.readthedocs.io/)/ptyprocess, built on Julia's own
event loop.

Programs behave differently when connected to a terminal: they enable prompts,
line editing, colors, progress bars, and password input. `PtySessions` spawns a
command with its stdin/stdout/stderr attached to a real pty slave, so the child
sees `isatty(0) == true`, while your Julia code holds the master side as a
plain `IO`.

Supports Linux and macOS. Requires Julia 1.10+.

## Quickstart

```julia
using PtySessions

session = PtySession(`sh`; echo=false)
write(session, "echo hello world\n")
line = readline(session)          # "hello world\r"  (terminal newlines are CRLF)
close(session)
wait(session)
```

`PtySession <: IO`, so the whole standard IO vocabulary works: `write`,
`print`/`println`, `readline`, `readuntil`, `readavailable`, `read(session,
String)`, `eachline`, ….

## Driving interactive programs with `expect`

`expect` reads until the output matches a `String` or `Regex` and returns
everything through the end of the match (later output stays buffered):

```julia
session = PtySession(`julia --startup-file=no -q`; echo=false)
expect(session, "julia>")                  # wait for the prompt
write(session, "6 * 7\n")
expect(session, r"\d+")                    # ⇒ "…42"
close(session; force=true)
wait(session)
```

On timeout, `expect` throws `ExpectTimeoutError`; if the output ends first, it
throws `EOFError`. Either way, the output consumed while waiting stays
buffered and readable. `readuntil(session, delim; timeout=...)` offers the
same with `Base.readuntil` semantics (delimiter excluded unless `keep=true`,
partial data returned at EOF).

For guaranteed cleanup, use the do-block form — it closes the pty, waits
briefly for the child to exit on EOF, and force-kills it if necessary:

```julia
PtySession(`cat`) do session
    write(session, "hi\n")
    readline(session)
end
```

## API overview

Session setup:

- `PtySession(cmd::Cmd; env=nothing, dir=nothing, rows=24, cols=80, echo=true)`
- `PtySession(f::Function, cmd::Cmd; kwargs...)` — do-block form with cleanup

Interaction (beyond the standard `IO` interface):

- `expect(session, pattern::Union{AbstractString,Regex}; timeout=30)`
- `readuntil(session, delim; keep=false, timeout=Inf)`

Process management:

- `isactive(session)` / `process_running` / `process_exited`
- `wait(session)`, `success(session)`, `exitcode(session)`, `getpid(session)`
- `kill(session, signum=SIGTERM)`
- `close(session; force=false)` — closes the pty; `force=true` also SIGKILLs

Terminal control:

- `resize!(session, rows, cols)` — set window size and notify the child (SIGWINCH)
- `getsize(session)` — current `(rows, cols)`
- `setecho(session, on)` / `getecho(session)` — toggle input echo

## Terminal behavior notes

- **Echo**: a pty echoes input back by default, so everything you `write`
  reappears in the output stream. Pass `echo=false` (or call
  `setecho(session, false)`) for clean scripted interaction.
- **CRLF**: terminal output translates `\n` to `\r\n` (ONLCR). Expect `"\r\n"`
  line endings when matching output.
- **No controlling terminal**: the child runs in its own session (`setsid`),
  but libuv provides no way to make the pty its *controlling* terminal.
  Consequences: writing control characters like `"\x03"` does not deliver
  SIGINT (use `kill(session, Base.SIGINT)` to signal the session process
  group), the kernel does not send SIGHUP when the master closes (most programs
  still exit on the EOF they see), and job-control shells print a "no job
  control" warning. This matches the fake-pty approach Julia's own test suite
  uses.
- **Hangup on close**: `close(session)` closes the master; children reading
  their terminal observe the hangup (EOF on macOS/BSD, `EIO` on Linux) and
  typically exit — `wait(session)` then reaps. Reads from the session side
  uniformly report EOF either way. For children that ignore their terminal,
  use `close(session; force=true)`.

## Alternatives

- `Base.run`/`pipeline` — when the child doesn't need to believe it's on a
  terminal, plain pipes are simpler and faster.
- [Expect.jl](https://gitlab.com/wavexx/Expect.jl) — an earlier take on
  pexpect-style interaction for Julia.
