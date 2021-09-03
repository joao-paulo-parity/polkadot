from rust:1.54.0-slim-bullseye

env RUST_TARGET=x86_64-unknown-linux-musl \
    APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends" \
    GCC=musl-gcc \
    PKG_CONFIG_ALL_STATIC=true \
    OPENSSL_STATIC=true

run rustup target add "$RUST_TARGET" && \
    rustup toolchain install --profile minimal nightly && \
    rustup target add wasm32-unknown-unknown --toolchain nightly

run apt update

# Used for Substrate
run $APT_INSTALL \
  zlib1g-dev libssl-dev libudev-dev pkg-config clang libclang-dev llvm musl \
  musl-dev musl-tools gcc libc-dev make g++ librocksdb-dev libsnappy-dev    \
  libbz2-dev libgflags-dev

copy . /app

workdir /app

run CC="$GCC" \
  CXX="$GCC" \
  TARGET_CC="$GCC" \
  TARGET_CXX="$GCC" \
  RUST_BACKTRACE=1 \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
  LIBCLANG_STATIC_PATH=/usr/lib \
  ROCKSDB_LIB_DIR=/usr/lib/ \
  ROCKSDB_STATIC=true \
  SNAPPY_LIB_DIR=/usr/lib \
  SNAPPY_STATIC=true \
    cargo build --target "$RUST_TARGET" --release --verbose
