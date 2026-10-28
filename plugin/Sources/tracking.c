// Plugin içinde çalışan kafa takibi.
//
// Oyunun ana thread'iyle aynı çekirdekte (Old 3DS'te uygulamalar ikinci
// çekirdeği kullanamıyor) en düşük öncelikte çalışır; böylece sadece oyun
// boşta beklerken (ör. VBlank) CPU alır ve oyunu mümkün olduğunca az yavaşlatır.

#include <string.h>

#include "camera.h"
#include "face.h"
#include "head.h"
#include "oneeuro.h"
#include "tracker.h"
#include "tracking.h"

#define THREAD_STACK_SIZE (64 * 1024) // pico kümelemesi yığında ~16 KB kullanır
#define THREAD_PRIORITY   0x3F
#define THREAD_CORE       0
#define QTHRESHOLD        5.0f
#define FRAME_TIMEOUT_NS  100000000ULL

static Thread s_thread;
static volatile bool s_stop;
static volatile bool s_paused;

static LightLock s_lock;
static TrackingStatus s_status;

static u8 s_gray[CAM_W * CAM_H];

static void set_status(const TrackingStatus* st)
{
	LightLock_Lock(&s_lock);
	s_status = *st;
	LightLock_Unlock(&s_lock);
}

void tracking_get(TrackingStatus* out)
{
	LightLock_Lock(&s_lock);
	*out = s_status;
	LightLock_Unlock(&s_lock);
}

// RGB565 -> 8 bit gri.
static void to_gray(const u16* src, u8* dst)
{
	for (int i = 0; i < CAM_W * CAM_H; i++) {
		u16 p = src[i];
		u32 r = (p >> 11) & 0x1F;
		u32 g = (p >> 5) & 0x3F;
		u32 b = p & 0x1F;
		dst[i] = (u8)((r * 8 * 77 + g * 4 * 150 + b * 8 * 29) >> 8);
	}
}

static void thread_main(void* arg)
{
	(void)arg;

	TrackingStatus st;
	memset(&st, 0, sizeof(st));
	st.state = TRACK_STARTING;
	set_status(&st);

	if (!face_init()) {
		st.state = TRACK_ERROR;
		st.error = -1;
		set_status(&st);
		return;
	}

	Tracker tracker;
	OneEuro fx, fy, fz;
	oneeuro_init(&fx, 1.0f, 0.15f, 1.0f);
	oneeuro_init(&fy, 1.0f, 0.15f, 1.0f);
	oneeuro_init(&fz, 0.5f, 0.05f, 1.0f);

	bool cameraOpen = false;
	u64 lastFrameMs = osGetTime();
	u64 lastStatsMs = lastFrameMs;
	u32 frames = 0;
	u64 detectTicks = 0;

	while (!s_stop) {
		if (s_paused) {
			if (cameraOpen) {
				camera_close();
				cameraOpen = false;
			}
			st.state = TRACK_PAUSED;
			set_status(&st);
			svcSleepThread(100000000LL);
			continue;
		}

		if (!cameraOpen) {
			Result res = camera_open();
			if (R_FAILED(res)) {
				camera_close();
				st.state = TRACK_ERROR;
				st.error = res;
				set_status(&st);
				// Kamera başka bir şey tarafından kullanılıyor olabilir; bekleyip tekrar dene.
				svcSleepThread(2000000000LL);
				continue;
			}
			cameraOpen = true;
			tracker_init(&tracker);
			oneeuro_reset(&fx);
			oneeuro_reset(&fy);
			oneeuro_reset(&fz);
			st.state = TRACK_SEARCHING;
			set_status(&st);
		}

		if (!camera_wait_frame(FRAME_TIMEOUT_NS))
			continue;

		to_gray(camera_frame(), s_gray);
		u64 t0 = svcGetSystemTick();
		bool found = tracker_update(&tracker, s_gray, CAM_W, CAM_H, QTHRESHOLD);
		detectTicks += svcGetSystemTick() - t0;
		frames++;

		u64 nowMs = osGetTime();
		float dt = (nowMs - lastFrameMs) / 1000.0f;
		lastFrameMs = nowMs;

		if (found) {
			HeadPos raw = head_from_face(&tracker.face, CAM_W, CAM_H, false, false);
			st.x = oneeuro_filter(&fx, raw.x, dt);
			st.y = oneeuro_filter(&fy, raw.y, dt);
			st.z = oneeuro_filter(&fz, raw.z, dt);
			st.state = TRACK_LOCKED;
		} else {
			st.state = TRACK_SEARCHING;
		}

		if (nowMs - lastStatsMs >= 1000) {
			float secs = (nowMs - lastStatsMs) / 1000.0f;
			st.camFps = frames / secs;
			st.detectMs = frames ? (float)((double)detectTicks * 1000.0 / SYSCLOCK_ARM11 / frames) : 0.0f;
			frames = 0;
			detectTicks = 0;
			lastStatsMs = nowMs;
		}
		set_status(&st);
	}

	if (cameraOpen)
		camera_close();
	face_exit();
}

bool tracking_start(void)
{
	LightLock_Init(&s_lock);
	memset(&s_status, 0, sizeof(s_status));
	s_stop = false;
	s_paused = false;
	s_thread = threadCreate(thread_main, NULL, THREAD_STACK_SIZE, THREAD_PRIORITY, THREAD_CORE, false);
	return s_thread != NULL;
}

void tracking_pause(bool paused)
{
	s_paused = paused;
}

void tracking_stop(void)
{
	if (!s_thread)
		return;
	s_stop = true;
	threadJoin(s_thread, 3000000000ULL);
	threadFree(s_thread);
	s_thread = NULL;
}
