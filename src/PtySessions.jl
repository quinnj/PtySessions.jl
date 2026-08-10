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

export PtySession, expect, ExpectTimeoutError, isactive, exitcode, getsize, setecho, getecho

# The pty line discipline needs a signal we can't get from Base; value is 28 on
# both Linux and macOS.
const SIGWINCH = Cint(28)

const PendingBuffer = typeof(PipeBuffer())

"""
    PtySession <: IO

A pseudo-terminal session: a child process whose standard streams are attached
to the slave side of a pty, plus the master side wrapped as a Julia stream.

`PtySession` is an `IO`; reading from it reads the child's output (including
terminal echo of anything written), and writing to it feeds the child's input.
Reads and writes are integrated with Julia's event loop, so they block only the
calling task, never the whole process.

Reading from a session is single-consumer: interleave [`expect`](@ref),
`readline`, `readavailable`, etc. freely from one task, but don't read from
the same session concurrently from multiple tasks.

Construct with [`PtySession(cmd::Cmd)`](@ref); see [`isactive`](@ref),
`wait(session)`, `kill(session)`, `close(session)` for lifecycle management.
"""
mutable struct PtySession <: IO
    const process::Base.Process
    const master::Base.TTY
    const cmd::Cmd
    # output already pulled off the master but not yet consumed by the user
    # (expect reads ahead: data after a match arrives in the same chunk)
    const pending::PendingBuffer
    # in-flight `eof` waiter task, reused across expect calls that time out
    reader::Union{Task, Nothing}
    reader_generation::UInt
    wait_generation::UInt
    const reader_events::Channel{Tuple{UInt, UInt, Symbol}}
    # keeps close from releasing and reusing the fd during ioctl/termios calls
    const fd_lock::ReentrantLock
end

# ptsname(3) returns a pointer to static storage; serialize pty allocation so
# concurrent tasks/threads can't interleave between ptsname and open.
const PTY_ALLOC_LOCK = ReentrantLock()

"""
    PtySession(cmd::Cmd; env=nothing, dir=nothing, rows=24, cols=80, echo=true)

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
- `rows`, `cols`: initial window size of the pty, set before the child starts
  (a fresh pty otherwise reports 0×0, which confuses terminal programs).
- `echo`: whether the pty's line discipline echoes input back into the output
  stream (terminal default). Pass `false` for clean scripted interaction where
  written input should not reappear; see also [`setecho`](@ref).

# Notes
- With `echo=true`, written input reappears in the session's output, and line
  endings in the output are CRLF (`"\\r\\n"`).
- The child has no *controlling* terminal (libuv provides no `TIOCSCTTY`), so
  control characters written to the session (e.g. `"\\x03"`) do not generate
  signals; use `kill(session, sig)` to signal the child directly.

# Example
```julia
session = PtySession(`sh`; dir="/tmp", echo=false)
write(session, "echo hello\\n")
```
"""
function PtySession(cmd::Cmd; env=nothing, dir=nothing,
                    rows::Integer=24, cols::Integer=80, echo::Bool=true)
    (Sys.islinux() || Sys.isapple()) ||
        error("PtySessions requires POSIX pty support and only supports Linux and macOS; got $(Sys.KERNEL)")

    spawn_cmd = cmd
    env === nothing || (spawn_cmd = setenv(spawn_cmd, env))
    dir === nothing || (spawn_cmd = Cmd(spawn_cmd; dir=String(dir)))

    O_RDWR = Base.Filesystem.JL_O_RDWR
    O_NOCTTY = Base.Filesystem.JL_O_NOCTTY
    O_CLOEXEC = Base.Filesystem.JL_O_CLOEXEC

    # Allocate the pty pair. O_NOCTTY on the slave open matters: without it, a
    # session-leader Julia process without a controlling terminal would acquire
    # this pty as its controlling terminal as a side effect. CLOEXEC keeps the
    # pty fds out of unrelated child processes spawned concurrently elsewhere;
    # our child receives its stdio copies via dup2, which clears CLOEXEC on the
    # duplicates. Linux and macOS both accept O_CLOEXEC in posix_openpt, so set
    # it atomically at allocation time. A later fcntl would race unrelated
    # fork/exec activity in another thread.
    local master_fd::Cint, slave_fd::Cint
    lock(PTY_ALLOC_LOCK) do
        master_fd = ccall(:posix_openpt, Cint, (Cint,), O_RDWR | O_NOCTTY | O_CLOEXEC)
        Base.systemerror("posix_openpt", master_fd < 0)
        try
            Base.systemerror("grantpt", ccall(:grantpt, Cint, (Cint,), master_fd) != 0)
            Base.systemerror("unlockpt", ccall(:unlockpt, Cint, (Cint,), master_fd) != 0)
            name_ptr = ccall(:ptsname, Ptr{UInt8}, (Cint,), master_fd)
            Base.systemerror("ptsname", name_ptr == C_NULL)
            slave_name = unsafe_string(name_ptr)
            slave_fd = ccall(:open, Cint, (Cstring, Cint), slave_name, O_RDWR | O_NOCTTY | O_CLOEXEC)
            Base.systemerror("open($slave_name)", slave_fd < 0)
        catch
            ccall(:close, Cint, (Cint,), master_fd)
            rethrow()
        end
    end

    # Configure the terminal before the child starts, so it observes the
    # requested size and echo mode from its very first read.
    try
        _set_winsize(master_fd, rows, cols)
        echo || _set_echo(master_fd, false)
    catch
        ccall(:close, Cint, (Cint,), master_fd)
        ccall(:close, Cint, (Cint,), slave_fd)
        rethrow()
    end

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

    events = Channel{Tuple{UInt, UInt, Symbol}}(32)
    return PtySession(process, master, cmd, PipeBuffer(), nothing, 0, 0,
                      events, ReentrantLock())
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

# Run `f` with the raw master fd while preventing close/fd reuse. The fd must
# not escape the callback.
function _with_master_fd(f::F, s::PtySession) where {F}
    lock(s.fd_lock)
    try
        handle = s.master.handle
        (isopen(s.master) && handle != C_NULL) ||
            throw(Base.IOError("PtySession is closed", 0))
        fd = Ref{Cint}(-1)
        err = ccall(:uv_fileno, Cint, (Ptr{Cvoid}, Ptr{Cint}), handle, fd)
        err == 0 || throw(Base.IOError("PtySession is closed", err))
        return f(fd[])
    finally
        unlock(s.fd_lock)
    end
end

# ── IO interface ────────────────────────────────────────────────────────────
# Reads consult the pending (readahead) buffer first, then the master stream;
# writes go straight to the master.

# On Linux, read(2) on a pty master fails with EIO once the last slave fd is
# closed (i.e. the child exited and its terminal hung up); macOS/BSD return a
# clean EOF instead. Translate the hangup into EOF so sessions read uniformly
# on both platforms. Data buffered before the hangup is never lost: the error
# only surfaces once the stream's buffer is empty. Write errors are NOT
# translated — writing to a hung-up session is a real error.
_is_pty_hangup(e) = e isa Base.IOError && e.code == Base.UV_EIO

function _eof(master::Base.TTY)
    try
        return eof(master)
    catch e
        _is_pty_hangup(e) && return true
        rethrow()
    end
end

Base.isopen(s::PtySession) = isopen(s.master)
Base.eof(s::PtySession) = bytesavailable(s.pending) > 0 ? false : _eof(s.master)
Base.bytesavailable(s::PtySession) = bytesavailable(s.pending) + bytesavailable(s.master)

function Base.readavailable(s::PtySession)
    if bytesavailable(s.pending) > 0
        out = read(s.pending)
        bytesavailable(s.master) > 0 && append!(out, readavailable(s.master))
        return out
    end
    try
        return readavailable(s.master)
    catch e
        _is_pty_hangup(e) && return UInt8[]
        rethrow()
    end
end

function Base.read(s::PtySession, ::Type{UInt8})
    bytesavailable(s.pending) > 0 && return read(s.pending, UInt8)
    try
        return read(s.master, UInt8)
    catch e
        _is_pty_hangup(e) && throw(EOFError())
        rethrow()
    end
end

function Base.unsafe_read(s::PtySession, p::Ptr{UInt8}, n::UInt)
    nb = UInt(bytesavailable(s.pending))
    if nb > 0
        k = min(n, nb)
        unsafe_read(s.pending, p, k)
        n -= k
        p += k
    end
    if n > 0
        try
            unsafe_read(s.master, p, n)
        catch e
            _is_pty_hangup(e) && throw(EOFError())
            rethrow()
        end
    end
    return nothing
end

Base.write(s::PtySession, b::UInt8) = write(s.master, b)
Base.unsafe_write(s::PtySession, p::Ptr{UInt8}, n::UInt) = unsafe_write(s.master, p, n)
Base.flush(s::PtySession) = flush(s.master)
Base.isreadable(s::PtySession) = bytesavailable(s.pending) > 0 || isreadable(s.master)
Base.iswritable(s::PtySession) = iswritable(s.master)

# ── expect ──────────────────────────────────────────────────────────────────

"""
    ExpectTimeoutError(pattern, timeout)

Thrown by [`expect`](@ref) (and `readuntil` with a `timeout`) when the pattern
does not appear in the session's output within `timeout` seconds. Any output
consumed while waiting remains buffered and readable from the session.
"""
struct ExpectTimeoutError <: Exception
    pattern::Union{String, Regex}
    timeout::Float64
end

Base.showerror(io::IO, e::ExpectTimeoutError) =
    print(io, "ExpectTimeoutError: no match for ", repr(e.pattern),
          " in session output within ", e.timeout, " seconds")

const DEFAULT_EXPECT_TIMEOUT = 30.0

# Byte index in `data` of the end of the first match, or nothing. `searched` is
# how many leading bytes a previous call already established contain no match:
# a fixed string absent from data[1:searched] can only match starting within
# its last patlen-1 bytes, so resume there instead of rescanning from the top
# (keeps expect linear as output accumulates). A regex match can start anywhere
# once new bytes arrive (e.g. r"a.*b"), so regexes always rescan in full.
function _match_end(pattern::AbstractVector{UInt8}, data::Vector{UInt8}, searched::Int)
    start = max(1, searched - length(pattern) + 2)
    r = findnext(pattern, data, start)
    return r === nothing ? nothing : last(r)
end

_match_end(pattern::AbstractString, data::Vector{UInt8}, searched::Int) =
    _match_end(codeunits(String(pattern)), data, searched)

function _match_end(pattern::Regex, data::Vector{UInt8}, searched::Int)
    str = String(copy(data))
    m = match(pattern, str)
    m === nothing && return nothing
    return m.offset + ncodeunits(m.match) - 1
end

# Append everything currently readable on the master to `data`.
function _drain!(data::Vector{UInt8}, s::PtySession)
    while bytesavailable(s.master) > 0
        append!(data, readavailable(s.master))
    end
    return nothing
end

# Wait until the master has data (:data), reaches EOF (:eof), or the deadline
# passes (:timeout). `eof` blocks until one of the first two, so one reusable
# task publishes its result to a channel. A Timer publishes the timeout. Reader
# and wait generations let us discard late events without polling.
_remaining_timeout(started::UInt64, timeout::Float64, now::UInt64=time_ns()) =
    timeout - Float64(now - started) / 1.0e9

function _start_reader!(s::PtySession)
    generation = s.reader_generation + 1
    s.reader_generation = generation
    stream = s.master
    events = s.reader_events
    task = @async begin
        status = try
            _eof(stream) ? :eof : :data
        catch
            # Concurrent close tears down a waiter. Match the read-side EOF
            # semantics used elsewhere instead of exposing TaskFailedException.
            :eof
        end
        put!(events, (generation, 0, status))
        return status
    end
    s.reader = task
    return task, generation
end

function _finish_reader!(s::PtySession, task::Task)
    s.reader === task && (s.reader = nothing)
    return fetch(task)::Symbol
end

function _wait_input(s::PtySession, started::UInt64, timeout::Float64)
    bytesavailable(s.master) > 0 && return :data
    t = s.reader
    if t === nothing
        t, reader_generation = _start_reader!(s)
    elseif istaskdone(t)
        return _finish_reader!(s, t)
    else
        reader_generation = s.reader_generation
    end
    while true
        remaining = _remaining_timeout(started, timeout)
        remaining <= 0 && return :timeout
        s.wait_generation += 1
        wait_generation = s.wait_generation
        timer = if isfinite(remaining)
            interval = min(remaining, 3600.0)
            timer_status = remaining <= 3600.0 ? :timeout : :recheck
            Timer(interval) do _
                put!(s.reader_events,
                     (reader_generation, wait_generation, timer_status))
            end
        else
            nothing
        end
        try
            while true
                event_reader, event_wait, status = take!(s.reader_events)
                event_reader == reader_generation || continue
                if status === :data || status === :eof
                    return _finish_reader!(s, t)
                end
                event_wait == wait_generation || continue
                if istaskdone(t)
                    return _finish_reader!(s, t)
                elseif status === :timeout
                    return :timeout
                else
                    # A bounded internal timer expired for a very long user
                    # timeout. Recompute the remaining monotonic duration.
                    break
                end
            end
        finally
            timer === nothing || close(timer)
        end
    end
end

"""
    expect(session::PtySession, pattern::Union{AbstractString, Regex};
           timeout::Real=$(DEFAULT_EXPECT_TIMEOUT)) -> String

Read from the session until its output matches `pattern`, and return
everything read up to and including the match. Output arriving after the match
stays buffered for subsequent reads.

Throws [`ExpectTimeoutError`](@ref) if the pattern doesn't appear within
`timeout` seconds, and `EOFError` if the session's output ends without a
match; in both cases the output consumed while waiting remains buffered and
readable (e.g. via `readavailable`).

```julia
session = PtySession(`sh`; echo=false)
write(session, "echo result=\\\$((6 * 7))\\n")
expect(session, r"result=\\d+")   # ⇒ "… result=42"
```
"""
function expect(s::PtySession, pattern::Union{AbstractString, Regex};
                timeout::Real=DEFAULT_EXPECT_TIMEOUT)
    timeout_s = Float64(timeout)
    timeout_s > 0 || throw(ArgumentError("timeout must be positive, got $timeout"))
    pattern isa AbstractString && isempty(pattern) &&
        throw(ArgumentError("pattern must be non-empty"))
    started = time_ns()
    saw_eof = false
    searched = 0
    data = read(s.pending)
    search_pattern = pattern isa Regex ? pattern : collect(codeunits(String(pattern)))
    try
        while true
            _drain!(data, s)
            stop = _match_end(search_pattern, data, searched)
            if stop !== nothing
                output = String(data[1:stop])
                write(s.pending, @view data[stop+1:end])
                return output
            end
            searched = length(data)
            saw_eof && throw(EOFError())
            status = _wait_input(s, started, timeout_s)
            if status === :timeout
                throw(ExpectTimeoutError(pattern isa Regex ? pattern : String(pattern),
                                         timeout_s))
            elseif status === :eof
                saw_eof = true
            end
        end
    catch
        # expect consumes no output when it fails. Restore all accumulated data
        # once, so ordinary reads or another expect can continue from it.
        write(s.pending, data)
        rethrow()
    end
end

"""
    readuntil(session::PtySession, delim::AbstractString;
              keep::Bool=false, timeout::Real=Inf) -> String

Like `Base.readuntil`, with an optional `timeout` in seconds: read until
`delim` appears in the session's output and return everything before it
(including it when `keep=true`). Returns the data read so far if the output
ends before `delim` appears; throws [`ExpectTimeoutError`](@ref) on timeout.
"""
function Base.readuntil(s::PtySession, delim::AbstractString;
                        keep::Bool=false, timeout::Real=Inf)
    isempty(delim) && return ""
    matched = try
        expect(s, delim; timeout=timeout)
    catch e
        # Base.readuntil semantics: EOF before the delimiter yields the data
        # read so far rather than throwing
        e isa EOFError && return String(read(s.pending))
        rethrow()
    end
    keep && return matched
    bytes = codeunits(matched)
    return String(bytes[1:end-ncodeunits(String(delim))])
end

Base.readuntil(s::PtySession, delim::AbstractChar; kwargs...) =
    readuntil(s, string(delim); kwargs...)

"""
    close(session::PtySession; force::Bool=false)

Close the master side of the pty. Children that read their terminal observe
the hangup (end-of-file on macOS/BSD, `EIO` on Linux) and typically exit on
their own — though their exit status after a hangup is platform-dependent.
Call `wait(session)` afterwards to reap the process. With `force=true`, also
send `SIGKILL` to the child if it is still running.
"""
function Base.close(s::PtySession; force::Bool=false)
    lock(s.fd_lock)
    try
        close(s.master)
    finally
        unlock(s.fd_lock)
    end
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
    # the process can exit between the check and the pid query; show must not throw
    pid = Base.process_running(s.process) ? (try; getpid(s); catch; nothing; end) : nothing
    if pid !== nothing
        print(io, "running, pid=", pid)
    elseif Base.process_exited(s.process)
        print(io, "exited, code=", s.process.exitcode)
    else
        print(io, "running")
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

function _set_winsize(fd::Cint, rows::Integer, cols::Integer)
    (0 <= rows <= typemax(UInt16) && 0 <= cols <= typemax(UInt16)) ||
        throw(ArgumentError("rows and cols must be in 0:$(typemax(UInt16)), got ($rows, $cols)"))
    ws = Ref(WinSize(rows, cols, 0, 0))
    # ioctl(2) is variadic; the trailing `...` matters for ABI correctness
    # (on aarch64-darwin, variadic args are passed on the stack).
    ret = ccall(:ioctl, Cint, (Cint, Culong, Ptr{WinSize}...), fd, TIOCSWINSZ, ws)
    Base.systemerror("ioctl(TIOCSWINSZ)", ret != 0)
    return nothing
end

"""
    resize!(session::PtySession, rows::Integer, cols::Integer)

Set the pty's window size and notify the child with `SIGWINCH`. The child can
observe the new size (e.g. via `TIOCGWINSZ`, `stty size`, or
`\$LINES`/`\$COLUMNS` updates in shells).
"""
function Base.resize!(s::PtySession, rows::Integer, cols::Integer)
    _with_master_fd(s) do fd
        _set_winsize(fd, rows, cols)
    end
    # The child has no controlling terminal, so the kernel won't deliver
    # SIGWINCH on our behalf; notify it directly.
    isactive(s) && kill(s, SIGWINCH)
    return s
end

"""
    getsize(session::PtySession) -> (rows, cols)

Return the pty's current window size.
"""
function getsize(s::PtySession)
    ws = Ref(WinSize(0, 0, 0, 0))
    _with_master_fd(s) do fd
        ret = ccall(:ioctl, Cint, (Cint, Culong, Ptr{WinSize}...), fd, TIOCGWINSZ, ws)
        Base.systemerror("ioctl(TIOCGWINSZ)", ret != 0)
    end
    return (Int(ws[].ws_row), Int(ws[].ws_col))
end

# ── Echo control ────────────────────────────────────────────────────────────

# We only need the c_lflag field of struct termios, whose layout differs per
# platform: glibc has 32-bit tcflag_t with c_lflag at offset 12 (60-byte
# struct); Darwin has 64-bit tcflag_t with c_lflag at offset 24 (72-byte
# struct). ECHO is 0x8 and TCSANOW is 0 on both.
@static if Sys.isapple()
    const TERMIOS_SIZE = 72
    const LFLAG_OFFSET = 24
    const Tcflag = UInt64
else
    const TERMIOS_SIZE = 60
    const LFLAG_OFFSET = 12
    const Tcflag = UInt32
end
const ECHO_FLAG = Tcflag(0x8)
const TCSANOW = Cint(0)

function _get_lflag(fd::Cint)
    buf = zeros(UInt8, TERMIOS_SIZE)
    ret = ccall(:tcgetattr, Cint, (Cint, Ptr{UInt8}), fd, buf)
    Base.systemerror("tcgetattr", ret != 0)
    lflag = GC.@preserve buf unsafe_load(Ptr{Tcflag}(pointer(buf, LFLAG_OFFSET + 1)))
    return lflag, buf
end

function _set_echo(fd::Cint, on::Bool)
    lflag, buf = _get_lflag(fd)
    lflag = on ? (lflag | ECHO_FLAG) : (lflag & ~ECHO_FLAG)
    GC.@preserve buf unsafe_store!(Ptr{Tcflag}(pointer(buf, LFLAG_OFFSET + 1)), lflag)
    ret = ccall(:tcsetattr, Cint, (Cint, Cint, Ptr{UInt8}), fd, TCSANOW, buf)
    Base.systemerror("tcsetattr", ret != 0)
    return nothing
end

"""
    setecho(session::PtySession, on::Bool)

Enable or disable the pty's input echo. With echo off, data written to the
session no longer reappears in its output — usually what you want for scripted
interaction. See also the `echo` keyword of [`PtySession`](@ref) to configure
this before the child starts.
"""
function setecho(s::PtySession, on::Bool)
    _with_master_fd(s) do fd
        _set_echo(fd, on)
    end
    return nothing
end

"""
    getecho(session::PtySession) -> Bool

Return whether the pty currently echoes input.
"""
getecho(s::PtySession) = _with_master_fd(s) do fd
    (_get_lflag(fd)[1] & ECHO_FLAG) != 0
end

end # module PtySessions
