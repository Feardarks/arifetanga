// KafaTakip - kafa takipli 3D
//
// Ön kameradan yüzü takip eder, kafanın ekrana göre konumunu cm cinsinden
// hesaplar ve üst ekranda sahneyi o gözden bakılıyormuş gibi (off-axis
// stereo) çizer: ekran, arkasındaki kutuya açılan bir pencere gibi davranır.
// Alt ekranda durum bilgisi ve yüzün kameradaki konumunu gösteren bir radar var.
//
// Not: Konsol fontu Türkçe karakterleri desteklemediği için ekrandaki
// yazılar ASCII.

#include <stdio.h>
#include <string.h>

#include <3ds.h>
#include <citro3d.h>

#include "camera.h"
#include "face.h"
#include "head.h"
#include "oneeuro.h"
#include "scene.h"
#include "tracker.h"

// pico'nun kümeleme adımı yığında 16 KB'lık dizi ve özyineleme kullanıyor.
u32 __stacksize__ = 128 * 1024;

#define CLEAR_COLOR 0x101820FF

#define DISPLAY_TRANSFER_FLAGS \
	(GX_TRANSFER_FLIP_VERT(0) | GX_TRANSFER_OUT_TILED(0) | GX_TRANSFER_RAW_COPY(0) | \
	GX_TRANSFER_IN_FORMAT(GX_TRANSFER_FMT_RGBA8) | GX_TRANSFER_OUT_FORMAT(GX_TRANSFER_FMT_RGB8) | \
	GX_TRANSFER_SCALING(GX_TRANSFER_SCALE_NO))

#define EYE_DISTANCE_CM   6.3f  // iki göz arası
#define DEFAULT_HEAD_Z_CM 30.0f // yüz yokken varsayılan uzaklık
#define MIN_HEAD_Z_CM     10.0f
#define LOST_RETURN_MS    1500  // yüz bu kadar süre görülmezse merkeze dön
#define MANUAL_RANGE_X_CM 8.0f  // circle pad tam itildiğinde ek kayma
#define MANUAL_RANGE_Y_CM 5.0f
#define HUD_INTERVAL_MS   250

// Alt ekran radarı (kamera görüntüsünün küçük haritası)
#define RADAR_COLS 30
#define RADAR_ROWS 15
#define RADAR_TOP  12

static u8 s_gray[CAM_W * CAM_H];

static double ticks_to_ms(u64 ticks)
{
	return (double)ticks * 1000.0 / SYSCLOCK_ARM11;
}

// RGB565 -> 8 bit gri.
static void to_gray(const u16* src, u8* dst)
{
	for (int i = 0; i < CAM_W * CAM_H; i++) {
		u16 p = src[i];
		u32 r = (p >> 11) & 0x1F;
		u32 g = (p >> 5) & 0x3F;
		u32 b = p & 0x1F;
		// 5/6 bit kanalları 8 bite ölçekleyip Y = 0.30R + 0.59G + 0.11B
		dst[i] = (u8)((r * 8 * 77 + g * 4 * 150 + b * 8 * 29) >> 8);
	}
}

static void draw_radar(bool hasFace, const Face* face)
{
	int fc = -1, fr = -1;
	if (hasFace) {
		// Kamera görüntüsü zaten ayna gibi: izleyici sağa gidince işaret de sağa gider.
		fc = (int)(face->x * RADAR_COLS / CAM_W);
		fr = (int)(face->y * RADAR_ROWS / CAM_H);
	}

	char line[RADAR_COLS + 3];
	memset(line, '-', sizeof(line) - 1);
	line[0] = '+';
	line[RADAR_COLS + 1] = '+';
	line[RADAR_COLS + 2] = '\0';
	printf("\x1b[%d;1H%s", RADAR_TOP, line);
	printf("\x1b[%d;1H%s", RADAR_TOP + RADAR_ROWS + 1, line);

	for (int r = 0; r < RADAR_ROWS; r++) {
		line[0] = '|';
		line[RADAR_COLS + 1] = '|';
		for (int c = 0; c < RADAR_COLS; c++)
			line[1 + c] = (r == fr && c == fc) ? 'O' : ' ';
		// Merkez işareti
		if (r == RADAR_ROWS / 2 && line[1 + RADAR_COLS / 2] == ' ')
			line[1 + RADAR_COLS / 2] = '+';
		printf("\x1b[%d;1H%s", RADAR_TOP + 1 + r, line);
	}
}

static void wait_for_start(void)
{
	printf("\nCikmak icin START'a bas.\n");
	while (aptMainLoop()) {
		hidScanInput();
		if (hidKeysDown() & KEY_START)
			break;
		gfxFlushBuffers();
		gspWaitForVBlank();
	}
}

int main(void)
{
	gfxInitDefault();
	gfxSet3D(true);
	consoleInit(GFX_BOTTOM, NULL);
	C3D_Init(C3D_DEFAULT_CMDBUF_SIZE);

	C3D_RenderTarget* left = C3D_RenderTargetCreate(240, 400, GPU_RB_RGBA8, GPU_RB_DEPTH24_STENCIL8);
	C3D_RenderTarget* right = C3D_RenderTargetCreate(240, 400, GPU_RB_RGBA8, GPU_RB_DEPTH24_STENCIL8);
	C3D_RenderTargetSetOutput(left, GFX_TOP, GFX_LEFT, DISPLAY_TRANSFER_FLAGS);
	C3D_RenderTargetSetOutput(right, GFX_TOP, GFX_RIGHT, DISPLAY_TRANSFER_FLAGS);

	if (!scene_init() || !face_init()) {
		printf("Baslatma hatasi (bellek ya da shader)!");
		wait_for_start();
		C3D_Fini();
		gfxExit();
		return 0;
	}

	Result res = camera_open();
	if (R_FAILED(res)) {
		printf("Kamera acilamadi! Hata: 0x%08lX", res);
		wait_for_start();
		camera_close();
		face_exit();
		scene_exit();
		C3D_Fini();
		gfxExit();
		return 0;
	}

	Tracker tracker;
	tracker_init(&tracker);

	OneEuro filterX, filterY, filterZ;
	oneeuro_init(&filterX, 1.0f, 0.15f, 1.0f);
	oneeuro_init(&filterY, 1.0f, 0.15f, 1.0f);
	oneeuro_init(&filterZ, 0.5f, 0.05f, 1.0f);

	float qthreshold = 5.0f;
	float gain = 1.0f;
	bool flipX = false, flipY = false;
	float offsetX = 0.0f, offsetY = 0.0f;

	HeadPos lastRaw = { 0.0f, 0.0f, DEFAULT_HEAD_Z_CM };
	HeadPos head = { 0.0f, 0.0f, DEFAULT_HEAD_Z_CM };
	bool everSeen = false;

	u64 startMs = osGetTime();
	u64 lastCamMs = startMs;
	u64 lastSeenMs = 0;
	u64 lastHudMs = startMs;

	u32 camFrames = 0, renderFrames = 0, fullScans = 0;
	u64 detectTicks = 0;

	while (aptMainLoop()) {
		hidScanInput();
		u32 kDown = hidKeysDown();
		if (kDown & KEY_START)
			break;
		if (kDown & KEY_L && qthreshold >= 0.5f)
			qthreshold -= 0.5f;
		if (kDown & KEY_R)
			qthreshold += 0.5f;
		if (kDown & KEY_DUP)
			gain += 0.25f;
		if (kDown & KEY_DDOWN && gain > 0.25f)
			gain -= 0.25f;
		if (kDown & KEY_X)
			flipX = !flipX;
		if (kDown & KEY_Y)
			flipY = !flipY;
		if (kDown & KEY_A) {
			// Şu anki konumu merkez kabul et.
			offsetX = -lastRaw.x;
			offsetY = -lastRaw.y;
		}
		if (kDown & KEY_B) {
			offsetX = 0.0f;
			offsetY = 0.0f;
		}

		u64 nowMs = osGetTime();

		// Yeni kamera karesi varsa takip et (beklemeden kontrol).
		if (camera_wait_frame(0)) {
			to_gray(camera_frame(), s_gray);

			u64 t0 = svcGetSystemTick();
			bool found = tracker_update(&tracker, s_gray, CAM_W, CAM_H, qthreshold);
			detectTicks += svcGetSystemTick() - t0;
			if (tracker.lastWasFullScan)
				fullScans++;
			camFrames++;

			float dt = (nowMs - lastCamMs) / 1000.0f;
			lastCamMs = nowMs;

			if (found) {
				lastRaw = head_from_face(&tracker.face, CAM_W, CAM_H, flipX, flipY);
				lastSeenMs = nowMs;
				everSeen = true;

				head.x = oneeuro_filter(&filterX, (lastRaw.x + offsetX) * gain, dt);
				head.y = oneeuro_filter(&filterY, (lastRaw.y + offsetY) * gain, dt);
				head.z = oneeuro_filter(&filterZ, lastRaw.z, dt);
			}
		}

		// Yüz uzun süre görülmezse yavaşça merkeze dön.
		if (!everSeen || nowMs - lastSeenMs > LOST_RETURN_MS) {
			head.x += (0.0f - head.x) * 0.05f;
			head.y += (0.0f - head.y) * 0.05f;
			head.z += (DEFAULT_HEAD_Z_CM - head.z) * 0.05f;
			oneeuro_reset(&filterX);
			oneeuro_reset(&filterY);
			oneeuro_reset(&filterZ);
		}

		// Circle pad ile elle kafa kaydırma (takip olmadan test için).
		circlePosition pad;
		hidCircleRead(&pad);
		float eyeX = head.x + pad.dx / 156.0f * MANUAL_RANGE_X_CM;
		float eyeY = head.y + pad.dy / 156.0f * MANUAL_RANGE_Y_CM;
		float eyeZ = head.z < MIN_HEAD_Z_CM ? MIN_HEAD_Z_CM : head.z;

		float slider = osGet3DSliderState();
		float halfEye = EYE_DISTANCE_CM * slider / 2.0f;
		float timeSec = (nowMs - startMs) / 1000.0f;

		C3D_FrameBegin(C3D_FRAME_SYNCDRAW);
		C3D_RenderTargetClear(left, C3D_CLEAR_ALL, CLEAR_COLOR, 0);
		C3D_FrameDrawOn(left);
		scene_render_eye(eyeX - halfEye, eyeY, eyeZ, timeSec);
		C3D_RenderTargetClear(right, C3D_CLEAR_ALL, CLEAR_COLOR, 0);
		C3D_FrameDrawOn(right);
		scene_render_eye(eyeX + halfEye, eyeY, eyeZ, timeSec);
		C3D_FrameEnd(0);
		renderFrames++;

		if (nowMs - lastHudMs >= HUD_INTERVAL_MS) {
			float secs = (nowMs - lastHudMs) / 1000.0f;
			bool locked = tracker.locked && nowMs - lastSeenMs < LOST_RETURN_MS;

			printf("\x1b[1;1HKafaTakip - kafa takipli 3D");
			printf("\x1b[3;1HTakip   : %s", locked ? "\x1b[32mKILITLI \x1b[0m" : "\x1b[33mARANIYOR\x1b[0m");
			printf("\x1b[4;1HKamera  : %4.1f FPS  Cizim: %4.1f FPS ", camFrames / secs, renderFrames / secs);
			if (camFrames > 0)
				printf("\x1b[5;1HAlgilama: %5.2f ms  tam tarama %3lu%% ",
					ticks_to_ms(detectTicks) / camFrames, fullScans * 100 / camFrames);
			if (tracker.locked)
				printf("\x1b[6;1HYuz     : x%4d y%4d boy%4d q%5.1f ",
					(int)tracker.face.x, (int)tracker.face.y, (int)tracker.face.size, tracker.face.q);
			else
				printf("\x1b[6;1HYuz     : yok                          ");
			printf("\x1b[7;1HKafa cm : X%+5.1f Y%+5.1f Z%5.1f  ", eyeX, eyeY, eyeZ);
			printf("\x1b[8;1HEsik L/R: %4.1f  Kazanc dpad: %4.2f ", qthreshold, gain);
			printf("\x1b[9;1HTers X/Y: yatay %s  dikey %s ", flipX ? "EVET " : "hayir", flipY ? "EVET " : "hayir");
			printf("\x1b[10;1H3D slider: %4.2f ", slider);

			draw_radar(tracker.locked, &tracker.face);

			printf("\x1b[29;1HA merkezle  B sifirla  pad: elle kafa");
			printf("\x1b[30;1HSTART cikis");
			gfxFlushBuffers();

			camFrames = 0;
			renderFrames = 0;
			fullScans = 0;
			detectTicks = 0;
			lastHudMs = nowMs;
		}
	}

	camera_close();
	face_exit();
	scene_exit();
	C3D_RenderTargetDelete(left);
	C3D_RenderTargetDelete(right);
	C3D_Fini();
	gfxExit();
	return 0;
}
