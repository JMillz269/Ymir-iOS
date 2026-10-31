#!/bin/bash
# Builds and runs the CHD converter test against a library-only build of ymir-core (BUILD, default /tmp/bcorepic).
# Usage: build.sh [disc image to convert as well...]
set -e
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD=${BUILD:-/tmp/bcorepic}
CXX=${CXX:-g++}
OUT=${OUT:-/tmp/chd_convert_test}
$CXX -std=gnu++20 -O2 -g -DYmir_HAS_ZLIB=1 -DYmir_ENABLE_DEVLOG=1 -DYmir_EXTRA_INLINING=1 -DYmir_DEV_ASSERTIONS=0 \
    -I"$SRC/libs/ymir-core/include" -I"$SRC/libs/ymir-core/src" -I"$BUILD/libs/ymir-core/include" \
    -I"$BUILD/_cmrc/include" -I"$SRC/vendor/fmt/include" -I"$SRC/vendor/mio/include" \
    -I"$SRC/vendor/concurrentqueue/concurrentqueue" -I"$SRC/vendor/xxHash/xxHash" \
    -I"$SRC/vendor/libchdr/libchdr/include" \
    "$SRC/tools/chd-tests/chd_convert_test.cpp" "$SRC/libs/ymir-core/src/ymir/media/chd_convert.cpp" -o "$OUT" \
    -Wl,--whole-archive "$BUILD/libs/ymir-core/libymir-core.a" -Wl,--no-whole-archive \
    "$BUILD/libs/ymir-core/libymir-core-shaders.a" "$BUILD/vendor/fmt/libfmt.a" "$BUILD/vendor/xxHash/libxxHash.a" \
    "$BUILD/vendor/libchdr/libchdr-static.a" "$BUILD/vendor/libchdr/libchdr/deps/miniz-3.1.2/libminiz.a" \
    "$BUILD/vendor/libchdr/libchdr/deps/zstd-1.5.7/libzstd.a" "$BUILD/vendor/libchdr/libchdr/deps/lzma-26.02/libchdr-lzma.a" \
    -lz -lpthread
"$OUT" "$@"
