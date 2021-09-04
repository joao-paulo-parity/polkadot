from messense/rust-musl-cross:x86_64-musl

env APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends" \
    PKG_CONFIG_ALL_STATIC=true \
    PKG_CONFIG_ALLOW_CROSS=true \
    OPENSSL_ARCH=linux-x86_64

RUN export CC="$TARGET_CC -static" && \
    export C_INCLUDE_PATH=$TARGET_C_INCLUDE_PATH && \
    export LD=$TARGET-ld && \
    echo "Building OpenSSL" && \
    VERS=1.0.2u && \
    CHECKSUM=ecd0c6ffb493dd06707d38b14bb4d8c2288bb7033735606569d8f90f89669d16 && \
    curl -sqO https://www.openssl.org/source/openssl-$VERS.tar.gz && \
    echo "$CHECKSUM openssl-$VERS.tar.gz" > checksums.txt && \
    sha256sum -c checksums.txt && \
    tar xzf openssl-$VERS.tar.gz && cd openssl-$VERS && \
    CFLAGS=-fPIC ./Configure $OPENSSL_ARCH --prefix=$TARGET_HOME && \
    make -j$(nproc) && make install && \
    cd .. && rm -rf openssl-$VERS.tar.gz openssl-$VERS checksums.txt

ENV OPENSSL_DIR=$TARGET_HOME/ \
    OPENSSL_INCLUDE_DIR=$TARGET_HOME/include/ \
    DEP_OPENSSL_INCLUDE=$TARGET_HOME/include/ \
    OPENSSL_LIB_DIR=$TARGET_HOME/lib/ \
    OPENSSL_STATIC=1

run rustup toolchain install --profile minimal nightly && \
    rustup target add wasm32-unknown-unknown --toolchain nightly

run apt update

run $APT_INSTALL pkg-config

run echo "
[target.$TARGET]
linker = \"$TARGET-gcc\"
rustflags = [
  \"-Clink-arg=-static\",
  \"-Clink-arg=-static-libstdc++\",
  \"-Clink-arg=-static-libgcc\"
]" > /root/.cargo/config

copy . /app

workdir /app

run RUST_BACKTRACE=1 \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
  ROCKSDB_COMPILE=1 \
  SNAPPY_COMPILE=1 \
  LZ4_COMPILE=1 \
  ZSTD_COMPILE=1 \
  Z_COMPILE=1 \
  BZ2_COMPILE=1 \
  CC="$TARGET_CC -static" \
  CXX="$TARGET_CXX -static" \
  LD="$TARGET-ld" \
  CC_x86_64_unknown_linux_musl="$TARGET_CC -static" \
  CXX_x86_64_unknown_linux_musl="$TARGET_CXX -static" \
  cargo build --target "$RUST_MUSL_CROSS_TARGET" --release --verbose
