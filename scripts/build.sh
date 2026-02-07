#!/bin/bash
set -e

# ==========================================
# 配置区域
# ==========================================
FFMPEG_VERSION=$1
WORK_DIR=$(pwd)
SOURCE_DIR="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
OUTPUT_DIR="$WORK_DIR/output"
THIN_DIR="$OUTPUT_DIR/thin"
FAT_DIR="$OUTPUT_DIR/fat"

# 1. 下载源码 (如果不存在)
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Downloading FFmpeg $FFMPEG_VERSION..."
    curl -O https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2
    tar xjvf ffmpeg-$FFMPEG_VERSION.tar.bz2
fi

cd "$SOURCE_DIR"

# ==========================================
# 🔥 核心配置：工业级 RTSP 专用 (无软解)
# ==========================================
COMMON_FLAGS="
    --disable-everything 
    --enable-protocol=rtsp,tcp,udp,file 
    --enable-demuxer=rtsp,mov,mpegts 
    --enable-parser=h264,hevc,aac 
    --disable-debug 
    --disable-doc 
    --disable-programs 
    --disable-avdevice 
    --disable-avfilter 
    --disable-postproc 
    --disable-swscale 
    --disable-swresample 
    --enable-cross-compile 
    --enable-pic
    --target-os=darwin
    --pkg-config-flags=--static
"

# 编译函数
build_arch() {
    ARCH=$1
    PLATFORM=$2 # iphoneos, iphonesimulator, macosx
    
    echo "Building for $PLATFORM ($ARCH)..."
    
    # 清理上次编译残留
    make distclean > /dev/null 2>&1 || true
    
    SDK_PATH=$(xcrun --sdk $PLATFORM --show-sdk-path)
    CC="xcrun -sdk $PLATFORM clang"
    CXX="xcrun -sdk $PLATFORM clang++"
    
    # 针对不同架构的 Flags
    # 注意：已移除 -fembed-bitcode (Xcode 15+ 不再支持)
    if [ "$PLATFORM" == "macosx" ]; then
        TARGET_FLAGS="-arch $ARCH -isysroot $SDK_PATH -mmacosx-version-min=10.15"
    elif [ "$PLATFORM" == "iphonesimulator" ]; then
        TARGET_FLAGS="-arch $ARCH -isysroot $SDK_PATH -mios-simulator-version-min=12.0"
    else
        # iphoneos
        TARGET_FLAGS="-arch $ARCH -isysroot $SDK_PATH -miphoneos-version-min=12.0"
    fi

    ./configure \
        $COMMON_FLAGS \
        --arch=$ARCH \
        --cc="$CC" \
        --cxx="$CXX" \
        --sysroot="$SDK_PATH" \
        --extra-cflags="$TARGET_FLAGS" \
        --extra-ldflags="$TARGET_FLAGS" \
        --prefix="$THIN_DIR/$PLATFORM/$ARCH"

    # 使用所有核心进行编译
    make -j$(sysctl -n hw.logicalcpu)
    make install
}

# ==========================================
# 2. 开始编译各个架构
# ==========================================

# iOS Device
build_arch "arm64" "iphoneos"

# iOS Simulator (Apple Silicon + Intel)
build_arch "arm64" "iphonesimulator"
build_arch "x86_64" "iphonesimulator"

# macOS (Apple Silicon + Intel)
build_arch "arm64" "macosx"
build_arch "x86_64" "macosx"

# ==========================================
# 3. 合并静态库 (Lipo)
#    注意：只处理 avcodec, avformat, avutil
#    (移除了 swscale/swresample，因为上面 disable 了)
# ==========================================
echo "Merging architectures..."

mkdir -p "$FAT_DIR/ios" "$FAT_DIR/simulator" "$FAT_DIR/macos"

libs=("libavcodec" "libavformat" "libavutil")

for lib in "${libs[@]}"; do
    # 3.1 iOS Device (只有 arm64，直接拷贝)
    cp "$THIN_DIR/iphoneos/arm64/lib/$lib.a" "$FAT_DIR/ios/$lib.a"
    
    # 3.2 iOS Simulator (arm64 + x86_64 合并)
    lipo -create \
        "$THIN_DIR/iphonesimulator/arm64/lib/$lib.a" \
        "$THIN_DIR/iphonesimulator/x86_64/lib/$lib.a" \
        -output "$FAT_DIR/simulator/$lib.a"

    # 3.3 macOS (arm64 + x86_64 合并)
    lipo -create \
        "$THIN_DIR/macosx/arm64/lib/$lib.a" \
        "$THIN_DIR/macosx/x86_64/lib/$lib.a" \
        -output "$FAT_DIR/macos/$lib.a"
done

# ==========================================
# 4. 生成 XCFramework
# ==========================================
echo "Creating XCFrameworks..."
mkdir -p "$OUTPUT_DIR/xcframeworks"

for lib in "${libs[@]}"; do
    # 头文件是一样的，取一份即可
    HEADERS="$THIN_DIR/iphoneos/arm64/include"
    
    xcodebuild -create-xcframework \
        -library "$FAT_DIR/ios/$lib.a" -headers "$HEADERS" \
        -library "$FAT_DIR/simulator/$lib.a" -headers "$HEADERS" \
        -library "$FAT_DIR/macos/$lib.a" -headers "$HEADERS" \
        -output "$OUTPUT_DIR/xcframeworks/$lib.xcframework"
done

echo "🎉 Build Complete! Artifacts are in: $OUTPUT_DIR/xcframeworks"
