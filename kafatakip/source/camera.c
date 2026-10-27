#include <stdlib.h>

#include "camera.h"

#define FRAME_BYTES (CAM_W * CAM_H * 2)

static u16* s_buf;
static u32 s_transferUnit;
// 0: buffer hatası olayı, 1: kare alındı olayı
static Handle s_events[2];
static bool s_restart;

Result camera_open(void)
{
	Result res = camInit();
	if (R_FAILED(res))
		return res;

	s_buf = malloc(FRAME_BYTES);
	if (!s_buf)
		return -1;

	CAMU_SetSize(SELECT_IN1, SIZE_QQVGA, CONTEXT_A);
	CAMU_SetOutputFormat(SELECT_IN1, OUTPUT_RGB_565, CONTEXT_A);
	CAMU_SetFrameRate(SELECT_IN1, FRAME_RATE_30);
	CAMU_SetNoiseFilter(SELECT_IN1, true);
	CAMU_SetAutoExposure(SELECT_IN1, true);
	CAMU_SetAutoWhiteBalance(SELECT_IN1, true);
	// İç kamera CAM1 portunu kullanır.
	CAMU_SetTrimming(PORT_CAM1, false);

	res = CAMU_GetMaxBytes(&s_transferUnit, CAM_W, CAM_H);
	if (R_FAILED(res))
		return res;
	res = CAMU_SetTransferBytes(PORT_CAM1, s_transferUnit, CAM_W, CAM_H);
	if (R_FAILED(res))
		return res;

	res = CAMU_Activate(SELECT_IN1);
	if (R_FAILED(res))
		return res;

	res = CAMU_GetBufferErrorInterruptEvent(&s_events[0], PORT_CAM1);
	if (R_FAILED(res))
		return res;

	CAMU_ClearBuffer(PORT_CAM1);
	return CAMU_StartCapture(PORT_CAM1);
}

bool camera_wait_frame(u64 timeout_ns)
{
	// Bir sonraki kareyi alma isteği. Kare işlenirken buffer'a yazılmasın diye
	// istek ancak önceki kare işlendikten sonra (bir sonraki çağrıda) verilir.
	if (s_events[1] == 0)
		CAMU_SetReceiving(&s_events[1], s_buf, PORT_CAM1, FRAME_BYTES, (s16)s_transferUnit);

	if (s_restart) {
		CAMU_StartCapture(PORT_CAM1);
		s_restart = false;
	}

	s32 index = -1;
	Result res = svcWaitSynchronizationN(&index, s_events, 2, false, timeout_ns);
	if (R_FAILED(res) || R_DESCRIPTION(res) == RD_TIMEOUT)
		return false;

	// İki durumda da alma isteği bitti; yeni istek bir sonraki çağrıda verilecek.
	svcCloseHandle(s_events[1]);
	s_events[1] = 0;

	if (index == 0) {
		// Buffer hatası: yakalama durdu, yeniden başlat.
		s_restart = true;
		return false;
	}

	return index == 1;
}

const u16* camera_frame(void)
{
	return s_buf;
}

void camera_close(void)
{
	CAMU_StopCapture(PORT_CAM1);

	for (int i = 0; i < 2; i++) {
		if (s_events[i]) {
			svcCloseHandle(s_events[i]);
			s_events[i] = 0;
		}
	}

	CAMU_Activate(SELECT_NONE);
	camExit();

	free(s_buf);
	s_buf = NULL;
}
