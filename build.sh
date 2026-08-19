#!/usr/bin/env bash
odin build . \
    -debug \
    -extra-linker-flags:"-L$(pwd)/external-libs/SDL/build -Wl,-rpath,$(pwd)/external-libs/SDL/build:$(pwd)/external-libs/slang/lib" \
    --collection:shared=./external-libs \
