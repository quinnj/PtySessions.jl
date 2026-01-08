using Test
using PtySessions
import PtySessions: readavailable

println("Test 1: Basic creation")
s = PtySession(`cat`)
@test isactive(s)
close(s)
sleep(0.2)
println("✓ Test 1 passed")

println("Test 2: Write and read")
s = PtySession(`cat`)
sleep(0.1)
write(s, "hello\n")
sleep(0.2)
out = readavailable(s)
@test occursin("hello", out)
close(s)
println("✓ Test 2 passed")

println("All tests passed!")
