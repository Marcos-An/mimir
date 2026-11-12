# Used by CI through the CMAKE_TOOLCHAIN_FILE environment variable when
# building whisper.cpp (whisper-rs-sys). By default ggml optimizes for the
# build machine (GGML_NATIVE), so a binary built on a GitHub runner with
# AVX-512 would crash with "illegal instruction" on a friend's PC. Pin a
# portable baseline instead: AVX2 + FMA + F16C (Intel 2013+, AMD 2015+).
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_AVX ON CACHE BOOL "" FORCE)
set(GGML_AVX2 ON CACHE BOOL "" FORCE)
set(GGML_FMA ON CACHE BOOL "" FORCE)
set(GGML_F16C ON CACHE BOOL "" FORCE)
set(GGML_AVX512 OFF CACHE BOOL "" FORCE)
