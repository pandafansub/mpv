#!/bin/bash
# Builds a single mpv.exe that depends on no DLLs other than the ones that
# come with Windows. Run it from an MSYS2 UCRT64 shell in the mpv source
# directory:
#
#   TOOLS/win-static-build.sh [deps|fetch|ffmpeg|libplacebo|mpv|all]
#
#   deps        install the MSYS2 packages needed for the build
#   fetch       download the FFmpeg and libplacebo sources
#   ffmpeg      build FFmpeg
#   libplacebo  build libplacebo
#   mpv         build mpv and check the result
#   all         all of the above except deps (the default)
#
# Everything is built in build-static/ (or $STATIC_BUILD_DIR), and the result
# is build-static/mpv/mpv.exe.
#
# FFmpeg and libplacebo are built from source because the MSYS2 packages
# depend on libraries that only exist as DLLs (whisper/ggml, vulkan-1).
# Everything else comes from the static libraries of the MSYS2 packages.
# Features without static libraries are disabled: Vulkan (D3D11 is used),
# libarchive (opening media inside archives) and subrandr.
set -e

if [ "$MSYSTEM" != "UCRT64" ]; then
    echo "Run this from an MSYS2 UCRT64 shell." >&2
    exit 1
fi

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${STATIC_BUILD_DIR:-$SRC/build-static}
PREFIX=$WORK/prefix
JOBS=$(nproc)
step=${1:-all}

# Versions the build was tested with; override to use others.
FFMPEG_URL=${FFMPEG_URL:-https://github.com/FFmpeg/FFmpeg.git}
FFMPEG_REF=${FFMPEG_REF:-d97584959417519597a24c8fdd13dc4b9af1a876}
LIBPLACEBO_URL=${LIBPLACEBO_URL:-https://github.com/haasn/libplacebo.git}
LIBPLACEBO_REF=${LIBPLACEBO_REF:-c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56}

UCRT=$(cygpath -m "$MINGW_PREFIX")

# meson's cmake dependency lookups fail without a home directory.
export USERPROFILE=${USERPROFILE:-C:/Users/$(whoami)}
export HOME=$(cygpath -m "$USERPROFILE")

# The MSYS2 .pc files of these point at the DLL versions; use the static
# archives instead. MSYS2's shaderc_combined doesn't actually contain glslang
# and SPIRV-Tools, so add them.
write_pc_overrides() {
    mkdir -p "$WORK/pc-override"
    local shaderc_libs="-L$UCRT/lib -lshaderc_combined -lglslang -lglslang-default-resource-limits -lSPIRV -lSPIRV-Tools-opt -lSPIRV-Tools -lstdc++"
    for name in shaderc shaderc_combined; do
        cat > "$WORK/pc-override/$name.pc" <<EOF
Name: $name
Description: shaderc (static, combined)
Version: $(pkgconf --modversion shaderc 2>/dev/null || echo 2023.1)
Libs: $shaderc_libs
Cflags: -I$UCRT/include
EOF
    done
    cat > "$WORK/pc-override/spirv-cross-c-shared.pc" <<EOF
Name: spirv-cross-c-shared
Description: SPIRV-Cross C API (static)
Version: $(pkgconf --modversion spirv-cross-c 2>/dev/null || echo 0.64.0)
Libs: -L$UCRT/lib -lspirv-cross-c -lspirv-cross-glsl -lspirv-cross-hlsl -lspirv-cross-msl -lspirv-cross-cpp -lspirv-cross-reflect -lspirv-cross-util -lspirv-cross-core -lstdc++
Cflags: -I$UCRT/include/spirv_cross
EOF
}

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$WORK/pc-override:$MINGW_PREFIX/lib/pkgconfig"

install_deps() {
    local p=$MINGW_PACKAGE_PREFIX
    pacman -S --needed --noconfirm git make \
        $p-gcc $p-meson $p-ninja $p-pkgconf $p-nasm $p-python \
        $p-libass $p-luajit $p-libjpeg-turbo $p-uchardet $p-zimg \
        $p-rubberband $p-lcms2 $p-libdovi $p-dav1d $p-curl \
        $p-shaderc $p-spirv-cross $p-vulkan-headers \
        $p-zlib $p-bzip2 $p-xz $p-libiconv
}

# Clones url at a specific commit into dir, unless it's already there.
fetch_repo() {
    local url=$1 ref=$2 dir=$3
    if [ ! -d "$dir/.git" ]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    if [ "$(git -C "$dir" rev-parse -q --verify HEAD)" != "$ref" ]; then
        git -C "$dir" fetch -q --depth 1 origin "$ref"
        git -C "$dir" checkout -q FETCH_HEAD
    fi
    git -C "$dir" submodule -q update --init --depth 1
}

fetch_sources() {
    mkdir -p "$WORK/src"
    fetch_repo "$FFMPEG_URL" "$FFMPEG_REF" "$WORK/src/ffmpeg"
    fetch_repo "$LIBPLACEBO_URL" "$LIBPLACEBO_REF" "$WORK/src/libplacebo"
}

build_ffmpeg() {
    cd "$WORK/src/ffmpeg"
    ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-programs --disable-doc --disable-debug \
        --pkg-config-flags=--static \
        --disable-autodetect \
        --enable-zlib --enable-bzlib --enable-lzma --enable-iconv \
        --enable-schannel \
        --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-w32threads \
        --enable-mediafoundation \
        --enable-libdav1d
    make -j"$JOBS"
    make install
}

build_libplacebo() {
    write_pc_overrides
    cd "$WORK/src/libplacebo"
    rm -rf build
    meson setup build --prefix="$PREFIX" --buildtype=release \
        --default-library=static --prefer-static \
        -Dvulkan=disabled -Dd3d11=enabled -Dopengl=enabled \
        -Dshaderc=enabled -Dglslang=disabled \
        -Dlcms=enabled -Ddovi=enabled -Dlibdovi=enabled \
        -Dunwind=disabled -Dxxhash=disabled \
        -Ddemos=false -Dtests=false
    meson compile -C build
    meson install -C build
}

# Fails if mpv.exe imports DLLs that don't come with Windows.
check_imports() {
    local others
    others=$(objdump -p "$1" | sed -n 's/^\s*DLL Name: //p' | grep -viE \
        '^(api-ms-win-.*|kernel32|user32|gdi32|advapi32|shell32|ole32|oleaut32|opengl32|ws2_32|crypt32|secur32|bcrypt|bcryptprimitives|ncrypt|ntdll|dwmapi|uxtheme|version|shlwapi|shcore|imm32|iphlpapi|rpcrt4|userenv|usp10|wldap32|avicap32|avrt|dwrite)\.dll$' || true)
    if [ -n "$others" ]; then
        echo "$1 depends on non-system DLLs:" >&2
        echo "$others" >&2
        return 1
    fi
    echo "$1 only depends on Windows system DLLs."
}

build_mpv() {
    write_pc_overrides
    cd "$SRC"
    rm -rf "$WORK/mpv"
    meson setup "$WORK/mpv" --buildtype=release \
        --prefer-static --default-library=static \
        -Dlua=luajit -Dlibmpv=false -Dvulkan=disabled \
        -Dsubrandr=disabled -Dlibarchive=disabled \
        -Dc_link_args=-static -Dcpp_link_args=-static
    meson compile -C "$WORK/mpv"
    strip "$WORK/mpv/mpv.exe"
    check_imports "$WORK/mpv/mpv.exe"
}

case $step in
    deps) install_deps ;;
    fetch) fetch_sources ;;
    ffmpeg) build_ffmpeg ;;
    libplacebo) build_libplacebo ;;
    mpv) build_mpv ;;
    all) fetch_sources; build_ffmpeg; build_libplacebo; build_mpv ;;
    *) echo "Unknown step: $step" >&2; exit 1 ;;
esac
