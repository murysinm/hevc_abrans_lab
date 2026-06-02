./configure \
  --disable-everything \
  --disable-doc \
  --disable-network \
  --enable-decoder=hevc \
  --enable-parser=hevc \
  --enable-demuxer=hevc \
  --enable-protocol=file \
  --enable-muxer=yuv4mpegpipe \
  --enable-encoder=rawvideo \
  --enable-muxer=rawvideo \
  --enable-debug=3 \
  --disable-optimizations \
  --disable-stripping \
  --disable-asm

bear -- make -j$(nproc)
