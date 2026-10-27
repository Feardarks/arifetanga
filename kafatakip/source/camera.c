#include <stdlib.h>

#include "camera.h"

#define FRAME_BYTES (CAM_W * CAM_H * 2)

// Çift buffer: biri işlenirken kamera diğerine yazar, böylece kare kaçmaz.
static u16* s_bufs[2];
static int s_recvIdx;
static int s_readyIdx;
static u32 s_transferUnit;
// 0: buffer hatası olayı, 1: kare alındı olayı
static Handle s_events[2];
static bool s_restart;

static void start_receive(void)
{
	CAMU_SetReceiving(&s_events[1], s_bufs[s_recvIdx], PORT_CAM1, FRAME_BYTES, (s16)s_transferUnit);
}

Result camera_open(void)
{
	Result res = camInit();
	if (R_FAILED(res))
		return res;

	for (int i = 0; i < 2; i++) {
		s_bufs[i] = malloc(FRAME_BYTES);
		if (!s_bufs[i])
			return -1;
	}

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
	// Bekleyen alma isteği yoksa (ilk çağrı ya da buffer hatası sonrası) ver.
	if (s_events[1] == 0)
		start_receive();

	if (s_restart) {
		CAMU_StartCapture(PORT_CAM1);
		s_restart = false;
	}

	s32 index = -1;
	Result res = svcWaitSynchronizationN(&index, s_events, 2, false, timeout_ns);
	if (R_FAILED(res) || R_DESCRIPTION(res) == RD_TIMEOUT)
		return false;

	// İki durumda da alma isteği bitti.
	svcCloseHandle(s_events[1]);
	s_events[1] = 0;

	if (index != 1) {
		// Buffer hatası: yakalama durdu, bir sonraki çağrıda yeniden başlat.
		s_restart = true;
		return false;
	}

	// Biten kareyi hazır işaretle ve sonraki kareyi hemen öbür buffer'a iste;
	// çağıran bu kareyi işlerken kamera beklemeden yazmaya devam eder.
	s_readyIdx = s_recvIdx;
	s_recvIdx ^= 1;
	start_receive();
	return true;
}

const u16* camera_frame(void)
{
	return s_bufs[s_readyIdx];
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

	for (int i = 0; i < 2; i++) {
		free(s_bufs[i]);
		s_bufs[i] = NULL;
	}
}
