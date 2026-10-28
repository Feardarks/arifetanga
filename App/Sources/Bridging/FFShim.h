// Swift'e aktarılamayan FFmpeg makroları için küçük satır içi sarmalayıcılar.
#ifndef FFShim_h
#define FFShim_h

#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

static inline int arif_averror_eof(void) { return AVERROR_EOF; }
static inline int arif_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int arif_averror_eio(void) { return AVERROR(EIO); }
static inline int64_t arif_nopts_value(void) { return AV_NOPTS_VALUE; }
static inline int64_t arif_time_base(void) { return AV_TIME_BASE; }

/// Akışın kodlanmış yan verisini (FFmpeg 7+: codecpar->coded_side_data) türüne göre bulur.
static inline const AVPacketSideData *arif_stream_side_data(const AVStream *st, enum AVPacketSideDataType type) {
    return av_packet_side_data_get(st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data, type);
}

#endif
