// Fails to compile on purpose: the test expects this diagnostic in the
// stderr of `zig build`.
#error cmake_zig_broken_source_diagnostic

int main(void) { return 0; }
