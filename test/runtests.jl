using Test
using Aqua
using PtySessions

@testset "PtySessions.jl" begin

@testset "Aqua quality checks" begin
    Aqua.test_all(PtySessions)
end

@testset "creation and IO basics" begin
    s = PtySession(`cat`)
    @test s isa PtySession
    @test s isa IO
    @test isopen(s)
    @test isactive(s)
    @test isreadable(s)
    @test iswritable(s)

    # The master must be close-on-exec from the instant it is allocated. This
    # keeps unrelated children spawned by other threads from inheriting it.
    master_flags = PtySessions._with_master_fd(s) do fd
        ccall(:fcntl, Cint, (Cint, Cint), fd, Cint(1))
    end
    @test master_flags >= 0
    @test master_flags & 1 == 1

    write(s, "hello\n")
    # The pty echoes input by default (with CRLF), then cat's copy follows.
    echoed = readline(s)
    @test occursin("hello", echoed)
    output = readline(s)
    @test occursin("hello", output)

    close(s)
    @test !isopen(s)
    wait(s)          # cat sees EOF once the master closes and exits
    @test !isactive(s)
end

@testset "terminal operations serialize with close" begin
    s = PtySession(`cat`)
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    holder = @async PtySessions._with_master_fd(s) do _
        put!(entered, nothing)
        take!(release)
    end
    take!(entered)
    closer = @async close(s; force=true)
    yield()
    @test !istaskdone(closer)
    put!(release, nothing)
    wait(holder)
    wait(closer)
    wait(s)
    @test !isopen(s)
end

@testset "UTF-8 round trip" begin
    # Regression: the old byte-at-a-time readline re-encoded each UTF-8 byte
    # as its own Char, corrupting any non-ASCII output.
    s = PtySession(`cat`)
    write(s, "héllo wörld ✓\n")
    echoed = readline(s)
    @test occursin("héllo wörld ✓", echoed)
    close(s)
    wait(s)
end

@testset "readuntil follows Base semantics" begin
    s = PtySession(`cat`)
    write(s, "abc MARKER def\n")
    out = readuntil(s, "MARKER")
    @test occursin("abc", out)
    @test !occursin("MARKER", out)
    out = readuntil(s, "MARKER"; keep=true)
    @test endswith(out, "MARKER")
    @test readuntil(s, "") == ""
    @test readuntil(s, ""; keep=true, timeout=0) == ""
    close(s)
    wait(s)
end

@testset "read to EOF" begin
    s = PtySession(`sh -c "printf 'chunk1 '; printf 'chunk2\n'"`)
    data = read(s, String)
    @test occursin("chunk1 chunk2", data)
    wait(s)
    @test !isactive(s)
    close(s)
end

@testset "working directory" begin
    mktempdir() do tmp
        s = PtySession(`sh -c "pwd"`; dir=tmp)
        data = read(s, String)
        @test occursin(realpath(tmp), data)
        wait(s)
        close(s)
    end
end

@testset "environment" begin
    s = PtySession(`sh -c "echo VAR=\$MYVAR"`;
                   env=Dict("MYVAR" => "ptyval", "PATH" => ENV["PATH"]))
    data = read(s, String)
    @test occursin("VAR=ptyval", data)
    wait(s)
    close(s)
end

@testset "child sees a terminal" begin
    s = PtySession(`sh -c "test -t 0 && test -t 1 && test -t 2 && echo ISATTY"`)
    @test occursin("ISATTY", read(s, String))
    wait(s)
    close(s)
end

@testset "resize! and getsize" begin
    s = PtySession(`cat`)
    resize!(s, 30, 100)
    @test getsize(s) == (30, 100)
    @test resize!(s, 24, 80) === s
    @test getsize(s) == (24, 80)
    @test_throws ArgumentError resize!(s, -1, 80)
    @test_throws ArgumentError resize!(s, 24, 100_000)
    close(s)
    wait(s)
    # size queries on a closed session fail cleanly rather than using a stale fd
    @test_throws Base.IOError getsize(s)
    @test_throws Base.IOError resize!(s, 24, 80)
end

@testset "child observes resize" begin
    # The child blocks on `read` until we release it, so the resize is
    # guaranteed to land before stty queries the size.
    s = PtySession(`sh -c "read line; stty size"`)
    resize!(s, 37, 91)
    write(s, "go\n")
    data = read(s, String)
    @test occursin("37 91", data)
    wait(s)
    close(s)
end

@testset "initial window size" begin
    s = PtySession(`cat`)
    @test getsize(s) == (24, 80)      # default, not a confusing 0×0
    close(s)
    wait(s)

    # size is in place before the child's first instruction runs
    s = PtySession(`sh -c "stty size"`; rows=11, cols=42)
    data = read(s, String)
    @test occursin("11 42", data)
    wait(s)
    close(s)
end

@testset "echo control" begin
    # default: echo on — input appears twice (echo + cat's copy)
    s = PtySession(`cat`)
    @test getecho(s)
    write(s, "marker\n\x04")          # \x04 = VEOF at line start: cat exits
    data = read(s, String)
    @test count("marker", data) == 2
    wait(s)
    close(s)

    # echo=false: input appears exactly once
    s = PtySession(`cat`; echo=false)
    @test !getecho(s)
    write(s, "marker\n\x04")
    data = read(s, String)
    @test count("marker", data) == 1
    wait(s)
    close(s)

    # toggling at runtime
    s = PtySession(`cat`; echo=false)
    setecho(s, true)
    @test getecho(s)
    setecho(s, false)
    @test !getecho(s)
    close(s; force=true)
    wait(s)
end

@testset "process management" begin
    s = PtySession(`cat`)
    @test getpid(s) > 0
    kill(s)              # SIGTERM by default
    wait(s)
    @test !isactive(s)
    close(s)
end

@testset "expect" begin
    s = PtySession(`cat`; echo=false)
    write(s, "one\ntwo\nthree\n")
    out = expect(s, "two"; timeout=15)
    @test endswith(out, "two")
    @test occursin("one", out)
    # data after the match stays buffered for subsequent reads
    @test occursin("three", readuntil(s, "three"; keep=true, timeout=15))

    # regex pattern
    write(s, "code=1234 done\n")
    out = expect(s, r"code=\d+"; timeout=15)
    @test endswith(out, "code=1234")

    # print/println integrate via the IO interface
    println(s, "printed")
    @test occursin("printed", expect(s, "printed"; timeout=15))

    # timeout raises promptly and doesn't lose buffered data
    write(s, "leftover\n")
    start = time()
    @test_throws ExpectTimeoutError expect(s, "never-appears-4dc1"; timeout=0.5)
    @test time() - start < 10
    @test occursin("leftover", String(readavailable(s)))

    @test_throws ArgumentError expect(s, ""; timeout=5)
    @test_throws ArgumentError expect(s, "x"; timeout=0)

    # Real-valued timeouts are normalized once, and elapsed time uses the
    # monotonic clock rather than the adjustable wall clock.
    write(s, "bigfloat-timeout\n")
    @test occursin("bigfloat-timeout", expect(s, "bigfloat-timeout"; timeout=big"5.0"))
    @test PtySessions._remaining_timeout(UInt64(100), 2.0,
                                         UInt64(1_000_000_100)) == 1.0
    close(s; force=true)
    wait(s)
end

@testset "expect matches across chunk boundaries" begin
    # the marker arrives split across two writes while expect is waiting, so
    # the resumed (incremental) search must still see it straddle the boundary
    s = PtySession(`cat`; echo=false)
    writer = @async begin
        write(s, "ABC\n")
        sleep(0.3)
        write(s, "DEF\n")
    end
    out = expect(s, "\nDEF"; timeout=15)
    @test endswith(out, "\nDEF")
    wait(writer)
    close(s; force=true)
    wait(s)

    # incremental-search seam: a resumed search must back up far enough to
    # catch a match overlapping the already-searched prefix
    data = Vector{UInt8}("hello world")
    @test PtySessions._match_end("world", data, 6) == 11
    @test PtySessions._match_end("o w", data, 6) == 7
    @test PtySessions._match_end("xyz", data, 6) === nothing
end

@testset "expect hits EOF" begin
    s = PtySession(`sh -c "echo partial-output"`; echo=false)
    @test_throws EOFError expect(s, "no-such-marker"; timeout=15)
    # consumed output remains readable after the failed expect
    @test occursin("partial-output", String(readavailable(s)))
    wait(s)
    close(s)
end

@testset "readuntil with timeout" begin
    s = PtySession(`cat`; echo=false)
    write(s, "alpha;beta\n")
    @test readuntil(s, ";"; timeout=15) == "alpha"
    @test_throws ExpectTimeoutError readuntil(s, ";"; timeout=0.5)
    close(s; force=true)
    wait(s)

    # EOF before the delimiter returns partial data (Base semantics)
    s = PtySession(`sh -c "printf 'no-delimiter-here'"`; echo=false)
    @test readuntil(s, "ZZZ"; timeout=15) == "no-delimiter-here"
    wait(s)
    close(s)
end

@testset "resize! delivers SIGWINCH" begin
    s = PtySession(`sh -c "trap 'echo GOTWINCH' 28; echo READY; while :; do sleep 0.2; done"`;
                   echo=false)
    expect(s, "READY"; timeout=15)   # trap is installed before READY prints
    resize!(s, 31, 81)
    @test occursin("GOTWINCH", expect(s, "GOTWINCH"; timeout=15))
    @test getsize(s) == (31, 81)
    close(s; force=true)
    wait(s)
end

@testset "status accessors and show" begin
    s = PtySession(`sh -c "exit 3"`)
    wait(s)
    @test process_exited(s)
    @test !process_running(s)
    @test exitcode(s) == 3
    @test !success(s)
    @test occursin("exited, code=3", sprint(show, s))
    close(s)
    @test occursin("closed", sprint(show, s))

    s = PtySession(`cat`)
    @test process_running(s)
    @test_throws ArgumentError exitcode(s)
    shown = sprint(show, s)
    @test occursin("running, pid=", shown)
    @test occursin("cat", shown)
    close(s)
    wait(s)
    # cat exits after the hangup, but its status is platform-dependent:
    # 0 on macOS/BSD (clean EOF), nonzero on Linux (EIO)
    @test process_exited(s)

    # success == true for a child that exits 0 on its own
    s = PtySession(`sh -c "echo done"`)
    @test success(s)
    @test exitcode(s) == 0
    close(s)
end

@testset "do-block constructor" begin
    # child that exits on EOF: cleaned up via the graceful path
    result = PtySession(`cat`) do s
        write(s, "scoped\n")
        readline(s)
    end
    @test occursin("scoped", result)

    # child that ignores EOF: cleaned up via the SIGKILL grace timer
    local captured
    elapsed = @elapsed PtySession(`sleep 100`) do s
        captured = s
    end
    @test !isactive(captured)
    @test !isopen(captured)
    @test elapsed < 30

    # f's exception propagates and cleanup still happens
    local captured2
    @test_throws ErrorException PtySession(`cat`) do s
        captured2 = s
        error("boom")
    end
    @test !isactive(captured2)
    @test !isopen(captured2)
end

@testset "close(force=true) kills stubborn children" begin
    # sleep never reads its terminal, so EOF alone wouldn't stop it
    s = PtySession(`sleep 100`)
    close(s; force=true)
    wait(s)
    @test !isactive(s)
end

@testset "error paths" begin
    @test_throws Base.IOError PtySession(`this-command-does-not-exist-8b1b437c`)
    s = PtySession(`cat`)
    close(s; force=true)
    @test_throws Base.IOError write(s, "x")
    wait(s)
end

@testset "concurrent sessions" begin
    n = 6
    outs = Vector{String}(undef, n)
    @sync for i in 1:n
        @async begin
            s = PtySession(`sh -c $("echo session-$i")`)
            outs[i] = read(s, String)
            wait(s)
            close(s)
        end
    end
    for i in 1:n
        @test occursin("session-$i", outs[i])
    end
end

end # top-level testset
