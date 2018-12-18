#!/bin/bash

if [ ! -f server ]; then
  echo "building libreactor..."

  INSDIR=$PWD/install
  mkdir $INSDIR

  INCLUDEDIR=$INSDIR/include
  LIBDIR=$INSDIR/lib

  wget -q https://github.com/fredrikwidlund/libdynamic/releases/download/v1.1.0/libdynamic-1.1.0.tar.gz
  tar xfz libdynamic-1.1.0.tar.gz
  cd libdynamic-1.1.0
  ./configure --prefix=$INSDIR
  make
  make install
  cd ..

  wget -q https://github.com/fredrikwidlund/libreactor/releases/download/v1.0.0/libreactor-1.0.0.tar.gz
  tar xfz libreactor-1.0.0.tar.gz
  cd libreactor-1.0.0
  cat ../src/patch.c >> src/reactor/reactor_core.c
  ./configure --prefix=$INSDIR CFLAGS="-I"$INCLUDEDIR LDFLAGS="-L"$LIBDIR
  make
  make install
  cd ..

  wget -q https://github.com/fredrikwidlund/libclo/releases/download/v0.1.0/libclo-0.1.0.tar.gz
  tar xfz libclo-0.1.0.tar.gz
  cd libclo-0.1.0
  ./configure --prefix=$INSDIR CFLAGS="-I"$INCLUDEDIR LDFLAGS="-L"$LIBDIR
  make
  make install
  cd ..

  make clean
  LIBDIR=$LIBDIR INCLUDEDIR=$INCLUDEDIR make -f plaintext.make

fi
