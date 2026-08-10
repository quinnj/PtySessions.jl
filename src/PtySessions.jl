"""
    PtySessions

Create and interact with pseudo-terminal (PTY) sessions on Unix-like systems
(Linux, macOS).

A [`PtySession`](@ref) spawns a command with its stdin/stdout/stderr attached to
the slave side of a fresh pty, while the session object wraps the master side as
a normal Julia `IO`: `write`, `print`, `readline`, `readuntil`, `readavailable`,
`eachline`, etc. all work and cooperate with the task scheduler.

```julia
using PtySessions

session = PtySession(`cat`)
write(session, "hello\\n")
line = readline(session)   # "hello\\r" — the pty echoes input by default
close(session)
wait(session)
```
"""
module PtySessions

export PtySession, isactive, exitcode, getsize

# The pty line discipline needs a signal we can't get from Base; value is 28 on
# both Linux and macOS.
const SIGWINCH = Cint(28)

"""
    PtySession <: IO

A pseudo-terminal session: a child process whose standard streams are attached
to the slave side of a pty, plus the master side wrapped as a Julia stream.

`PtySession` is an `IO`; reading from it reads the child's output (including
terminal echo of anything written), and writing to it feeds the child's input.
Reads and writes are integrated with Julia's event loop, so they block only the
calling task, never the whole process.

Construct with [`PtySession(cmd::Cmd)`](@ref); see [`isactive`](@ref),
`wait(session)`, `kill(session)`, `close(session)` for lifecycle management.
"""
struct PtySession <: IO
    process::Base.Process
    master::Base.TTY
    cmd::Cmd
end

# ptsname(3) returns a pointer to static storage; serialize pty allocation so
# concurrent tasks/threads can't interleave between ptsname and open.
const PTY_ALLOC_LOCK = ReentrantLock()

"""
    PtySession(cmd::Cmd; env=nothing, dir=nothing)

Run `cmd` in a fresh pseudo-terminal and return the [`PtySession`](@ref)
connected to it.

The child process is placed in a new session (via `setsid`), with the pty slave
as its stdin, stdout, and stderr, so it believes it is talking to a real
terminal (`isatty` is true).

# Keyword arguments
- `env`: environment for the child (any value accepted by `setenv`, e.g. a
  `Dict` or vector of `"k=v"` strings). `nothing` (the default) inherits the
  current process environment. Note that when set, it *replaces* the entire
  environment — include `"PATH"` if the command needs it.
- `dir`: working directory for the child. `nothing` (the default) inherits the
  current working directory.

# Notes
- The pty's line discipline echoes input back by default, so written input
  reappears in the session's output with CRLF (`"\\r\\n"`) line endings.
- The child has no *controlling* terminal (libuv provides no `TIOCSCTTY`), so
  control characters written to the session (e.g. `"\\x03"`) do not generate
  signals; use `kill(session, sig)` to signal the child directly.

# Example
```julia
session = PtySession(`sh`; dir="/tmp")
write(session, "echo hello\\n")
```
"""
function PtySession(cmd::Cmd; env=nothing, dir=nothing)
    (Sys.islinux() || Sys.isapple()) ||
        error("PtySessions requires POSIX pty support and only supports Linux and macOS; got $(Sys.KERNEL)")

    spawn_cmd = cmd
    env === nothing || (spawn_cmd = setenv(spawn_cmd, env))
    dir === nothing || (spawn_cmd = Cmd(spawn_cmd; dir=String(dir)))

    O_RDWR = Base.Filesystem.JL_O_RDWR
    O_NOCTTY = Base.Filesystem.JL_O_NOCTTY

    # Allocate the pty pair. O_NOCTTY on the slave open matters: without it, a
    # session-leader Julia process without a controlling terminal would acquire
    # this pty as its controlling terminal as a side effect.
    local master_fd::Cint, slave_fd::Cint
    lock(PTY_ALLOC_LOCK) do
        master_fd = ccall(:posix_openpt, Cint, (Cint,), O_RDWR | O_NOCTTY)
        Base.systemerror("posix_openpt", master_fd < 0)
        try
            Base.systemerror("grantpt", ccall(:grantpt, Cint, (Cint,), master_fd) != 0)
            Base.systemerror("unlockpt", ccall(:unlockpt, Cint, (Cint,), master_fd) != 0)
            name_ptr = ccall(:ptsname, Ptr{UInt8}, (Cint,), master_fd)
            Base.systemerror("ptsname", name_ptr == C_NULL)
            slave_name = unsafe_string(name_ptr)
            slave_fd = ccall(:open, Cint, (Cstring, Cint), slave_name, O_RDWR | O_NOCTTY)
            Base.systemerror("open($slave_name)", slave_fd < 0)
        catch
            ccall(:close, Cint, (Cint,), master_fd)
            rethrow()
        end
    end

    # Keep the pty fds out of unrelated child processes spawned concurrently
    # elsewhere; our child receives its stdio copies via dup2, which clears
    # CLOEXEC on the duplicates.
    F_SETFD, FD_CLOEXEC = Cint(2), Cint(1)
    ccall(:fcntl, Cint, (Cint, Cint, Cint), master_fd, F_SETFD, FD_CLOEXEC)
    ccall(:fcntl, Cint, (Cint, Cint, Cint), slave_fd, F_SETFD, FD_CLOEXEC)

    local master::Base.TTY
    try
        master = Base.TTY(RawFD(master_fd))  # takes ownership of master_fd
    catch
        ccall(:close, Cint, (Cint,), master_fd)
        ccall(:close, Cint, (Cint,), slave_fd)
        rethrow()
    end

    local process::Base.Process
    try
        # detach: the child calls setsid(2), getting its own session and
        # process group like a program run from a real terminal.
        slave = RawFD(slave_fd)
        process = run(detach(spawn_cmd), slave, slave, slave; wait=false)
    catch
        close(master)
        ccall(:close, Cint, (Cint,), slave_fd)
        rethrow()
    end

    # The child holds its own dups of the slave; drop ours so that when the
    # child exits, reads on the master see EOF.
    ccall(:close, Cint, (Cint,), slave_fd)

    return PtySession(process, master, cmd)
end

"""
    PtySession(f::Function, cmd::Cmd; kwargs...)

Run `f(session)` with a fresh [`PtySession`](@ref), guaranteeing cleanup: when
`f` returns (or throws), the master side is closed, the child is given a grace
period of `2` seconds to exit on its own (most terminal programs exit on EOF),
then force-killed if necessary, and finally reaped. Returns `f`'s return value.

```julia
output = PtySession(`cat`) do session
    write(session, "hi\\n")
    readline(session)
end
```
"""
function PtySession(f::Function, cmd::Cmd; kwargs...)
    session = PtySession(cmd; kwargs...)
    try
        return f(session)
    finally
        close(session)
        if isactive(session)
            grace = Timer(2.0) do _
                isactive(session) && kill(session, Base.SIGKILL)
            end
            wait(session)
            close(grace)
        end
    end
end

# Raw fd of the master, for ioctls. Only valid while the session is open.
function _master_fd(s::PtySession)
    isopen(s.master) || throw(Base.IOError("PtySession is closed", 0))
    fd = Ref{Cint}(-1)
    err = ccall(:uv_fileno, Cint, (Ptr{Cvoid}, Ptr{Cint}), s.master.handle, fd)
    err == 0 || throw(Base.IOError("PtySession is closed", err))
    return fd[]
end

# ── IO interface: forward to the master stream ──────────────────────────────

Base.isopen(s::PtySession) = isopen(s.master)
Base.eof(s::PtySession) = eof(s.master)
Base.bytesavailable(s::PtySession) = bytesavailable(s.master)
Base.readavailable(s::PtySession) = readavailable(s.master)
Base.read(s::PtySession, ::Type{UInt8}) = read(s.master, UInt8)
Base.unsafe_read(s::PtySession, p::Ptr{UInt8}, n::UInt) = unsafe_read(s.master, p, n)
Base.write(s::PtySession, b::UInt8) = write(s.master, b)
Base.unsafe_write(s::PtySession, p::Ptr{UInt8}, n::UInt) = unsafe_write(s.master, p, n)
Base.flush(s::PtySession) = flush(s.master)
Base.isreadable(s::PtySession) = isreadable(s.master)
Base.iswritable(s::PtySession) = iswritable(s.master)

"""
    close(session::PtySession; force::Bool=false)

Close the master side of the pty. Children that read their terminal see EOF
and typically exit on their own; call `wait(session)` afterwards to reap the
process. With `force=true`, also send `SIGKILL` to the child if it is still
running.
"""
function Base.close(s::PtySession; force::Bool=false)
    close(s.master)
    force && isactive(s) && kill(s.process, Base.SIGKILL)
    return nothing
end

# ── Process management ──────────────────────────────────────────────────────

"""
    isactive(session::PtySession) -> Bool

Return `true` while the session's child process is still running.
"""
isactive(s::PtySession) = Base.process_running(s.process)

"""
    wait(session::PtySession)

Wait for the session's child process to exit.
"""
Base.wait(s::PtySession) = wait(s.process)

"""
    kill(session::PtySession, signum=Base.SIGTERM)

Send the signal `signum` to the session's child process. No-op if the process
has already exited.
"""
Base.kill(s::PtySession, signum::Integer=Base.SIGTERM) = kill(s.process, signum)

"""
    getpid(session::PtySession) -> Int

Return the OS process ID of the session's child process. Throws if the process
has already exited.
"""
Base.getpid(s::PtySession) = getpid(s.process)

"""
    process_running(session::PtySession) -> Bool
    process_exited(session::PtySession) -> Bool

Whether the session's child process is still running / has exited.
`process_running` is the same as [`isactive`](@ref).
"""
Base.process_running(s::PtySession) = Base.process_running(s.process)
Base.process_exited(s::PtySession) = Base.process_exited(s.process)

"""
    success(session::PtySession) -> Bool

Wait for the session's child process to exit and return `true` if it exited
with status 0 and was not killed by a signal.
"""
Base.success(s::PtySession) = success(s.process)

"""
    exitcode(session::PtySession) -> Int

Exit status of the session's child process. Throws if the process is still
running. Note that for a child killed by a signal, see
`Base.process_signaled`/`s.process.termsignal`.
"""
function exitcode(s::PtySession)
    Base.process_exited(s.process) ||
        throw(ArgumentError("process has not exited; call wait(session) first"))
    return Int(s.process.exitcode)
end

function Base.show(io::IO, s::PtySession)
    print(io, "PtySession(", s.cmd, ", ")
    if Base.process_running(s.process)
        print(io, "running, pid=", getpid(s))
    elseif Base.process_exited(s.process)
        print(io, "exited, code=", s.process.exitcode)
    else
        print(io, "not started")
    end
    isopen(s) || print(io, ", closed")
    print(io, ")")
end

# ── Terminal size ───────────────────────────────────────────────────────────

struct WinSize
    ws_row::UInt16
    ws_col::UInt16
    ws_xpixel::UInt16
    ws_ypixel::UInt16
end

@static if Sys.isapple()
    const TIOCGWINSZ = Culong(0x40087468)
    const TIOCSWINSZ = Culong(0x80087467)
else
    const TIOCGWINSZ = Culong(0x5413)
    const TIOCSWINSZ = Culong(0x5414)
end

"""
    resize!(session::PtySession, rows::Integer, cols::Integer)

Set the pty's window size. The child can observe the new size (e.g. via
`TIOCGWINSZ`, `stty size`, or `\$LINES`/`\$COLUMNS` updates in shells).
"""
function Base.resize!(s::PtySession, rows::Integer, cols::Integer)
    (0 <= rows <= typemax(UInt16) && 0 <= cols <= typemax(UInt16)) ||
        throw(ArgumentError("rows and cols must be in 0:$(typemax(UInt16)), got ($rows, $cols)"))
    ws = Ref(WinSize(rows, cols, 0, 0))
    # ioctl(2) is variadic; the trailing `...` matters for ABI correctness
    # (on aarch64-darwin, variadic args are passed on the stack).
    ret = ccall(:ioctl, Cint, (Cint, Culong, Ptr{WinSize}...), _master_fd(s), TIOCSWINSZ, ws)
    Base.systemerror("ioctl(TIOCSWINSZ)", ret != 0)
    return s
end

"""
    getsize(session::PtySession) -> (rows, cols)

Return the pty's current window size.
"""
function getsize(s::PtySession)
    ws = Ref(WinSize(0, 0, 0, 0))
    ret = ccall(:ioctl, Cint, (Cint, Culong, Ptr{WinSize}...), _master_fd(s), TIOCGWINSZ, ws)
    Base.systemerror("ioctl(TIOCGWINSZ)", ret != 0)
    return (Int(ws[].ws_row), Int(ws[].ws_col))
end

end # module PtySessions
