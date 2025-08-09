#!/bin/sh -e
# shellcheck disable=2086,2031,2030

case $JOBS in
    ''|*[!0-9]*)
        if command -v nproc > /dev/null; then
            cpus=$(nproc)
        else
            cpus=$(sysctl -n hw.ncpu 2> /dev/null)
            [ -z "$cpus" ] && cpus=1
        fi

        JOBS=$((cpus * 2 / 3))
        [ "$JOBS" = 0 ] && JOBS=1
        export JOBS
    ;;
esac

if [ -z "$STRIP" ]; then
    if command -v llvm-strip > /dev/null 2>&1; then
        STRIP='llvm-strip'
    elif command -v strip > /dev/null 2>&1; then
        STRIP='strip'
    else
        STRIP='true'
    fi
fi

[ "${0%/*}" = "$0" ] && scriptroot="." || scriptroot="${0%/*}"
scriptroot="$(realpath "$scriptroot")"
pwd="$PWD"

rm -rf "$pwd/minux-toolchain" "$scriptroot/build"
mkdir -p "$pwd/minux-toolchain/share/minux"

cp -a "$scriptroot"/files/* "$pwd/minux-toolchain"

host="$(cc -dumpmachine)"

(
mkdir "$scriptroot/build" && cd "$scriptroot/build"

printf "Building LLVM+Clang\n\n"
llvmver="20.1.8"
curl -# -L "https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-$llvmver.tar.gz" | tar -xz
mkdir "llvm-project-llvmorg-$llvmver/build"
(
cd "llvm-project-llvmorg-$llvmver"
cd build
export PATH="$scriptroot/src/llvmbin:$PATH"
command -v clang >/dev/null && command -v clang++ >/dev/null && cmakecc='-DCMAKE_C_COMPILER=clang' && cmakecpp='-DCMAKE_CXX_COMPILER=clang++' && lto='Thin'
[ "$(uname -s)" != "Darwin" ] && command -v ld.lld >/dev/null && lld=ON

llvm_components() {
    for component in \
    LLVM \
    clang \
    clang-resource-headers \
    llvm-addr2line \
    llvm-objcopy \
    llvm-objdump \
    llvm-cxxfilt \
    llvm-nm \
    llvm-readelf \
    llvm-size \
    llvm-strip \
    llvm-strings \
    llvm-ar \
    llvm-ranlib \
    lld \
    ; do
        printf '%s;' "$component"
    done
}

# for LLVM_TARGETS_TO_BUILD we must support the target and build system, but there's
# no way I know of to detect the host arch here easily, so we just assume X86.
# But if your build system was Aarch64 you would replace X86 with that there.
cmake -GNinja ../llvm \
    -DCMAKE_BUILD_TYPE=Release \
    $cmakecc \
    $cmakecpp \
    -DLLVM_ENABLE_LLD="${lld:-OFF}" \
    -DLLVM_ENABLE_LTO="${lto:-OFF}" \
    -DCMAKE_INSTALL_PREFIX="$pwd/minux-toolchain/share/minux" \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=OFF \
    -DLLVM_ENABLE_PROJECTS='clang;lld' \
    -DLLVM_DISTRIBUTION_COMPONENTS="$(llvm_components)" \
    -DLLVM_TARGETS_TO_BUILD='X86;RISCV' \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$host"
ninja -j"$JOBS" install-distribution
)
)

(
cd "$pwd/minux-toolchain/share/minux"
curl -L -# https://github.com/North-Western-Development/minux/releases/download/0.0.57/sysroot.tar.xz | tar -xJ
rm -rf include
for bin in bin/* lib/*; do
    if [ ! -h "$bin" ] && [ -f "$bin" ]; then
        "$STRIP" "$bin"
    fi
done
for binutil in addr2line ar nm objcopy objdump ranlib readelf size strings strip; do
    ln -s "../bin/llvm-$binutil" "cctools-bin/$binutil"
done
ln -s ../bin/ld.lld cctools-bin/ld
ln -s ../bin/llvm-cxxfilt cctools-bin/c++filt
for cc in c++ gcc g++ clang clang++; do
    ln -s cc "cctools-bin/$cc"
done
mkdir ../../bin
cd ../../bin
for cctool in ../share/minux/cctools-bin/*; do
    ln -s "$cctool" "riscv64-linux-musl-${cctool##*/}"
done
)
