from rust:1.54.0-alpine3.14

env  CC=x86_64-alpine-linux-musl-gcc \
	   CXX=x86_64-alpine-linux-musl-gcc \
	   TARGET_CC=x86_64-alpine-linux-musl-gcc \
	   TARGET_CXX=x86_64-alpine-linux-musl-gcc \
     PKG_CONFIG_ALLOW_CROSS=1 \
	   PKG_CONFIG_ALL_STATIC=1 \
	   RUST_BACKTRACE=1 \
	   RUSTC_WRAPPER= \
     WASM_BUILD_NO_COLOR=1 

run TOOLCHAIN="nightly-$(apk --print-arch)-unknown-linux-musl" ; \
  rustup toolchain install "$TOOLCHAIN" && \
  rustup target add wasm32-unknown-unknown --toolchain "$TOOLCHAIN"

# Needed for building RocksDB
run apk add --no-cache \
  --virtual .rocksdb-build-deps \
  linux-headers python3 make gcc libc-dev g++

# Needed for building Substrate
run apk add --no-cache \
  openssl-dev openssl-libs-static protoc clang llvm-static llvm-dev \
  clang-static clang-dev eudev-dev pkgconfig

copy . /app

workdir /app

run gcc --version && \
  clang --version && \
  cargo build --release --verbose
