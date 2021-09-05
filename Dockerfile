FROM rust:1.54.0-slim-buster

# TODO: checksum verification for all downloaded packages

ENV DEBIAN_FRONTEND=noninteractive

ARG APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends"

ARG TARGET=x86_64-unknown-linux-musl

# https://wiki.gentoo.org/wiki/Embedded_Handbook/General/Introduction#Environment_variables
# CBUILD: Platform you are building on
# CHOST and CTARGET: Platform the cross-built binaries will run on
ARG CBUILD=x86_64-pc-linux-gnu
ARG CHOST=$CBUILD \
  CTARGET=$CBUILD

# --- Setup for building dependencies

RUN apt update && \
  $APT_INSTALL curl unzip cmake make build-essential wget && \
  make --version && \
  curl --version && \
  unzip -v && \
  cmake --version && \
  wget --version

# ---- musl

ARG CROSS_MAKE_VERSION=0.9.9

RUN export CROSS_MAKE_FOLDER=musl-cross-make-$CROSS_MAKE_VERSION && \
  export CROSS_MAKE_SOURCE=$CROSS_MAKE_FOLDER.zip && \
  cd /tmp && curl -Lsq https://github.com/richfelker/musl-cross-make/archive/v$CROSS_MAKE_VERSION.zip -o $CROSS_MAKE_SOURCE && \
  unzip -q $CROSS_MAKE_SOURCE && rm $CROSS_MAKE_SOURCE && \
  cd $CROSS_MAKE_FOLDER && \
  echo "OUTPUT=/usr/local/musl\nCOMMON_CONFIG += CFLAGS=\"-g0 -Os\" CXXFLAGS=\"-g0 -Os\" LDFLAGS=\"-s\"\nGCC_CONFIG += --enable-languages=c,c++" | tee config.mak && \
  make -j$(nproc) && make install && \
  ln -s /usr/local/musl/bin/$TARGET-strip /usr/local/musl/bin/musl-strip && \
  cd .. && rm -rf $CROSS_MAKE_FOLDER

ENV MUSL=/usr/local/musl \
  GCC_VERSION=9.2.0

ENV TARGET_HOME=$MUSL/$TARGET

ENV C_INCLUDE_PATH=$TARGET_HOME/include:$MUSL/lib/gcc/$TARGET/$GCC_VERSION/include

ENV CC_EXE=$MUSL/bin/$TARGET-gcc \
  CXX_EXE=$MUSL/bin/$TARGET-g++ \
  CC=$MUSL/bin/gcc \
  CXX=$MUSL/bin/g++ \
  CPLUS_INCLUDE_PATH=$C_INCLUDE_PATH \
  PATH=$MUSL/bin:$PATH

# use the compiler driver as a linker; linker-specific flags can be passed
# through -Wl
ENV LD=$CC

# musl compiled with musl-cross-make already adds the relevant includes and
# library paths by default; nostdinc + nostdinc++ should be used to ensure
# _other_ paths are not looked at, though
RUN export CFLAGS="-v -nostartfiles -nostdinc -Bstatic -static -static-libgcc -static-libstdc++ -fPIC -Wl,-M -Wl,-L,$TARGET_HOME/lib -Wl,-rpath,$TARGET_HOME/lib -Wl,--no-dynamic-linker -lstdc++ -lm -lc -lgcc $TARGET_HOME/lib/crt1.o" && \
  echo "#!/bin/sh\n$CC_EXE $CFLAGS \"\$@\"" > $CC && \
  chmod +x $CC && \
  echo "#!/bin/sh\n$CXX_EXE $CFLAGS -nostdinc++ \"\$@\"" > $CXX && \
  chmod +x $CXX

# ---- ZLib
# Necessary to build OpenSSL + also used on Polkadot builds

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
  ./Configure \
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
    --without-ada \
    --without-develop \
    --without-progs \
    --without-tests \
    --without-cxx \
    --without-cxx-binding \
    --without-dlsym \
    --without-tests \
    --disable-rpath-hack \
    --with-build-cc=/usr/bin/gcc \
    --enable-static --disable-shared \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $NCURSES_FOLDER

# ---- Libunwind (for Jemalloc)

RUN $APT_INSTALL autoconf automake autotools-dev libtool

ARG LIBUNWIND_VERSION=1.6.0-rc2

RUN export LIBUNWIND_FOLDER=libunwind-$LIBUNWIND_VERSION && \
  export LIBUNWIND_SOURCE=$LIBUNWIND_FOLDER.tar.gz && \
  echo "https://github.com/libunwind/libunwind/releases/download/v$LIBUNWIND_VERSION/$LIBUNWIND_SOURCE" && \
  cd /tmp && curl -sqLO https://github.com/libunwind/libunwind/releases/download/v$LIBUNWIND_VERSION/$LIBUNWIND_SOURCE && \
  tar xzf $LIBUNWIND_SOURCE && rm $LIBUNWIND_SOURCE && \
  cd $LIBUNWIND_FOLDER && \
  autoreconf -i && \
  ./configure \
    --enable-static \
    --disable-shared \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install prefix=$TARGET_HOME && \
  cd .. && rm -rf $LIBUNWIND_FOLDER

# ---- Jemalloc

ARG JEMALLOC_VERSION=5.2.1

RUN export JEMALLOC_FOLDER=jemalloc-$JEMALLOC_VERSION && \
  export JEMALLOC_SOURCE=$JEMALLOC_FOLDER.tar.bz2 && \
  cd /tmp && curl -sqLO https://github.com/jemalloc/jemalloc/releases/download/$JEMALLOC_VERSION/$JEMALLOC_SOURCE && \
  tar xzf $JEMALLOC_SOURCE && rm $JEMALLOC_SOURCE && \
  cd $JEMALLOC_FOLDER && \
  ./configure \
    --with-static-libunwind=$TARGET_HOME/lunwind.a \
    --disable-libdl \
    --disable-initial-exec-tls \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $JEMALLOC_FOLDER

# ---- Substrate

RUN rustup target add $TARGET && \
  rustup toolchain install --profile minimal nightly && \
  rustup target add wasm32-unknown-unknown --toolchain nightly

ENV PKG_CONFIG_ALL_STATIC=true \
  PKG_CONFIG_ALLOW_CROSS=true

run $APT_INSTALL pkg-config libclang-dev librocksdb-dev && \
  cp -r /usr/include/rocksdb $TARGET_HOME/include

copy . /app

workdir /app

run echo "#!/bin/bash\n$CC_EXE -v -nostartfiles -nostdinc -Bstatic -static -fPIC -Wl,-M -Wl,-L,$TARGET_HOME/lib -Wl,-rpath,$TARGET_HOME/lib -Wl,--no-dynamic-linker -lstdc++ -lm -lc -lgcc \"$@\"" > /app/ld_wrapper && chmod +x /app/ld_wrapper && echo "[target.$TARGET]\nlinker = \"/app/ld_wrapper\"" > $CARGO_HOME/config

run RUST_BACKTRACE=full \
  WASM_BUILD_NO_COLOR=1 \
  RUSTC_WRAPPER= \
  ROCKSDB_COMPILE=1 \
  SNAPPY_COMPILE=1 \
  LZ4_COMPILE=1 \
  ZSTD_COMPILE=1 \
  BZ2_COMPILE=1 \
  cargo build --target $TARGET --release --verbose

run ldd /app/target/x86_64-unknown-linux-musl/release/polkadot
