# PtySessions Specification

## Overview
PtySessions is a Julia package for managing pseudo-terminal (PTY) sessions. It provides a high-level interface for creating, managing, and interacting with PTY sessions.

## Core Features

### 1. PtySession Type
- Main type representing a PTY session
- Fields:
  - `process`: The underlying process
  - `master`: Master PTY file descriptor
  - `slave`: Slave PTY file descriptor (optional, for internal use)
  - `buffer`: IO buffer for reading output
  - `active`: Boolean indicating if session is active

### 2. Session Creation
- `PtySession(cmd::Cmd; env=ENV, dir=pwd())`: Create a new PTY session
  - Spawns command in a pseudo-terminal
  - Supports custom environment variables
  - Supports custom working directory
  - Returns PtySession object

### 3. Session Interaction
- `write(session::PtySession, data::String)`: Write data to PTY
- `read(session::PtySession)`: Read available output from PTY
- `readuntil(session::PtySession, marker::String; timeout=nothing)`: Read until marker found
- `readline(session::PtySession)`: Read a single line
- `readavailable(session::PtySession)`: Read all currently available data

### 4. Session Management
- `isactive(session::PtySession)`: Check if session is active
- `wait(session::PtySession)`: Wait for session to complete
- `kill(session::PtySession, signal=Base.SIGTERM)`: Send signal to session
- `close(session::PtySession)`: Close the PTY session

### 5. Utility Functions
- `resize!(session::PtySession, rows::Int, cols::Int)`: Resize PTY window
- `getsize(session::PtySession)`: Get current PTY size as (rows, cols)
- `pid(session::PtySession)`: Get process ID

## Implementation Requirements

### Platform Support
- Must work on Unix-like systems (Linux, macOS)
- Use Julia's built-in `ccall` for PTY operations
- Proper error handling for platform-specific operations

### Resource Management
- Proper cleanup of file descriptors
- Finalizers for automatic cleanup
- No resource leaks

### Error Handling
- Clear error messages
- Proper exception types
- Handle edge cases (closed sessions, terminated processes, etc.)

### Testing
- Unit tests for all public functions
- Integration tests for common workflows
- Test error conditions
- Test resource cleanup

## Example Usage

```julia
using PtySessions

# Create a bash session
session = PtySession(`bash`)

# Write commands
write(session, "echo Hello\n")

# Read output
output = readavailable(session)

# Clean up
close(session)
```
