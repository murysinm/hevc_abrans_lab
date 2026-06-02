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

bear -- make -j$(nproc)
