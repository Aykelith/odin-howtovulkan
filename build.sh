#!/usr/bin/env bash
odin build . \
    -debug \
    -extra-linker-flags:"-L$(pwd)/external-libs/SDL -Wl,-rpath,$(pwd)/external-libs/SDL:$(pwd)/external-libs/slang/lib" \
    --collection:shared=./external-libs \
