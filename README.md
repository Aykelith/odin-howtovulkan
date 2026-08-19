# howtovulkan.com Odin implementation

This repository contains a working implementation in Odin of the
[howtovulkan.com](https://www.howtovulkan.com) tutorial.

This repository is aimed at Linux developers, but I think it can be easily
adjusted for Windows/Mac users.

The repository contains the following packages/repositories as git submodules:

- [SDL](https://github.com/libsdl-org/SDL);
- [odin-vma](https://github.com/Capati/odin-vma);
- [tinyobj](https://github.com/algo-boyz/tinyobj);
- [ktx_odin](https://github.com/nowhereware/ktx_odin);
- [KTX-Software](https://github.com/KhronosGroup/KTX-Software) - required if not on Windows because `ktx_odin` doesn't ship with built KTX for Linux and MacOSX;
- [odin-slang](https://github.com/DragosPopse/odin-slang).

## Init

### Get submodules

In order to get all the submodules:

```sh
git submodule update --init --recursive
```

### Odin-slang

Because `odin-slang` repository has the Odin package at a subdirectory, `slang`,
we need to symlink it to `external-libs`:

```sh
ln -s $(pwd)/external-libs/odin-slang/slang external-libs/slang
```

> Alternative would be to add an extra `--collection` at build.

### Build SDL

We need to build SDL:

```sh
cd external-libs/SDL
mkdir build && cd build
cmake .. -DBUILD_SHARED_LIBS=OFF
cmake --build . -j$(nproc)
```

### Build and patch odin-ktx if not on Windows

`odin-ktx` doesn't ship with built KTX on Linux and MacOSX so we need to built it ourself:

```sh
cd external-libs/KTX-Software
mkdir build && cd build
cmake .. -DKTX_FEATURE_TESTS=OFF -DKTX_FEATURE_TOOLS=OFF -DKTX_FEATURE_DOC=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build .
```

> Don't use multithreading for building, it will not work!

Then copy it to `odin-ktx`:

```
cp lib/libktx.a ../../ktx_odin/
```

Because of some missing files in `odin-ktx` library it will not load the KTX library.

Edit `external-libs/ktx_odin/ktx.odin` and instead of lines 6-7 where is it:

```odin
@(export)
foreign import lib "ktx.lib"
```

Replace with:

```odin
when ODIN_OS == .Windows {
    @(export)
	foreign import lib "ktx.lib"
} else when ODIN_OS == .Linux {
    @(export)
	foreign import lib "libktx.a"
} else when ODIN_OS == .Darwin {
    @(export)
	foreign import lib "libktx.a"
}
```

## Build

In order to build run:

```sh
odin build . \
    -debug \
    -extra-linker-flags:"-L$(pwd)/external-libs/SDL/build -Wl,-rpath,$(pwd)/external-libs/SDL/build:$(pwd)/external-libs/slang/lib" \
    --collection:shared=./external-libs \
```

> Or run `build.sh`.

And check if all the libraries were linked using:

```sh
ldd <executable>
```

## Random things

- I needed to edit `assets/suzanne.obj` line 3 to give the full relative to binary path for MTL file.
