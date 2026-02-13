#!/usr/bin/env bash
set -euo pipefail

# IPCams FFmpeg build script
# - Builds only what this project uses (avformat/avcodec/avutil)
# - Video decode is done by VideoToolbox, so swscale/swresample are not required

FFMPEG_VERSION="${1:-7.1.1}"
IOS_MIN="${IOS_MIN:-16.0}"
MACOS_MIN="${MACOS_MIN:-13.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/.ffmpeg-build"
SOURCE_DIR="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}"
OUTPUT_ROOT="${REPO_ROOT}/ffmpeg-artifacts/${FFMPEG_VERSION}"
THIN_DIR="${OUTPUT_ROOT}/thin"
FAT_DIR="${OUTPUT_ROOT}/fat"
XCFRAMEWORK_DIR="${OUTPUT_ROOT}/xcframeworks"

mkdir -p "${BUILD_ROOT}" "${THIN_DIR}" "${FAT_DIR}" "${XCFRAMEWORK_DIR}"

download_ffmpeg_source() {
    if [[ -d "${SOURCE_DIR}" ]]; then
        return
    fi

    pushd "${BUILD_ROOT}" >/dev/null

    local xz_archive="ffmpeg-${FFMPEG_VERSION}.tar.xz"
    local bz2_archive="ffmpeg-${FFMPEG_VERSION}.tar.bz2"

    if curl -fL -o "${xz_archive}" "https://ffmpeg.org/releases/${xz_archive}"; then
        tar -xf "${xz_archive}"
    else
        echo "xz archive not found, trying bz2..."
        curl -fL -o "${bz2_archive}" "https://ffmpeg.org/releases/${bz2_archive}"
        tar -xjf "${bz2_archive}"
    fi

    popd >/dev/null
}

COMMON_FLAGS=(
    --disable-everything
    --disable-autodetect
    --disable-debug
    --disable-doc
    --disable-programs
    --disable-avdevice
    --disable-avfilter
    --disable-postproc
    --disable-swscale
    --disable-swresample
    --disable-iconv
    --enable-static
    --disable-shared
    --enable-avcodec
    --enable-avformat
    --enable-avutil
    --enable-network
    --enable-protocol=file,rtp,rtsp,tcp,udp
    --enable-demuxer=rtsp,rtp,sdp,mov,mpegts
    --enable-parser=h264,hevc,aac
    --enable-decoder=aac,pcm_alaw,pcm_mulaw,adpcm_g726,adpcm_g726le
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc
    --enable-cross-compile
    --enable-pic
    --target-os=darwin
    --pkg-config-flags=--static
)

build_arch() {
    local arch="$1"
    local sdk="$2"

    echo "==> Building ${sdk}/${arch}"

    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"

    local target_flags
    if [[ "${sdk}" == "macosx" ]]; then
        target_flags="-arch ${arch} -isysroot ${sdk_path} -mmacosx-version-min=${MACOS_MIN}"
    elif [[ "${sdk}" == "iphonesimulator" ]]; then
        target_flags="-arch ${arch} -isysroot ${sdk_path} -mios-simulator-version-min=${IOS_MIN}"
    else
        target_flags="-arch ${arch} -isysroot ${sdk_path} -miphoneos-version-min=${IOS_MIN}"
    fi

    local prefix="${THIN_DIR}/${sdk}/${arch}"
    mkdir -p "${prefix}"

    pushd "${SOURCE_DIR}" >/dev/null
    make distclean >/dev/null 2>&1 || true

    ./configure \
        "${COMMON_FLAGS[@]}" \
        --arch="${arch}" \
        --cc="$(xcrun --sdk "${sdk}" -f clang)" \
        --cxx="$(xcrun --sdk "${sdk}" -f clang++)" \
        --sysroot="${sdk_path}" \
        --extra-cflags="${target_flags}" \
        --extra-ldflags="${target_flags}" \
        --prefix="${prefix}"

    make -j"$(sysctl -n hw.logicalcpu)"
    make install
    popd >/dev/null
}

create_xcframeworks() {
    echo "==> Merging static libraries"
    mkdir -p "${FAT_DIR}/ios" "${FAT_DIR}/simulator" "${FAT_DIR}/macos"

    local libs=(libavcodec libavformat libavutil)
    for lib in "${libs[@]}"; do
        cp "${THIN_DIR}/iphoneos/arm64/lib/${lib}.a" "${FAT_DIR}/ios/${lib}.a"

        lipo -create \
            "${THIN_DIR}/iphonesimulator/arm64/lib/${lib}.a" \
            "${THIN_DIR}/iphonesimulator/x86_64/lib/${lib}.a" \
            -output "${FAT_DIR}/simulator/${lib}.a"

        lipo -create \
            "${THIN_DIR}/macosx/arm64/lib/${lib}.a" \
            "${THIN_DIR}/macosx/x86_64/lib/${lib}.a" \
            -output "${FAT_DIR}/macos/${lib}.a"

        local headers="${THIN_DIR}/iphoneos/arm64/include"
        xcodebuild -create-xcframework \
            -library "${FAT_DIR}/ios/${lib}.a" -headers "${headers}" \
            -library "${FAT_DIR}/simulator/${lib}.a" -headers "${headers}" \
            -library "${FAT_DIR}/macos/${lib}.a" -headers "${headers}" \
            -output "${XCFRAMEWORK_DIR}/${lib}.xcframework"
    done
}

print_decoder_hints() {
    echo
    echo "==> Build done"
    echo "Artifacts: ${XCFRAMEWORK_DIR}"
    echo
    echo "Recommended decoder checks in FFmpeg config.h during CI logs:"
    echo "  CONFIG_PCM_ALAW_DECODER"
    echo "  CONFIG_PCM_MULAW_DECODER"
    echo "  CONFIG_ADPCM_G726_DECODER"
    echo "  CONFIG_ADPCM_G726LE_DECODER"
    echo "  CONFIG_AAC_DECODER"
}

download_ffmpeg_source
build_arch "arm64" "iphoneos"
build_arch "arm64" "iphonesimulator"
build_arch "x86_64" "iphonesimulator"
build_arch "arm64" "macosx"
build_arch "x86_64" "macosx"
create_xcframeworks
print_decoder_hints
