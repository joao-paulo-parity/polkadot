FROM rust:1.54.0-slim-buster

# TODO: checksum verification for all downloaded packages

ARG APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends"

ENV DEBIAN_FRONTEND=noninteractive

# --- Setup for building dependencies

RUN apt update && \
  $APT_INSTALL curl unzip cmake make build-essential wget && \
  make --version && \
  curl --version && \
  unzip -v && \
  cmake --version && \
  wget --version

# ---- musl

ENV CROSS_MAKE_VERSION=0.9.9 \
  TARGET=x86_64-unknown-linux-musl \
  TARGET_HOME=/usr/local/musl/$TARGET

RUN echo "$TARGET_HOME"

RUN export CROSS_MAKE_FOLDER=musl-cross-make-$CROSS_MAKE_VERSION && \
  export CROSS_MAKE_SOURCE=$CROSS_MAKE_FOLDER.zip && \
  cd /tmp && curl -Lsq https://github.com/richfelker/musl-cross-make/archive/v$CROSS_MAKE_VERSION.zip -o $CROSS_MAKE_SOURCE && \
  unzip -q $CROSS_MAKE_SOURCE && rm $CROSS_MAKE_SOURCE && \
  cd $CROSS_MAKE_FOLDER && \
  echo "OUTPUT=/usr/local/musl\nCOMMON_CONFIG += CFLAGS=\"-g0 -Os\" CXXFLAGS=\"-g0 -Os\" LDFLAGS=\"-s\"\nGCC_CONFIG += --enable-languages=c,c++" | tee config.mak && \
  make -j$(nproc) && make install && \
  ln -s /usr/local/musl/bin/$TARGET-strip /usr/local/musl/bin/musl-strip && \
  cd .. && rm -rf $CROSS_MAKE_FOLDER

ENV CC=$TARGET-gcc \
  CXX=$TARGET-g++ \
  C_INCLUDE_PATH=$TARGET_HOME/include \
  CPLUS_INCLUDE_PATH=$TARGET_HOME/include \
  CFLAGS="-static -static-libstdc++ -static-libgcc -I$TARGET_HOME/include" \
  CXXFLAGS="-static -static-libstdc++ -static-libgcc -I$TARGET_HOME/include" \
  LD=$TARGET-ld \
  LDFLAGS="-L$TARGET_HOME/lib" \
  LD_RUN_PATH=$TARGET_HOME/lib \
  PATH=/usr/local/musl/bin:$PATH \
  # https://wiki.gentoo.org/wiki/Embedded_Handbook/General/Introduction#Environment_variables
  # CBUILD: Platform you are building on
  # CHOST and CTARGET: Platform the cross-built binaries will run on
  CBUILD=x86_64-pc-linux-gnu \
  CHOST=$TARGET \
  CTARGET=$TARGET

# ---- ZLib (necessary to build OpenSSL)

ARG ZLIB_VERSION=1.2.11

RUN export ZLIB_FOLDER=zlib-$ZLIB_VERSION && \
  export ZLIB_SOURCE=$ZLIB_FOLDER.tar.gz && \
  cd /tmp && curl -sqLO https://zlib.net/$ZLIB_SOURCE && \
  tar xzf $ZLIB_SOURCE && rm $ZLIB_SOURCE && \
  cd $ZLIB_FOLDER && \
  ./configure \
    --static \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $ZLIB_FOLDER

ENV Z_STATIC=1 \
  Z_LIB_DIR=$TARGET_HOME/lib

# ---- OpenSSL

ARG OPENSSL_VERSION=1.0.2u \
  OPENSSL_ARCH=linux-x86_64

RUN export OPENSSL_FOLDER=openssl-$OPENSSL_VERSION && \
  export OPENSSL_SOURCE=$OPENSSL_FOLDER.tar.gz && \
  cd /tmp && curl -sqO https://www.openssl.org/source/$OPENSSL_SOURCE && \
  tar xzf $OPENSSL_SOURCE && rm $OPENSSL_SOURCE && \
  cd $OPENSSL_FOLDER && \
  CC="$CC $CFLAGS" ./Configure \
    $OPENSSL_ARCH \
    -static \
    no-shared \
    no-async \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $OPENSSL_FOLDER

ENV OPENSSL_STATIC=1 \
  OPENSSL_DIR=$TARGET_HOME \
  OPENSSL_INCLUDE_DIR=$TARGET_HOME/include \
  DEP_OPENSSL_INCLUDE=$TARGET_HOME/include \
  OPENSSL_LIB_DIR=$TARGET_HOME/lib

# --- clang-sys dependencies (for bindgen of Subtrate dependencies)

ARG LIBFFI_VERSION=3.2.1

RUN $APT_INSTALL texinfo sed

RUN export LIBFFI_FOLDER=libffi-$LIBFFI_VERSION && \
  export LIBFFI_SOURCE=$LIBFFI_FOLDER.tar.gz && \
  cd /tmp && curl -sqO ftp://sourceware.org/pub/libffi/$LIBFFI_SOURCE && \
  tar xzf $LIBFFI_SOURCE && rm $LIBFFI_SOURCE && \
  cd $LIBFFI_FOLDER && \
  # sed command makes the package install headers into $PREFIX/include instead of $PREFIX/lib/libffi-3.2.1/include
  sed -e '/^includesdir/ s/$(libdir).*$/$(includedir)/' -i include/Makefile.in && \
  sed -e '/^includedir/ s/=.*$/=@includedir@/' -e 's/^Cflags: -I${includedir}/Cflags:/' -i libffi.pc.in && \
  ./configure \
    --build=$CBUILD --host=$CHOST --target=$CTARGET \
    --enable-static \
    --disable-shared \
    --prefix=$TARGET_HOME && \
  make && make install && \
  cd .. && rm -rf $LIBFFI_FOLDER

ARG NCURSES_VERSION=6.2-20210828

RUN export NCURSES_FOLDER=ncurses-$NCURSES_VERSION && \
  export NCURSES_SOURCE=$NCURSES_FOLDER.tgz && \
  cd /tmp && curl -sqLO https://invisible-mirror.net/archives/ncurses/current/$NCURSES_SOURCE && \
  tar xzf $NCURSES_SOURCE && rm $NCURSES_SOURCE && \
  cd $NCURSES_FOLDER && \
  ./configure --build=$CBUILD --host=$CHOST \
    --enable-widec \
    --without-develop \
    --without-progs \
    --without-tests \
    --without-cxx \
    --without-dlsym \
    --without-tests \
    --disable-rpath-hack \
    --without-cxx-binding \
    --enable-static --disable-shared \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $NCURSES_FOLDER

# ---- Substrate

RUN rustup target add $TARGET && \
  rustup toolchain install --profile minimal nightly && \
  rustup target add wasm32-unknown-unknown --toolchain nightly

ENV PKG_CONFIG_ALL_STATIC=true \
  PKG_CONFIG_ALLOW_CROSS=true

# Clang needs to be installed for the C++ headers to be available, even though
# the binary itself is not actually used
# https://github.com/rust-rocksdb/rust-rocksdb/issues/174#issuecomment-537326461
RUN $APT_INSTALL pkg-config libclang-dev clang

# use musl-gcc as the linker
# https://github.com/rust-lang/rust/issues/47693#issuecomment-360021149
run echo "[target.$TARGET]\nlinker = \"$CC\"\nrustflags = [\"-Clink-arg=-static\",\"-Clink-arg=-static-libstdc++\",\"-Clink-arg=-static-libgcc\",\"-Clink-arg=-I,$TARGET_HOME/include\",\"-Clink-arg=-Wl,-L,$TARGET_HOME/lib\",\"-Clink-arg=-Wl,-rpath,$TARGET_HOME/lib\"]" > $CARGO_HOME/config

copy . /app

workdir /app

run find / -name '*.a'

run RUST_BACKTRACE=1 \
  WASM_BUILD_NO_COLOR=1 \
  RUSTC_WRAPPER= \
  ROCKSDB_COMPILE=1 \
  SNAPPY_COMPILE=1 \
  LZ4_COMPILE=1 \
  ZSTD_COMPILE=1 \
  BZ2_COMPILE=1 \
  LIBCLANG_STATIC_PATH= \
  cargo build --target $TARGET --release --verbose
