#!/usr/bin/env bash
# 分阶段构建 CUSA02716（假面骑士 穿越战争 创生）的 Android 运行时 APK。
# 用法: bash ci/build.sh [headers|deps|bionic|apk|all]
# 每个阶段独立可跑，便于在 CI 里逐段定位失败点。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 定位上游源码树：CI 里本仓库被检出到 ci/，上游树在旁边 src-tree/；
# 本地把脚本放进上游树里跑时，ROOT 本身就是源码树。
SRC=${BB_SRC:-}
if [[ -z $SRC ]]; then
    if [[ -d $ROOT/../src-tree ]]; then
        SRC=$(cd "$ROOT/../src-tree" && pwd)
    elif [[ -d $ROOT/src-tree ]]; then
        SRC=$ROOT/src-tree
    else
        SRC=$ROOT
    fi
fi
cd "$SRC"

STAGE=${1:-all}
SDK=${BB_ANDROID_SDK:-/usr/local/lib/android/sdk}
NDK_VER=${BB_NDK_VER:-29.0.14206865}

# NDK 查找顺序：显式指定 > 系统 SDK 下的目标版本 > 仓库内 .local-deps > 系统里任意版本
NDK=${BB_NDK:-}
if [[ -z $NDK ]]; then
    for cand in "$SDK/ndk/$NDK_VER" "$PWD/.local-deps/android/sdk/ndk/$NDK_VER"; do
        [[ -f $cand/build/cmake/android.toolchain.cmake ]] && { NDK=$cand; break; }
    done
fi
if [[ -z $NDK ]]; then
    NDK=$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)
    [[ -n $NDK ]] && echo "警告: 未找到 NDK $NDK_VER，回落到 $NDK"
fi

export BB_JOBS=${BB_JOBS:-$(nproc)}
export BB_NDK=$NDK
export BB_ANDROID_SDK=$SDK
export BB_ANDROID_API=${BB_ANDROID_API:-30}
# 8 Gen 3 走系统 Vulkan 驱动，不把 Turnip/PanVK 打进包（省下载与体积）
export BB_SKIP_DRIVERS=${BB_SKIP_DRIVERS:-1}
export BB_APK_NAME=${BB_APK_NAME:-BBPort-CUSA02716}

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# install_header_pkg <源码目录> <cmake 额外参数...>
# 把 header-only 包装进 /usr/local，让 NDK toolchain 下的 find_package 能找到。
install_header_pkg() {
    local src=$1; shift
    local bld
    bld=$(mktemp -d)
    cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release "$@" >/dev/null
    sudo cmake --install "$bld" >/dev/null
    rm -rf "$bld"
}

step_headers() {
    log "stage: host header-only packages"
    local tmp
    tmp=$(mktemp -d)
    # Vulkan-Headers：VMA 的 cmake config 依赖它
    curl -fsSL "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.363.tar.gz" \
        | tar xz -C "$tmp"
    install_header_pkg "$tmp/Vulkan-Headers-1.4.363" \
        -DVULKAN_HEADERS_ENABLE_TESTS=OFF -DVULKAN_HEADERS_ENABLE_MODULE=OFF
    # magic_enum
    curl -fsSL "https://github.com/Neargye/magic_enum/archive/refs/tags/v0.9.7.tar.gz" | tar xz -C "$tmp"
    install_header_pkg "$tmp/magic_enum-0.9.7" -DMAGIC_ENUM_OPT_BUILD_TESTS=OFF -DMAGIC_ENUM_OPT_BUILD_EXAMPLES=OFF
    # tsl-robin-map
    curl -fsSL "https://github.com/Tessil/robin-map/archive/refs/tags/v1.3.0.tar.gz" | tar xz -C "$tmp"
    install_header_pkg "$tmp/robin-map-1.3.0" -DTSL_ROBIN_MAP_INSTALL=ON
    # VulkanMemoryAllocator
    curl -fsSL "https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/archive/refs/tags/v3.1.0.tar.gz" \
        | tar xz -C "$tmp"
    install_header_pkg "$tmp/VulkanMemoryAllocator-3.1.0" -DVMA_BUILD_SAMPLES=OFF -DVMA_BUILD_DOCUMENTATION=OFF
    rm -rf "$tmp"
    log "headers installed to /usr/local"
}

step_deps() {
    log "stage: bionic third-party deps (ffmpeg / openssl / protobuf / SDL3 ...)"
    bash tools/android/build_bionic_deps.sh
}

step_bionic() {
    log "stage: bionic runtime (libbbcpu / libbbgpu / bb-probe / bb-prepare)"
    [[ -f $NDK/build/cmake/android.toolchain.cmake ]] || die "NDK 缺失: $NDK"

    # gpu 里用的是 header-only 的 Boost（定义 BOOST_ASIO_STANDALONE），但 CMake 交叉编译时
    # 只把 $prefix/include 和 /usr/local/include 放进 include 路径，host 的 /usr/include 进不来，
    # 于是 boost/asio/*.hpp 找不到。把系统 Boost 头挂到 bionic 前缀下，走已有的 -isystem。
    local prefix=$PWD/.local-deps/android/bionic-prefix
    if [[ ! -e $prefix/include/boost ]]; then
        [[ -d /usr/include/boost ]] || die "系统缺 Boost 头（apt install libboost-dev）"
        mkdir -p "$prefix/include"
        ln -sfn /usr/include/boost "$prefix/include/boost"
        log "Boost headers linked: $prefix/include/boost -> /usr/include/boost"
    fi

    # boost 的 asio 修复已移到 gpu/CMakeLists.txt（target_compile_options），环境变量在这里不生效。

    # ps4-pkg-tool：build_bionic.sh 的最后一步要它（app 的 PKG 安装器会调用），但它不在上游树里，
    # 源头是外部仓库 xXJSONDeruloXx/ps4-pkg-tools @ 45baeda，且 externals/cryptopp 是 submodule。
    local pkgtool=$PWD/.local-deps/src/ps4-pkg-tools
    if [[ ! -f $pkgtool/externals/cryptopp/cryptlib.h ]]; then
        rm -rf "$pkgtool"
        mkdir -p "$(dirname "$pkgtool")"
        git clone --filter=blob:none https://github.com/xXJSONDeruloXx/ps4-pkg-tools "$pkgtool"
        git -C "$pkgtool" checkout -q 45baedaa29b8da42b3c6fe912800d2fa4119834b
        git -C "$pkgtool" submodule update --init --recursive
        log "ps4-pkg-tools ready at $pkgtool"
    fi
    export BB_PKG_TOOL_SRC=$pkgtool

    bash tools/android/build_bionic.sh
}

step_apk() {
    log "stage: release APK"
    bash tools/android/build_release_apk.sh
}

case "$STAGE" in
    headers) step_headers ;;
    deps)    step_deps ;;
    bionic)  step_bionic ;;
    apk)     step_apk ;;
    all)     step_headers; step_deps; step_bionic; step_apk ;;
    *)       die "未知阶段: $STAGE（可用: headers|deps|bionic|apk|all）" ;;
esac

log "stage '$STAGE' done"
ls -la out/release/*.apk 2>/dev/null || true
