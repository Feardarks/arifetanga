// KafaTakip - Aşama 1
// Ön kameradan 160x120 görüntü alır, gri tonlamaya çevirir ve alt ekrana
// 2x büyütülmüş olarak çizer. Üst ekranda FPS ve süre ölçümleri gösterilir.
//
// Not: Konsol fontu Türkçe karakterleri desteklemediği için ekrandaki
// yazılar ASCII.

#include <stdio.h>

#include <3ds.h>

#include "camera.h"

// Aşama 2'de yüz algılama bu gri görüntü üzerinde çalışacak.
static u8 s_gray[CAM_W * CAM_H];

static double ticks_to_ms(u64 ticks)
{
	return (double)ticks * 1000.0 / SYSCLOCK_ARM11;
}

// RGB565 -> 8 bit gri. Ortalama parlaklığı döndürür.
static u32 to_gray(const u16* src, u8* dst)
{
	u32 sum = 0;
	for (int i = 0; i < CAM_W * CAM_H; i++) {
		u16 p = src[i];
		u32 r = (p >> 11) & 0x1F;
		u32 g = (p >> 5) & 0x3F;
		u32 b = p & 0x1F;
		// 5/6 bit kanalları 8 bite ölçekleyip Y = 0.30R + 0.59G + 0.11B
		u32 y = (r * 8 * 77 + g * 4 * 150 + b * 8 * 29) >> 8;
		dst[i] = (u8)y;
		sum += y;
	}
	return sum / (CAM_W * CAM_H);
}

// Gri görüntüyü alt ekrana (320x240) 2x büyütüp çizer.
// Alt ekran framebuffer'ı 90 derece döndürülmüş, BGR8 formatında.
static void draw_gray_bottom(const u8* gray, bool mirror)
{
	u8* fb = gfxGetFramebuffer(GFX_BOTTOM, GFX_LEFT, NULL, NULL);

	for (int sx = 0; sx < 320; sx++) {
		int cx = sx >> 1;
		if (mirror)
			cx = CAM_W - 1 - cx;

		u8* col = fb + sx * 240 * 3;
		for (int sy = 0; sy < 240; sy++) {
			u8 v = gray[(sy >> 1) * CAM_W + cx];
			u8* p = col + (239 - sy) * 3;
			p[0] = v;
			p[1] = v;
			p[2] = v;
		}
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
	consoleInit(GFX_TOP, NULL);

	printf("\x1b[1;1HKafaTakip - Asama 1: kamera testi");
	printf("\x1b[3;1HSTART: cikis   A: aynalama ac/kapa");

	Result res = camera_open();
	if (R_FAILED(res)) {
		printf("\x1b[5;1HKamera acilamadi! Hata: 0x%08lX", res);
		wait_for_start();
		camera_close();
		gfxExit();
		return 0;
	}

	bool mirror = true;
	u32 frames = 0;
	u64 grayTicks = 0;
	u64 drawTicks = 0;
	u32 brightness = 0;
	u64 lastReport = osGetTime();

	while (aptMainLoop()) {
		hidScanInput();
		u32 kDown = hidKeysDown();
		if (kDown & KEY_START)
			break;
		if (kDown & KEY_A)
			mirror = !mirror;

		// 50 ms bekle; kare gelmezse döngü yine de tuşları okumaya devam eder.
		bool gotFrame = camera_wait_frame(50000000ULL);

		if (gotFrame) {
			u64 t0 = svcGetSystemTick();
			brightness = to_gray(camera_frame(), s_gray);
			u64 t1 = svcGetSystemTick();
			draw_gray_bottom(s_gray, mirror);
			u64 t2 = svcGetSystemTick();

			grayTicks += t1 - t0;
			drawTicks += t2 - t1;
			frames++;
		}

		u64 now = osGetTime();
		if (now - lastReport >= 1000) {
			double secs = (now - lastReport) / 1000.0;
			printf("\x1b[5;1HKamera FPS   : %5.1f   ", frames / secs);
			if (frames > 0) {
				printf("\x1b[6;1HGri cevirme  : %5.2f ms   ", ticks_to_ms(grayTicks) / frames);
				printf("\x1b[7;1HEkrana cizim : %5.2f ms   ", ticks_to_ms(drawTicks) / frames);
			}
			printf("\x1b[8;1HParlaklik    : %3lu / 255   ", brightness);
			printf("\x1b[9;1HAynalama     : %s   ", mirror ? "acik" : "kapali");

			frames = 0;
			grayTicks = 0;
			drawTicks = 0;
			lastReport = now;
		}

		gfxFlushBuffers();
		if (gotFrame) {
			gfxSwapBuffers();
			gspWaitForVBlank();
		}
	}

	camera_close();
	gfxExit();
	return 0;
}
