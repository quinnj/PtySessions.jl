using Test
using PtySessions

@testset "PtySessions.jl" begin

@testset "creation and IO basics" begin
    s = PtySession(`cat`)
    @test s isa PtySession
    @test s isa IO
    @test isopen(s)
    @test isactive(s)
    @test isreadable(s)
    @test iswritable(s)

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

@testset "process management" begin
    s = PtySession(`cat`)
    @test getpid(s) > 0
    kill(s)              # SIGTERM by default
    wait(s)
    @test !isactive(s)
    close(s)
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
    @test success(s)     # cat exits 0 on EOF; success waits for it
    @test exitcode(s) == 0
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
    @test_throws Exception write(s, "x")
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
