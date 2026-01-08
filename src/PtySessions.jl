module PtySessions

export PtySession, write, read, readline, readavailable, readuntil
export isactive, close, kill, resize!, getsize

using Base: Process

"""
    PtySession

Represents a pseudo-terminal session with a running process.

# Fields
- `process::Process`: The underlying process
- `master_fd::Int`: Master PTY file descriptor
"""
mutable struct PtySession
    process::Process
    master_fd::Int

    function PtySession(process::Process, master_fd::Int)
        session = new(process, master_fd)
        finalizer(close, session)
        return session
    end
end

"""
    PtySession(cmd::Cmd; env=ENV, dir=pwd())

Create a new PTY session running the given command.

# Arguments
- `cmd::Cmd`: The command to run
- `env`: Environment variables (default: current environment)
- `dir`: Working directory (default: current directory)

# Returns
- `PtySession`: A new PTY session object

# Example
```julia
session = PtySession(`bash`)
write(session, "echo hello\\n")
output = readavailable(session)
close(session)
```
"""
function PtySession(cmd::Cmd; env=ENV, dir=pwd())
    # Create a pseudo-terminal using Julia's built-in support
    # Set up the command with environment and directory
    cmd_with_env = setenv(cmd, env)

    process = nothing
    master_fd = -1

    try
        # For true PTY support, we need to use ccall to posix_openpt, grantpt, unlockpt
        master_fd = ccall(:posix_openpt, Cint, (Cint,), Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_NOCTTY)
        if master_fd < 0
            error("Failed to open pseudo-terminal master: $(Base.Libc.strerror())")
        end

        ret = ccall(:grantpt, Cint, (Cint,), master_fd)
        if ret != 0
            ccall(:close, Cint, (Cint,), master_fd)
            error("Failed to grant pseudo-terminal: $(Base.Libc.strerror())")
        end

        ret = ccall(:unlockpt, Cint, (Cint,), master_fd)
        if ret != 0
            ccall(:close, Cint, (Cint,), master_fd)
            error("Failed to unlock pseudo-terminal: $(Base.Libc.strerror())")
        end

        # Get the slave name
        slave_name_ptr = ccall(:ptsname, Ptr{UInt8}, (Cint,), master_fd)
        if slave_name_ptr == C_NULL
            ccall(:close, Cint, (Cint,), master_fd)
            error("Failed to get pseudo-terminal slave name: $(Base.Libc.strerror())")
        end
        slave_name = unsafe_string(slave_name_ptr)

        # Open slave for the child process
        slave_fd = ccall(:open, Cint, (Ptr{UInt8}, Cint), slave_name, Base.Filesystem.JL_O_RDWR)
        if slave_fd < 0
            ccall(:close, Cint, (Cint,), master_fd)
            error("Failed to open pseudo-terminal slave: $(Base.Libc.strerror())")
        end

        # Create IO objects for slave (these will be used by the child process)
        slave_io = fdio(slave_fd, true)

        # Change to the requested directory and spawn the process
        original_dir = pwd()
        try
            cd(dir)
            # Spawn the process with the slave as stdin/stdout/stderr
            process = run(pipeline(cmd_with_env, stdin=slave_io, stdout=slave_io, stderr=slave_io), wait=false)
        finally
            cd(original_dir)
        end

        # Close our reference to slave (child has it open)
        close(slave_io)

        # The master is now our interface to the process
        return PtySession(process, Int(master_fd))

    catch e
        # Clean up on error
        if master_fd >= 0
            ccall(:close, Cint, (Cint,), master_fd)
        end
        rethrow(e)
    end
end

"""
    Base.write(session::PtySession, data::Union{String, Vector{UInt8}})

Write data to the PTY session.

# Arguments
- `session::PtySession`: The PTY session
- `data`: Data to write (String or bytes)

# Returns
- Number of bytes written
"""
function Base.write(session::PtySession, data::Union{String, Vector{UInt8}})
    if !isactive(session)
        error("Cannot write to inactive session")
    end

    bytes = data isa String ? Vector{UInt8}(data) : data
    written = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                    session.master_fd, bytes, length(bytes))

    if written < 0
        error("Failed to write to PTY: $(Base.Libc.strerror())")
    end

    return Int(written)
end

"""
    Base.read(session::PtySession, nb::Integer)

Read specified number of bytes from the PTY session.

# Arguments
- `session::PtySession`: The PTY session
- `nb::Integer`: Number of bytes to read

# Returns
- Vector{UInt8}: The bytes read
"""
function Base.read(session::PtySession, nb::Integer)
    if session.master_fd < 0
        return UInt8[]
    end

    buffer = Vector{UInt8}(undef, nb)
    nread = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                  session.master_fd, buffer, nb)

    if nread < 0
        return UInt8[]
    end

    return buffer[1:nread]
end

"""
    Base.readline(session::PtySession; keep::Bool=false)

Read a line from the PTY session.

# Arguments
- `session::PtySession`: The PTY session
- `keep::Bool`: Whether to keep the newline character

# Returns
- String: The line read
"""
function Base.readline(session::PtySession; keep::Bool=false)
    if session.master_fd < 0
        return ""
    end

    result = IOBuffer()
    while true
        buffer = Vector{UInt8}(undef, 1)
        nread = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                      session.master_fd, buffer, 1)

        if nread <= 0
            break
        end

        c = Char(buffer[1])
        if c == '\n'
            keep && write(result, c)
            break
        end
        write(result, c)
    end

    return String(take!(result))
end

"""
    readavailable(session::PtySession)

Read all currently available data from the PTY session without blocking.

# Arguments
- `session::PtySession`: The PTY session

# Returns
- String: The available data
"""
function readavailable(session::PtySession)
    if session.master_fd < 0
        return ""
    end

    # Use select to check if data is available without blocking
    # struct timeval { long tv_sec; long tv_usec; }
    timeout = zeros(Int64, 2)  # 0 seconds, 0 microseconds = immediate return

    # fd_set structure
    fd_set = zeros(UInt8, 128)  # Usually sizeof(fd_set) = 128 bytes
    # Set the bit for our fd
    byte_idx = div(session.master_fd, 8)
    bit_idx = mod(session.master_fd, 8)
    fd_set[byte_idx + 1] |= (1 << bit_idx)

    # Call select(nfds, readfds, writefds, exceptfds, timeout)
    nfds = session.master_fd + 1
    ret = ccall(:select, Cint, (Cint, Ptr{UInt8}, Ptr{Nothing}, Ptr{Nothing}, Ptr{Int64}),
                nfds, fd_set, C_NULL, C_NULL, timeout)

    if ret <= 0
        # No data available or error
        return ""
    end

    # Data is available, read it
    result = IOBuffer()
    buffer = Vector{UInt8}(undef, 4096)

    # Set to non-blocking for the read loop
    F_GETFL = 3
    F_SETFL = 4
    O_NONBLOCK = 0x0004

    old_flags = ccall(:fcntl, Cint, (Cint, Cint), session.master_fd, F_GETFL)
    ccall(:fcntl, Cint, (Cint, Cint, Cint), session.master_fd, F_SETFL, old_flags | O_NONBLOCK)

    while true
        nread = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                      session.master_fd, buffer, 4096)

        if nread > 0
            write(result, buffer[1:nread])
        else
            break
        end
    end

    # Restore blocking mode
    ccall(:fcntl, Cint, (Cint, Cint, Cint), session.master_fd, F_SETFL, old_flags)

    return String(take!(result))
end

"""
    Base.readuntil(session::PtySession, marker::Union{Char, String}; timeout=nothing)

Read from the PTY session until a marker is found or timeout occurs.

# Arguments
- `session::PtySession`: The PTY session
- `marker`: Character or string to read until
- `timeout`: Optional timeout in seconds

# Returns
- String: The data read up to and including the marker
"""
function Base.readuntil(session::PtySession, marker::Union{Char, String}; timeout=nothing)
    if session.master_fd < 0
        return ""
    end

    result = IOBuffer()
    marker_str = string(marker)
    start_time = time()

    while timeout === nothing || (time() - start_time < timeout)
        buffer = Vector{UInt8}(undef, 1)
        nread = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                      session.master_fd, buffer, 1)

        if nread <= 0
            if timeout === nothing
                break
            else
                sleep(0.01)
                continue
            end
        end

        write(result, buffer[1])

        # Check if we've hit the marker
        current = String(take!(result))
        if endswith(current, marker_str)
            return current
        end
        # Put it back
        write(result, current)
    end

    return String(take!(result))
end

"""
    isactive(session::PtySession)

Check if the PTY session is still active (process is running).

# Arguments
- `session::PtySession`: The PTY session

# Returns
- Bool: true if active, false otherwise
"""
function isactive(session::PtySession)
    return process_running(session.process)
end

"""
    Base.wait(session::PtySession)

Wait for the PTY session to complete.

# Arguments
- `session::PtySession`: The PTY session

# Returns
- The process exit status
"""
function Base.wait(session::PtySession)
    return wait(session.process)
end

"""
    Base.kill(session::PtySession, signal::Integer=Base.SIGTERM)

Send a signal to the PTY session process.

# Arguments
- `session::PtySession`: The PTY session
- `signal::Integer`: Signal to send (default: SIGTERM)
"""
function Base.kill(session::PtySession, signal::Integer=Base.SIGTERM)
    if isactive(session)
        kill(session.process, signal)
    end
end

"""
    Base.close(session::PtySession)

Close the PTY session and clean up resources.

# Arguments
- `session::PtySession`: The PTY session
"""
function Base.close(session::PtySession)
    # Close the file descriptor first (this will cause the process to terminate)
    if session.master_fd >= 0
        ccall(:close, Cint, (Cint,), session.master_fd)
        session.master_fd = -1
    end

    # Try to kill the process if still running (non-blocking)
    try
        if isactive(session)
            kill(session, Base.SIGKILL)
        end
    catch
        # Ignore errors during cleanup
    end

    return nothing
end

"""
    resize!(session::PtySession, rows::Int, cols::Int)

Resize the PTY window.

# Arguments
- `session::PtySession`: The PTY session
- `rows::Int`: Number of rows
- `cols::Int`: Number of columns
"""
function resize!(session::PtySession, rows::Int, cols::Int)
    if !isactive(session)
        error("Cannot resize inactive session")
    end

    # Get the file descriptor
    fd = session.master_fd

    # Define the winsize struct (from sys/ioctl.h)
    # struct winsize {
    #     unsigned short ws_row;
    #     unsigned short ws_col;
    #     unsigned short ws_xpixel;
    #     unsigned short ws_ypixel;
    # };
    winsize = zeros(UInt16, 4)
    winsize[1] = UInt16(rows)
    winsize[2] = UInt16(cols)
    winsize[3] = UInt16(0)  # xpixel (unused)
    winsize[4] = UInt16(0)  # ypixel (unused)

    # TIOCSWINSZ constant (from sys/ioctl.h)
    # On macOS: 0x80087467
    # On Linux: 0x5414
    @static if Sys.isapple()
        TIOCSWINSZ = 0x80087467
    elseif Sys.islinux()
        TIOCSWINSZ = 0x5414
    else
        error("Unsupported platform for resize!")
    end

    ret = ccall(:ioctl, Cint, (Cint, Culong, Ptr{UInt16}), fd, TIOCSWINSZ, winsize)
    if ret != 0
        error("Failed to resize PTY: $(Libc.strerror())")
    end

    return nothing
end

"""
    getsize(session::PtySession)

Get the current PTY window size.

# Arguments
- `session::PtySession`: The PTY session

# Returns
- Tuple{Int, Int}: (rows, columns)
"""
function getsize(session::PtySession)
    if !isactive(session)
        error("Cannot get size of inactive session")
    end

    # Get the file descriptor
    fd = session.master_fd

    # Create winsize struct to receive the size
    winsize = zeros(UInt16, 4)

    # TIOCGWINSZ constant
    @static if Sys.isapple()
        TIOCGWINSZ = 0x40087468
    elseif Sys.islinux()
        TIOCGWINSZ = 0x5413
    else
        error("Unsupported platform for getsize")
    end

    ret = ccall(:ioctl, Cint, (Cint, Culong, Ptr{UInt16}), fd, TIOCGWINSZ, winsize)
    if ret != 0
        error("Failed to get PTY size: $(Libc.strerror())")
    end

    rows = Int(winsize[1])
    cols = Int(winsize[2])

    return (rows, cols)
end

"""
    getpid(session::PtySession)

Get the process ID of the PTY session.

# Arguments
- `session::PtySession`: The PTY session

# Returns
- Int: The process ID
"""
function getpid(session::PtySession)
    return Base.getpid(session.process)
end

end # module PtySessions
