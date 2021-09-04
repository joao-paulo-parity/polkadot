FROM rust:1.54.0-bullseye

ARG APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update

# ---- musl

ARG CROSS_MAKE_VERSION=0.9.9 \
  TARGET=x86_64-unknown-linux-musl \
  TARGET_HOME=/usr/local/musl/$TARGET

RUN export CROSS_MAKE_FOLDER=musl-cross-make-$CROSS_MAKE_VERSION && \
  export CROSS_MAKE_SOURCE=$CROSS_MAKE_FOLDER.zip && \
  cd /tmp && curl -Lsq https://github.com/richfelker/musl-cross-make/archive/v$CROSS_MAKE_VERSION.zip -o $CROSS_MAKE_SOURCE && \
  unzip -q $CROSS_MAKE_SOURCE && rm $CROSS_MAKE_SOURCE && \
  cd $CROSS_MAKE_FOLDER && \
  echo "OUTPUT=/usr/local/musl\nCOMMON_CONFIG += CFLAGS=\"-g0 -Os\" CXXFLAGS=\"-g0 -Os\" LDFLAGS=\"-s\"\nGCC_CONFIG += --enable-languages=c,c++" | tee config.mak && \
  make -j$(nproc) && make install && \
  ln -s /usr/local/musl/bin/$TARGET-strip /usr/local/musl/bin/musl-strip && \
  cd .. && rm -rf $CROSS_MAKE_FOLDER

ENV CC_EXE=$TARGET-gcc \
  C_INCLUDE_PATH=$TARGET_HOME/include/ \
  CC_STATIC_FLAGS="-static -static-libstdc++ -static-libgcc" \
  CC="$CC_EXE $_CC_STATIC_FLAGS" \
  CXX_EXE=$TARGET-g++ \
  CXX="$CXX_EXE $TARGET_CC_STATIC_FLAGS" \
  LD="$TARGET-ld" \
  LDFLAGS="-L$TARGET_HOME/lib"

# ---- ZLib (necessary to build OpenSSL)

ARG ZLIB_VERSION=1.2.11

RUN export ZLIB_FOLDER=zlib-$ZLIB_VERSION && \
  export ZLIB_SOURCE=$ZLIB_FOLDER.tar.gz && \
  cd /tmp && curl -sqLO https://zlib.net/$ZLIB_SOURCE && \
  tar xzf $ZLIB_SOURCE && rm $ZLIB_SOURCE && \
  cd $ZLIB_FOLDER && \
  ./configure --static --archs="-fPIC" --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $ZLIB_FOLDER

ENV LDFLAGS="$LDFLAGS -lz" \
  Z_STATIC=1 \
  Z_LIB_DIR=$TARGET_HOME/lib

# ---- OpenSSL

ARG OPENSSL_VERSION=1.0.2u \
    OPENSSL_ARCH=linux-x86_64

RUN export OPENSSL_FOLDER=openssl-$OPENSSL_VERSION && \
  export OPENSSL_SOURCE=$OPENSSL_FOLDER.tar.gz && \
  cd /tmp && curl -sqO https://www.openssl.org/source/$OPENSSL_SOURCE && \
  tar xzf $OPENSSL_SOURCE && rm $OPENSSL_SOURCE && \
  cd $OPENSSL_FOLDER && \
  ./Configure $OPENSSL_ARCH -fPIC --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $OPENSSL_FOLDER

ENV OPENSSL_STATIC=1 \
  OPENSSL_DIR=$TARGET_HOME/ \
  OPENSSL_INCLUDE_DIR=$TARGET_HOME/include/ \
  DEP_OPENSSL_INCLUDE=$TARGET_HOME/include/ \
  OPENSSL_LIB_DIR=$TARGET_HOME/lib/ \
  LDFLAGS="$LDFLAGS -lssl"

# ---- Substrate

RUN rustup toolchain install --profile minimal nightly && \
  rustup target add wasm32-unknown-unknown --toolchain nightly

ENV PKG_CONFIG_ALL_STATIC=true \
  PKG_CONFIG_ALLOW_CROSS=true

RUN $APT_INSTALL pkg-config

# use musl-gcc as the linker
# https://github.com/rust-lang/rust/issues/47693#issuecomment-360021149
run echo "[target.$TARGET]\nlinker = \"$TARGET-gcc\"\nrustflags = [\"-Clink-arg=-static\",\"-Clink-arg=-static-libstdc++\",\"\"-Clink-arg=-static-libgcc\",\"-Clink-arg=-Wl,-L$TARGET_HOME/lib\",\"-Clink-arg=-WL,-lz\",\"-Clink-arg=-WL,-lssl\"]" > $CARGO_HOME/config

copy . /app

workdir /app

run RUST_BACKTRACE=1 \
  WASM_BUILD_NO_COLOR=1 \
  RUSTC_WRAPPER= \
  ROCKSDB_COMPILE=1 \
  SNAPPY_COMPILE=1 \
  LZ4_COMPILE=1 \
  ZSTD_COMPILE=1 \
  BZ2_COMPILE=1 \
  cargo build --target $TARGET --release --verbose
