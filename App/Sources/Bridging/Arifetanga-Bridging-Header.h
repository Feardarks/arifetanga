// Uygulama hedefinin C köprüsü: FFmpeg (LGPL, statik) ve libdovi (MIT, statik).
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>
#include "FFShim.h"
