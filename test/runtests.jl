using Test
using PtySessions

# Disable finalizers during testing to avoid cleanup issues
# Each test will explicitly close its sessions

println("Running PtySessions tests...")

@testset "PtySessions.jl" begin
    @testset "Portable errno handling" begin
        @test PtySessions._would_block(Base.Libc.EAGAIN)
        if isdefined(Base.Libc, :EWOULDBLOCK)
            @test PtySessions._would_block(getfield(Base.Libc, :EWOULDBLOCK))
        end
        @test !PtySessions._would_block(Base.Libc.EINTR)
    end

    @testset "Basic functionality" begin
        # Test 1: Creation and basic I/O
        session = PtySession(`cat`)
        @test session isa PtySession
        @test isactive(session)

        write(session, "hello\n")
        sleep(0.2)
        output = PtySessions.readavailable(session)
        @test occursin("hello", output)

        # Explicitly close without finalizer
        if session.master_fd >= 0
            ccall(:close, Cint, (Cint,), session.master_fd)
            session.master_fd = -1
        end
    end

    @testset "Working directory" begin
        tmpdir = mktempdir()
        session = PtySession(`sh -c "pwd"`; dir=tmpdir)
        sleep(0.3)
        output = PtySessions.readavailable(session)
        wait(session)
        @test occursin(tmpdir, output)

        # Cleanup
        if session.master_fd >= 0
            ccall(:close, Cint, (Cint,), session.master_fd)
            session.master_fd = -1
        end
        rm(tmpdir, recursive=true)
    end

    @testset "Environment variables" begin
        session = PtySession(`sh -c "echo \$TESTVAR"`; env=Dict("TESTVAR" => "testvalue"))
        sleep(0.3)
        output = PtySessions.readavailable(session)
        wait(session)
        @test occursin("testvalue", output)

        # Cleanup
        if session.master_fd >= 0
            ccall(:close, Cint, (Cint,), session.master_fd)
            session.master_fd = -1
        end
    end

    @testset "Process management" begin
        session = PtySession(`cat`)
        sleep(0.1)

        @test isactive(session)
        pid = PtySessions.getpid(session)
        @test pid > 0

        # Cleanup
        if session.master_fd >= 0
            ccall(:close, Cint, (Cint,), session.master_fd)
            session.master_fd = -1
        end
    end
end

println("All tests passed!")
