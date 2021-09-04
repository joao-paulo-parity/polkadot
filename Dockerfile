from messense/rust-musl-cross:x86_64-musl

env TARGET=x86_64-unknown-linux-musl \
    APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends" \
    PKG_CONFIG_ALL_STATIC=true \
    PKG_CONFIG_ALLOW_CROSS=true \
    OPENSSL_ARCH=linux-x86_64 \
    LD="$TARGET-ld" \
    LDFLAGS="-L$TARGET_HOME/lib -rpath-link $TARGET_HOME/lib -lz"

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

run echo "[target.$TARGET]\nlinker = \"$TARGET-ld\"\nrustflags = [\"-Clink-arg=-L$TARGET_HOME/lib\",\"-Clink-arg=-rpath-link $TARGET_HOME/lib\",\"-Clink-arg=-lz\"]" > /root/.cargo/config

copy . /app

workdir /app

run RUST_BACKTRACE=1 \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
  ROCKSDB_COMPILE=1 \
  SNAPPY_COMPILE=1 \
  LZ4_COMPILE=1 \
  ZSTD_COMPILE=1 \
  BZ2_COMPILE=1 \
  CC="$TARGET_CC -static" \
  CXX="$TARGET_CXX -static" \
  Z_STATIC=1 \
  Z_LIB_DIR="$TARGET_HOME/lib" \
  cargo build --target "$RUST_MUSL_CROSS_TARGET" --release --verbose
