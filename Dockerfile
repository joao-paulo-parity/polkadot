from rust:1.54.0-slim-bullseye

env RUST_TARGET=x86_64-unknown-linux-musl \
    APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends" \
    GCC=musl-gcc

run rustup target add "$RUST_TARGET" && \
    rustup toolchain install --profile minimal nightly && \
    rustup target add wasm32-unknown-unknown --toolchain nightly

# Used for Substrate
run $APT_INSTALL \
  zlib-dev libssl-dev libudev-dev pkg-config clang libclang-dev llvm musl \
  musl-tools gcc libc-dev

copy . /app

workdir /app

run ls /usr/bin/*.a

run CC="$GCC" \
  CXX="$GCC" \
  TARGET_CC="$GCC" \
  TARGET_CXX="$GCC" \
  PKG_CONFIG_ALLOW_CROSS=1 \
  PKG_CONFIG_ALL_STATIC=1 \
  RUST_BACKTRACE=1 \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
    cargo build --target "$RUST_TARGET" --release --verbose
