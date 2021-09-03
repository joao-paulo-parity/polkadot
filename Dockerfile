from rust:1.54.0-alpine3.14

run toolchain="nightly-$(apk --print-arch)-unknown-linux-musl"; \
  rustup toolchain install "$toolchain" && \
  rustup target add wasm32-unknown-unknown --toolchain "$toolchain"

# Needed for building RocksDB
run apk add --no-cache \
  --virtual .rocksdb-build-deps \
  linux-headers python3 make gcc libc-dev g++

# Needed for building Substrate
run apk add --no-cache \
  openssl-dev openssl-libs-static protoc clang llvm-static llvm-dev \
  clang-static clang-dev eudev-dev pkgconfig zlib-static libffi-dev \
  ncurses-static

copy . /app

workdir /app

run gcc="$(apk --print-arch)-alpine-linux-musl-gcc"; \
  CC="$gcc" \
  CXX="$gcc" \
  TARGET_CC="$gcc" \
  TARGET_CXX="$gcc" \
  PKG_CONFIG_ALLOW_CROSS=1 \
  PKG_CONFIG_ALL_STATIC=1 \
  RUST_BACKTRACE=1 \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
    cargo build --release --verbose
