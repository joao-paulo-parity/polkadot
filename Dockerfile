from rust:1.54.0-slim-bullseye

env RUST_TARGET=x86_64-unknown-linux-musl \
    APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends" \
    GCC=musl-gcc \
    LLD=musl-lld \
    PKG_CONFIG_ALL_STATIC=true \
    PKG_CONFIG_ALLOW_CROSS=true \
    OPENSSL_STATIC=true

run rustup target add "$RUST_TARGET" && \
    rustup toolchain install --profile minimal nightly && \
    rustup target add wasm32-unknown-unknown --toolchain nightly

run apt update

# Used for Substrate
run $APT_INSTALL \
  zlib1g-dev libssl-dev libudev-dev pkg-config clang libclang-dev llvm musl \
  musl-dev musl-tools gcc libc-dev make g++

copy . /app

workdir /app

run CC="$GCC" \
  CXX="g++" \
  TARGET_CC="$GCC" \
  TARGET_CXX="g++" \
  RUST_BACKTRACE=1 \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
    cargo build --target "$RUST_TARGET" --release --verbose
