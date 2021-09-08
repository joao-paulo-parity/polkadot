FROM rust:1.54.0-slim-bullseye

# TODO: checksum verification for all downloaded packages

# ---- Initial definitions

ENV DEBIAN_FRONTEND=noninteractive

ARG APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends"

# https://wiki.gentoo.org/wiki/Embedded_Handbook/General/Introduction#Environment_variables
ARG RUST_TARGET=x86_64-unknown-linux-musl \
  TARGET=x86_64-linux-musl \
  RUST_HOST=x86_64-unknown-linux-gnu \
  HOST=x86_64-linux-gnu


# ---- Rust toolchains

RUN rustup target add $RUST_TARGET && \
  rustup toolchain install --profile minimal nightly && \
  rustup target add wasm32-unknown-unknown --toolchain nightly


# --- Setup for building C/C++ dependencies

RUN apt update && \
  $APT_INSTALL curl unzip cmake make build-essential wget pkg-config && \
  make --version && \
  curl --version && \
  unzip -v && \
  cmake --version && \
  wget --version && \
  pkg-config --version

ENV PKG_CONFIG_ALL_STATIC=true \
  PKG_CONFIG_ALLOW_CROSS=true


# ---- musl

# Default to the same GCC version as the one used by default in musl-cross-make 
# https://github.com/richfelker/musl-cross-make/blob/75e6c618adc9dde2cdcd0522ef40adf75a6bffe7/Makefile#L6
ARG GCC_MAJOR_VERSION=9 \
  GCC_MINOR_VERSION=2.0 \
  CROSS_MAKE_VERSION=0.9.9 \
  MUSL=/usr/local/musl

ENV GCC_VERSION=$GCC_MAJOR_VERSION.$GCC_MINOR_VERSION \
  TARGET_HOME=$MUSL/$TARGET \
  HIJACK_AR=$MUSL/bin/ar \
  HIJACK_AS=$MUSL/bin/as \
  HIJACK_LD=$MUSL/bin/ld \
  HIJACK_STRIP=$MUSL/bin/strip \
  HIJACK_CC=$MUSL/bin/cc \
  HIJACK_CPP=$MUSL/bin/c++ \
  HIJACK_GNUCC=$MUSL/bin/gnu-cc \
  HIJACK_GNUCXX=$MUSL/bin/gnu-cxx

# --enable-default-pie: https://www.openwall.com/lists/musl/2017/12/21/1
#   If you build gcc with --enable-default-pie, musl libc.a will also end up as PIC by default.
# --enable-initfini-array: https://github.com/richfelker/musl-cross-make/commit/3398364d6e3251cd097024182a8cb9f667c23bda
RUN export CROSS_MAKE_FOLDER=musl-cross-make-$CROSS_MAKE_VERSION && \
  export CROSS_MAKE_SOURCE=$CROSS_MAKE_FOLDER.zip && \
  cd /tmp && curl -Lsq https://github.com/richfelker/musl-cross-make/archive/v$CROSS_MAKE_VERSION.zip -o $CROSS_MAKE_SOURCE && \
  unzip -q $CROSS_MAKE_SOURCE && rm $CROSS_MAKE_SOURCE && \
  cd $CROSS_MAKE_FOLDER && \
  echo "OUTPUT = $MUSL\nTARGET = $TARGET\nCOMMON_CONFIG += CFLAGS=\"-g0 -Os\" CXXFLAGS=\"-g0 -Os\" LDFLAGS=\"-s\"\nGCC_CONFIG += --enable-languages=c,c++\nGCC_CONFIG += --enable-default-pie\nGCC_CONFIG += --enable-initfini-array\nGCC_VER=$GCC_VERSION" | tee config.mak && \
  make -j$(nproc) && make install && \
  ln -s $MUSL/bin/$TARGET-ar $HIJACK_AR && \
  ln -s $MUSL/bin/$TARGET-as $HIJACK_AS && \
  ln -s $MUSL/bin/$TARGET-ld $HIJACK_LD && \
  ln -s $MUSL/bin/$TARGET-strip $HIJACK_STRIP && \
  cd .. && rm -rf $CROSS_MAKE_FOLDER


# ---- Compiler setup

RUN $APT_INSTALL git libstdc++-$GCC_MAJOR_VERSION-dev

ENV C_INCLUDE_PATH=$TARGET_HOME/include:$MUSL/lib/gcc/$TARGET/$GCC_VERSION/include

ENV CC_EXE=$MUSL/bin/$TARGET-gcc \
  CXX_EXE=$MUSL/bin/$TARGET-g++ \
  CC=$MUSL/bin/gcc \
  CXX=$MUSL/bin/g++ \
  CPLUS_INCLUDE_PATH=$C_INCLUDE_PATH \
  PATH=$MUSL/bin:$PATH

# since musl-gcc already adds the relevant includes, nostdinc and nostdinc++ are
# used to ensure system-level headers are not looked at.

# rpath-link is used to prioritize the libraries' location at link time

# -fPIC enables Position Independent Code which is a requirement for producing
# static binaries. Since *ALL* objects should be compiled with this flag, we'll
# hijack the compiler binaries here with a custom script which unconditionally
# embeds those flags and filter unwanted ones regardless of what each individual
# application wants, as opposed to e.g. relying on CFLAGS which might be ignored
# by the applications' build scripts.
ENV BASE_CFLAGS="-v -static --static -nostdinc -nostdinc++ -static-libgcc -static-libstdc++ -fPIC -Wl,-M -Wl,-rpath-link,$TARGET_HOME/lib -Wl,--no-dynamic-linker -Wl,-static -L$TARGET_HOME/lib"
ENV BASE_CXXFLAGS="$BASE_CFLAGS -I$TARGET_HOME/include/c++/$GCC_VERSION -I$TARGET_HOME/include/c++/$GCC_VERSION/$TARGET"

copy ./generate_wrapper /generate_wrapper

RUN /generate_wrapper "$CC_EXE $BASE_CFLAGS" > $CC && \
  chmod +x $CC && \
  ln -s $CC $HIJACK_CC && \
  ln -s $CC $HIJACK_GNUCC && \
  /generate_wrapper "$CXX_EXE $BASE_CXXFLAGS" > $CXX && \
  chmod +x $CXX && \
  ln -s $CC $HIJACK_CPP && \
  ln -s $CC $HIJACK_GNUCXX


# ---- ZLib
# used in OpenSSL and RocksDB

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
# used in Substrate

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
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install && \
  cd .. && rm -rf $OPENSSL_FOLDER

ENV OPENSSL_STATIC=1 \
  OPENSSL_DIR=$TARGET_HOME \
  OPENSSL_INCLUDE_DIR=$TARGET_HOME/include \
  DEP_OPENSSL_INCLUDE=$TARGET_HOME/include \
  OPENSSL_LIB_DIR=$TARGET_HOME/lib


# ---- Jemalloc
# used in parity-util-mem

RUN $APT_INSTALL autoconf automake autotools-dev libtool

ARG LIBUNWIND_VERSION=1.6.0-rc2

RUN export LIBUNWIND_FOLDER=libunwind-$LIBUNWIND_VERSION && \
  export LIBUNWIND_SOURCE=$LIBUNWIND_FOLDER.tar.gz && \
  cd /tmp && curl -sqLO https://github.com/libunwind/libunwind/releases/download/v$LIBUNWIND_VERSION/$LIBUNWIND_SOURCE && \
  tar xzf $LIBUNWIND_SOURCE && rm $LIBUNWIND_SOURCE && \
  cd $LIBUNWIND_FOLDER && \
  # revert https://github.com/libunwind/libunwind/commit/f1684379dfaf8018d5d4c1945e292a56d0fab245
  # use -lgcc because we don't have gcc_s.a from musl-cross-make
  # gcc_s is the it's the shared library counterpart of gcc_eh according to https://gitlab.kitware.com/cmake/cmake/-/merge_requests/1460
  sed -e 's/-lgcc_s/-lgcc/' -i configure.ac && \
  autoreconf -i && \
  ./configure \
    --build=$HOST \
    --host=$TARGET \
    --enable-static \
    --disable-shared \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) && make install prefix=$TARGET_HOME && \
  cd .. && rm -rf $LIBUNWIND_FOLDER

ARG JEMALLOC_VERSION=5.2.1

RUN export JEMALLOC_FOLDER=jemalloc-$JEMALLOC_VERSION && \
  export JEMALLOC_SOURCE=$JEMALLOC_FOLDER.tar.bz2 && \
  cd /tmp && curl -sqLO https://github.com/jemalloc/jemalloc/releases/download/$JEMALLOC_VERSION/$JEMALLOC_SOURCE && \
  tar xf $JEMALLOC_SOURCE && rm $JEMALLOC_SOURCE && \
  cd $JEMALLOC_FOLDER && \
  ./configure \
    --build=$HOST \
    --host=$TARGET \
    --with-static-libunwind=$TARGET_HOME/lib/libunwind.a \
    --disable-libdl \
    --disable-initial-exec-tls \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) build_lib_static && \
  make install_lib_static && \
  cd .. && rm -rf $JEMALLOC_FOLDER

ENV JEMALLOC_OVERRIDE=$TARGET_HOME/lib/libjemalloc.a


# ---- RocksDB
# used in Substrate

# only snappy is compiled due to https://github.com/paritytech/parity-common/blob/30a879f4401fa4eac7f4d70be1038d7933e215a1/kvdb-rocksdb/Cargo.toml#L22

# This is the version used for rust-rocksdb v0.17.0
# Should the rust-rocksdb version used by Substrate change, revisit this
ARG SNAPPY_VERSION=1.1.8

RUN export SNAPPY_FOLDER=snappy-$SNAPPY_VERSION && \
  export SNAPPY_SOURCE=$SNAPPY_VERSION.tar.gz && \
  cd /tmp && curl -sqLO https://github.com/google/snappy/archive/refs/tags/$SNAPPY_SOURCE && \
  tar xzf $SNAPPY_SOURCE && rm $SNAPPY_SOURCE && \
  cd $SNAPPY_FOLDER && mkdir build && cd build && \
  cmake \
    -DBUILD_SHARED_LIBS=0 \
    -DBUILD_STATIC_LIBS=1 \
    -DSNAPPY_BUILD_TESTS=0 \
    -DSNAPPY_BUILD_BENCHMARKS=0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$TARGET_HOME \
    .. && \
  make && make install && \
  cd ../.. && rm -rf $SNAPPY_FOLDER

ENV SNAPPY_STATIC=1 \
  SNAPPY_LIB_DIR=$TARGET_HOME/lib

RUN cd /tmp && \
  git clone https://github.com/gflags/gflags.git && \
  cd gflags && mkdir build && cd build && \
  cmake \
    -DBUILD_SHARED_LIBS=0 \
    -DBUILD_STATIC_LIBS=1 \
    -DBUILD_TESTING=0 \
    -DGFLAGS_INSTALL_STATIC_LIBS=1 \
    -DBUILD_gflags_LIB=0 \
    -DCMAKE_INSTALL_PREFIX=$TARGET_HOME \
    .. && \
  make && make install && \
  mv $TARGET_HOME/lib/libgflags_nothreads.a $TARGET_HOME/lib/libgflags.a && \
  cd ../.. && rm -rf gflags

# This is the version used for rust-rocksdb v0.17.0
# Should the rust-rocksdb version used by Substrate change, revisit this
ARG ROCKSDB_VERSION=6.20.3

# We'll opt out of jemalloc and tcmalloc so that we'll have less components to
# worry about (we just want the Polkadot binary to work right now); those
# libraries could be re-enabled later

RUN export ROCKSDB_FOLDER=rocksdb-$ROCKSDB_VERSION && \
  export ROCKSDB_SOURCE=v$ROCKSDB_VERSION.tar.gz && \
  cd /tmp && curl -sqLO https://github.com/facebook/rocksdb/archive/refs/tags/$ROCKSDB_SOURCE && \
  tar xzf $ROCKSDB_SOURCE && rm $ROCKSDB_SOURCE && \
  cd $ROCKSDB_FOLDER && \
  PORTABLE=1 DISABLE_JEMALLOC=1 make static_lib && \
  mv librocksdb.a $TARGET_HOME/lib && \
  mv include/* $TARGET_HOME/include && \
  cd .. && rm -rf $ROCKSDB_FOLDER

ENV ROCKSDB_STATIC=1 \
  ROCKSDB_LIB_DIR=$TARGET_HOME/lib \
  ROCKSDB_INCLUDE_DIR=$TARGET_HOME/include \
  ROCKSDB_DISABLE_JEMALLOC=1 \
  ROCKSDB_DISABLE_TCMALLOC=1


# ---- Polkadot

# unhijack the binaries because we'll not be compiling C directly anymore
RUN mv $CC /target-compiler && \
  rm $CXX $HIJACK_AR $HIJACK_AS $HIJACK_LD $HIJACK_STRIP $HIJACK_CC $HIJACK_CPP $HIJACK_GNUCC $HIJACK_GNUCXX

# link-self-contained=no is used so that the rust compiler does not include the
# build target's c runtime when it's linking the executable, because we'll be
# using musl-cross-make's target c runtime instead, which was already used to
# compile all the libraries above
RUN echo "[target.$RUST_TARGET]\nlinker = \"/target-compiler\"\nrunner = \"target-compiler\"\nrustflags=[\"-C\",\"target-feature=+crt-static\",\"-C\",\"link-self-contained=no\",\"-C\",\"prefer-dynamic=no\",\"-C\",\"relocation-model=pic\"]" > $CARGO_HOME/config

COPY . /app

WORKDIR /app

RUN bash -c "RUST_BACKTRACE=full \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
  BINDGEN_EXTRA_CLANG_ARGS=\"--sysroot=$TARGET_HOME -target $TARGET\" \
  cargo build --target $RUST_TARGET --release --verbose 2>&1 | tee /tmp/log.txt"; \
  if [ -e /app/target/x86_64-unknown-linux-musl/release/polkadot ]; then \
    mv /app/target/x86_64-unknown-linux-musl/release/polkadot /tmp; \
  fi; \
  rm -rf /app/*
