FROM rust:1.54.0-slim-bullseye

# TODO: checksum verification for all downloaded packages

# ---- Initial definitions

ENV DEBIAN_FRONTEND=noninteractive

ARG APT_INSTALL="apt install --assume-yes --quiet --no-install-recommends"

# https://wiki.gentoo.org/wiki/Embedded_Handbook/General/Introduction#Environment_variables
ARG TARGET=x86_64-unknown-linux-musl
ARG HOST=x86_64-pc-linux-gnu


# ---- Rust toolchains for Substrate

RUN rustup target add $TARGET && \
  rustup toolchain install --profile minimal nightly && \
  rustup target add wasm32-unknown-unknown --toolchain nightly


# --- Setup for building dependencies

RUN apt update && \
  $APT_INSTALL curl unzip cmake make build-essential wget && \
  make --version && \
  curl --version && \
  unzip -v && \
  cmake --version && \
  wget --version


# ---- musl

# A sane approach for settling on the GCC version is to read the source for the
# musl-cross-make version you're targetting and set the GCC version here. For
# instance, version 0.9.9 of musl-cross-make used GCC 9.2.0:
# https://github.com/richfelker/musl-cross-make/blob/75e6c618adc9dde2cdcd0522ef40adf75a6bffe7/Makefile#L6
ARG GCC_MAJOR_VERSION=9
ARG GCC_VERSION=$GCC_MAJOR_VERSION.2.0
ARG CROSS_MAKE_VERSION=0.9.9
ENV MUSL=/usr/local/musl
ENV TARGET_HOME=$MUSL/$TARGET

RUN export CROSS_MAKE_FOLDER=musl-cross-make-$CROSS_MAKE_VERSION && \
  export CROSS_MAKE_SOURCE=$CROSS_MAKE_FOLDER.zip && \
  cd /tmp && curl -Lsq https://github.com/richfelker/musl-cross-make/archive/v$CROSS_MAKE_VERSION.zip -o $CROSS_MAKE_SOURCE && \
  unzip -q $CROSS_MAKE_SOURCE && rm $CROSS_MAKE_SOURCE && \
  cd $CROSS_MAKE_FOLDER && \
  echo "OUTPUT=$MUSL\nTARGET = $TARGET\nCOMMON_CONFIG += CFLAGS=\"-g0 -Os\" CXXFLAGS=\"-g0 -Os\" LDFLAGS=\"-s\"\nGCC_CONFIG += --enable-languages=c,c++\nGCC_VER=$GCC_VERSION" | tee config.mak && \
  make -j$(nproc) && make install && \
  ln -s /usr/local/musl/bin/$TARGET-strip /usr/local/musl/bin/musl-strip && \
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

# use the compiler front-end as a linker, as recommended by musl; linker-only
# flags can be passed through -Wl
ENV LD=$CC

# the GCC/G++ binaries from musl-cross-make already adds the relevant includes
# and library paths to the arguments by default; since we're compiling for a
# foreign target, nostdinc and nostdinc++ are used to ensure system-level
# headers are not looked at.

# rpath-link is used to prioritize the libraries' location at link time

# -fPIC enables Position Independent Code which is a requirement for producing
# static binaries. Since *ALL* objects should be compiled with this flag, we'll
# hijack the compilar binaries here with a custom script which unconditionally
# embeds those flags regardless of what each individual application wants, as
# opposed to e.g. relying on CFLAGS which might be ignored by the applications'
# build scripts.
ENV BASE_CFLAGS="-v -static --static -nostdinc -static-libgcc -static-libstdc++ -fPIC -Wl,-M -Wl,-rpath-link,$TARGET_HOME/lib -Wl,--no-dynamic-linker"
ENV BASE_CXXFLAGS="$BASE_CFLAGS -I$TARGET_HOME/include/c++/$GCC_VERSION -I$TARGET_HOME/include/c++/$GCC_VERSION/$TARGET -nostdinc++"

copy ./generate_wrapper /generate_wrapper

RUN /generate_wrapper "$CC_EXE $BASE_CFLAGS" > $CC && \
  chmod +x $CC && \
  /generate_wrapper "$CXX_EXE $BASE_CXXFLAGS" > $CXX && \
  chmod +x $CXX

# ---- ZLib
# Necessary to build OpenSSL and RocksDB

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
# Necessary to build Substrate

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


# --- clang-sys dependencies
# For bindgen of Subtrate dependencies

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
    --build=$HOST --host=$TARGET --target=$TARGET \
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
  ./configure --build=$TARGET --host=$TARGET \
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
  # use -lgcc because we don't have "gcc_s" here
  # gcc_s is the it's the shared library counterpart of gcc_eh according to:
  # https://gitlab.kitware.com/cmake/cmake/-/merge_requests/1460)
  sed -e 's/-lgcc_s/-lgcc/' -i configure.ac && \
  autoreconf -i && \
  ./configure \
    --build="$HOST" \
    --host="$TARGET" \
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
    --build="$HOST" \
    --host="$TARGET" \
    --with-static-libunwind=$TARGET_HOME/lib/libunwind.a \
    --disable-libdl \
    --disable-initial-exec-tls \
    --prefix=$TARGET_HOME && \
  make -j$(nproc) build_lib_static && \
  make install_lib_static && \
  cd .. && rm -rf $JEMALLOC_FOLDER

ENV JEMALLOC_OVERRIDE=$TARGET_HOME/lib/libjemalloc.a


# ---- RocksDB
# Used for the database of Substrate-based chains

RUN cd /tmp && \
  git clone https://github.com/gflags/gflags.git && \
  cd gflags && \
  mkdir build && \
  cd build && \
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
  cd /tmp && rm -R /tmp/gflags

# This is the version used for rust-rocksdb v0.17.0
# https://github.com/rust-rocksdb/rust-rocksdb/tree/v0.17.0/librocksdb-sys
# Should the rust-rocksdb version used by Substrate change, this also needs to
# be changed
ARG ROCKSDB_VERSION=6.20.3

RUN export ROCKSDB_FOLDER=rocksdb-$ROCKSDB_VERSION && \
  export ROCKSDB_SOURCE=v$ROCKSDB_VERSION.tar.gz && \
  cd /tmp && curl -sqLO https://github.com/facebook/rocksdb/archive/refs/tags/$ROCKSDB_SOURCE && \
  tar xzf $ROCKSDB_SOURCE && rm $ROCKSDB_SOURCE && \
  ls && \
  cd $ROCKSDB_FOLDER && \
  PORTABLE=1 DISABLE_JEMALLOC=1 make static_lib && \
  mv librocksdb.a $TARGET_HOME/lib && \
  mv include/* $TARGET_HOME/include && \
  cd /tmp && rm -rf /tmp/rocksdb

ENV ROCKSDB_STATIC=1 \
  ROCKSDB_LIB_DIR=$TARGET_HOME/lib \
  ROCKSDB_INCLUDE_DIR=$TARGET_HOME/include \
  ROCKSDB_DISABLE_JEMALLOC=1 \
  ROCKSDB_DISABLE_TCMALLOC=1


# ---- Substrate

ENV PKG_CONFIG_ALL_STATIC=true \
  PKG_CONFIG_ALLOW_CROSS=true

run $APT_INSTALL pkg-config libclang-dev

copy . /app

workdir /app

# -lrocksdb has to be added manually because the symbols are not added in the
# compiler options by librocksdb-sys, apparently
RUN /generate_wrapper "$CC_EXE $BASE_CFLAGS -lrocksdb" > $CC && \
  /generate_wrapper "$CXX_EXE $BASE_CXXFLAGS -lrocksdb" > $CXX && \
  echo "[target.$TARGET]\nlinker = \"$CC\"" > $CARGO_HOME/config

# For compile-time-only build tools, preserve this host's original compilers
# since they are not included in the binary we'll compile
ENV CC_x86_64_unknown_linux_gnu=/usr/bin/gcc \
  CXX_x86_64_unknown_linux_gnu=/usr/bin/g++ \
  LD_x86_64_unknown_linux_gnu=/usr/bin/ld \
  AR_x86_64_unknown_linux_gnu=/usr/bin/ar

run bash -c "RUST_BACKTRACE=full \
  RUSTC_WRAPPER= \
  WASM_BUILD_NO_COLOR=1 \
  SNAPPY_COMPILE=1 \
  LZ4_COMPILE=1 \
  ZSTD_COMPILE=1 \
  BZ2_COMPILE=1 \
  cargo build --target $TARGET --release --verbose 2>&1 | tee /tmp/log.txt"; \
  if [ -e /app/target/x86_64-unknown-linux-musl/release/polkadot ]; then \
    mv /app/target/x86_64-unknown-linux-musl/release/polkadot /tmp; \
  fi; \
  rm -rf /app/*
