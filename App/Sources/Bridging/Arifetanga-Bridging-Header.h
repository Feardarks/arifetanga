// Uygulama hedefinin C köprüsü: FFmpeg (LGPL, statik), libdovi (MIT, statik) ve libsmb2 (LGPL, statik; S7).
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>
#include <libdovi/rpu_parser.h>
#include "FFShim.h"
#include "SMBShim.h"
