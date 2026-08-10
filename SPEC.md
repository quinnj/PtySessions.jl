# PtySessions Specification

## Overview
PtySessions is a Julia package for managing pseudo-terminal (PTY) sessions:
spawning commands attached to a pty slave and interacting with them through
the master side as a standard Julia `IO`.

## Core Features

### 1. PtySession Type
- `PtySession <: IO`; reads return the child's output, writes feed its input
- Wraps the child `Process` and the pty master as a libuv-backed stream
  (`Base.TTY`), so all I/O cooperates with Julia's task scheduler
- Maintains a readahead buffer so pattern-matching reads (`expect`) compose
  with plain IO reads

### 2. Session Creation
- `PtySession(cmd::Cmd; env=nothing, dir=nothing, rows=24, cols=80, echo=true)`
  - Spawns the command in a fresh pty, in its own session (`setsid`)
  - `env`/`dir` use `Cmd`'s native support (no global state mutation)
  - Initial window size is applied before the child starts
  - `echo=false` disables terminal echo for scripted interaction
- `PtySession(f::Function, cmd::Cmd; kwargs...)` do-block form with guaranteed
  cleanup (close, grace period, force-kill, reap)

### 3. Session Interaction
- The standard `IO` interface: `write`, `print`, `readline`, `readavailable`,
  `read`, `eachline`, `eof`, `bytesavailable`, …
- `expect(session, pattern::Union{AbstractString,Regex}; timeout=30)`: read
  until the output matches, return everything through the match; throws
  `ExpectTimeoutError` on timeout, `EOFError` at end of output
- `readuntil(session, delim; keep=false, timeout=Inf)`: `Base.readuntil`
  semantics plus optional timeout

### 4. Session Management
- `PtySessions.isactive(session)` (alias of `process_running`), `process_exited`
- `wait(session)`, `success(session)`, `PtySessions.exitcode(session)`
- `kill(session, signum=SIGTERM)` signals the session's private process group
- `getpid(session)` (extends `Base.getpid`)
- `close(session; force=false)`: closes the master; `force=true` also SIGKILLs
  the session process group

### 5. Terminal Control
- `resize!(session, rows, cols)`: set window size, deliver SIGWINCH
- `displaysize(session)` / `PtySessions.getsize(session)`: current `(rows, cols)`
- `PtySessions.setecho(session, on)` / `PtySessions.getecho(session)`: input echo control

## Implementation Requirements

### Platform Support
- Unix-like systems (Linux, macOS); clear error on other platforms
- `ccall` only for the pty syscall layer (`posix_openpt`, `grantpt`,
  `unlockpt`, `ptsname`, `ioctl`, `tcgetattr`/`tcsetattr`); all streaming I/O
  goes through Julia's event loop, never raw blocking `read`/`write` ccalls
- `ioctl` ccalls must declare the pointer argument variadic (ABI correctness
  on aarch64-darwin)

### Resource Management
- Every fd owned by exactly one object; no double-close paths
- Pty fds are CLOEXEC so unrelated children can't inherit them
- Slave opened with `O_NOCTTY`; parent never acquires the pty as its
  controlling terminal
- Pty allocation serialized (ptsname's static buffer is not thread-safe)

### Error Handling
- Syscall failures raise `SystemError` with errno captured at the failure site
- `ExpectTimeoutError` for pattern timeouts; buffered output is never lost on
  error paths
- Clear messages for closed-session operations

### Testing
- Unit tests for all public functions, error conditions, and cleanup paths
- Aqua.jl quality checks (ambiguities, piracy, export hygiene)
- Known limitation (documented, inherent to libuv spawn): the child has no
  controlling terminal, so line-discipline signal generation (^C) and
  kernel-delivered SIGHUP/SIGWINCH don't apply; the package delivers signals
  directly instead

## Example Usage

```julia
using PtySessions

PtySession(`sh`; echo=false) do session
    write(session, "echo hello\n")
    expect(session, "hello")
end
```
