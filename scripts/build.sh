#!/bin/bash
set -e

FFMPEG_VERSION=$1
if [ -z "$FFMPEG_VERSION" ]; then
  echo "Usage: ./build-ffmpeg.sh <ffmpeg-version>"
  exit 1
fi

ROOT_DIR=$(pwd)
SOURCE_DIR="$ROOT_DIR/ffmpeg-$FFMPEG_VERSION"
OUTPUT_DIR="$ROOT_DIR/output"
THIN_DIR="$OUTPUT_DIR/thin"

mkdir -p "$OUTPUT_DIR"

# =====================================================
# 1. Download FFmpeg
# =====================================================
if [ ! -d "$SOURCE_DIR" ]; then
  echo "Downloading FFmpeg $FFMPEG_VERSION..."
  curl -LO https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2
  tar xjf ffmpeg-$FFMPEG_VERSION.tar.bz2
fi

cd "$SOURCE_DIR"

# =====================================================
# 2. Common configuration (Demux + Parser ONLY)
# =====================================================
COMMON_FLAGS="
--disable-everything
--enable-protocol=rtsp,tcp,udp
--enable-demuxer=rtsp,mpegts,mov
--enable-parser=h264,hevc
--disable-decoder
--disable-encoder
--disable-muxer
--disable-avdevice
--disable-avfilter
--disable-postproc
--disable-swscale
--disable-swresample
--disable-debug
--disable-doc
--disable-programs
--enable-pic
--target-os=darwin
"

build_arch() {
  ARCH=$1
  PLATFORM=$2
  MIN_VERSION=$3

  echo "Building $PLATFORM ($ARCH)..."

  make distclean >/dev/null 2>&1 || true

  SDK_PATH=$(xcrun --sdk $PLATFORM --show-sdk-path)
  CC="xcrun -sdk $PLATFORM clang"

  EXTRA_FLAGS="-arch $ARCH -isysroot $SDK_PATH"

  if [ "$PLATFORM" = "iphoneos" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS -miphoneos-version-min=$MIN_VERSION"
  elif [ "$PLATFORM" = "iphonesimulator" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS -mios-simulator-version-min=$MIN_VERSION"
  else
    EXTRA_FLAGS="$EXTRA_FLAGS -mmacosx-version-min=$MIN_VERSION"
  fi

  ./configure \
    $COMMON_FLAGS \
    --arch=$ARCH \
    --cc="$CC" \
    --sysroot="$SDK_PATH" \
    --extra-cflags="$EXTRA_FLAGS" \
    --extra-ldflags="$EXTRA_FLAGS" \
    --prefix="$THIN_DIR/$PLATFORM/$ARCH"

  make -j$(sysctl -n hw.logicalcpu)
  make install
}

# =====================================================
# 3. Build targets
# =====================================================

# iOS device
build_arch arm64 iphoneos 12.0

# iOS simulator
build_arch arm64 iphonesimulator 12.0
build_arch x86_64 iphonesimulator 12.0

# macOS
build_arch arm64 macosx 10.15
build_arch x86_64 macosx 10.15

# =====================================================
# 4. Create XCFrameworks
# =====================================================
echo "Creating XCFrameworks..."
XCFRAMEWORK_DIR="$OUTPUT_DIR/xcframeworks"
mkdir -p "$XCFRAMEWORK_DIR"

LIBS=(libavformat libavcodec libavutil)

for lib in "${LIBS[@]}"; do
  xcodebuild -create-xcframework \
    -library "$THIN_DIR/iphoneos/arm64/lib/$lib.a" \
    -headers "$THIN_DIR/iphoneos/arm64/include" \
    -library "$THIN_DIR/iphonesimulator/arm64/lib/$lib.a" \
    -headers "$THIN_DIR/iphonesimulator/arm64/include" \
    -library "$THIN_DIR/iphonesimulator/x86_64/lib/$lib.a" \
    -headers "$THIN_DIR/iphonesimulator/x86_64/include" \
    -library "$THIN_DIR/macosx/arm64/lib/$lib.a" \
    -headers "$THIN_DIR/macosx/arm64/include" \
    -library "$THIN_DIR/macosx/x86_64/lib/$lib.a" \
    -headers "$THIN_DIR/macosx/x86_64/include" \
    -output "$XCFRAMEWORK_DIR/$lib.xcframework"
done

echo "✅ Done"
echo "XCFrameworks are in $XCFRAMEWORK_DIR"
