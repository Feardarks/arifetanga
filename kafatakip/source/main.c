// KafaTakip - Aşama 2
// Ön kameradan 160x120 görüntü alır, gri tonlamaya çevirir, pico ile yüz
// arar ve alt ekrana 2x büyütülmüş görüntüyle birlikte yüz kutusunu çizer.
// Üst ekranda FPS, süre ölçümleri ve yüz bilgisi gösterilir.
//
// Not: Konsol fontu Türkçe karakterleri desteklemediği için ekrandaki
// yazılar ASCII.

#include <stdio.h>

#include <3ds.h>

#include "camera.h"
#include "face.h"

// pico'nun kümeleme adımı yığında 16 KB'lık dizi ve özyineleme kullanıyor.
u32 __stacksize__ = 128 * 1024;

#define MAX_FACES 4

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
static void draw_gray_bottom(u8* fb, const u8* gray, bool mirror)
{
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

static void put_px(u8* fb, int x, int y, u8 r, u8 g, u8 b)
{
	if (x < 0 || x >= 320 || y < 0 || y >= 240)
		return;
	u8* p = fb + (x * 240 + (239 - y)) * 3;
	p[0] = b;
	p[1] = g;
	p[2] = r;
}

// Yüzü alt ekran koordinatlarına çevirip kutu olarak çizer.
static void draw_face_box(u8* fb, const Face* f, bool mirror, int thickness, u8 r, u8 g, u8 b)
{
	float cx = mirror ? (CAM_W - 1 - f->x) : f->x;
	int x0 = (int)((cx - f->size / 2) * 2);
	int x1 = (int)((cx + f->size / 2) * 2);
	int y0 = (int)((f->y - f->size / 2) * 2);
	int y1 = (int)((f->y + f->size / 2) * 2);

	for (int t = 0; t < thickness; t++) {
		for (int x = x0; x <= x1; x++) {
			put_px(fb, x, y0 + t, r, g, b);
			put_px(fb, x, y1 - t, r, g, b);
		}
		for (int y = y0; y <= y1; y++) {
			put_px(fb, x0 + t, y, r, g, b);
			put_px(fb, x1 - t, y, r, g, b);
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

	printf("\x1b[1;1HKafaTakip - Asama 2: yuz algilama");
	printf("\x1b[3;1HSTART: cikis   A: aynalama ac/kapa");
	printf("\x1b[4;1HL / R: esigi azalt / artir");

	if (!face_init()) {
		printf("\x1b[6;1HYuz kaskadi yuklenemedi (bellek yok)!");
		wait_for_start();
		gfxExit();
		return 0;
	}

	Result res = camera_open();
	if (R_FAILED(res)) {
		printf("\x1b[6;1HKamera acilamadi! Hata: 0x%08lX", res);
		wait_for_start();
		camera_close();
		face_exit();
		gfxExit();
		return 0;
	}

	bool mirror = true;
	float qthreshold = 5.0f;
	Face faces[MAX_FACES];
	int nfaces = 0;

	u32 frames = 0;
	u32 framesWithFace = 0;
	u64 grayTicks = 0;
	u64 detectTicks = 0;
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
		if (kDown & KEY_L && qthreshold >= 0.5f)
			qthreshold -= 0.5f;
		if (kDown & KEY_R)
			qthreshold += 0.5f;

		// 50 ms bekle; kare gelmezse döngü yine de tuşları okumaya devam eder.
		bool gotFrame = camera_wait_frame(50000000ULL);

		if (gotFrame) {
			u64 t0 = svcGetSystemTick();
			brightness = to_gray(camera_frame(), s_gray);
			u64 t1 = svcGetSystemTick();
			nfaces = face_detect(s_gray, CAM_W, CAM_H, qthreshold, faces, MAX_FACES);
			u64 t2 = svcGetSystemTick();

			u8* fb = gfxGetFramebuffer(GFX_BOTTOM, GFX_LEFT, NULL, NULL);
			draw_gray_bottom(fb, s_gray, mirror);
			// En güvenilir yüz kalın yeşil, diğerleri ince kırmızı.
			for (int i = nfaces - 1; i >= 0; i--) {
				if (i == 0)
					draw_face_box(fb, &faces[i], mirror, 2, 0, 255, 0);
				else
					draw_face_box(fb, &faces[i], mirror, 1, 255, 0, 0);
			}
			u64 t3 = svcGetSystemTick();

			grayTicks += t1 - t0;
			detectTicks += t2 - t1;
			drawTicks += t3 - t2;
			frames++;
			if (nfaces > 0)
				framesWithFace++;
		}

		u64 now = osGetTime();
		if (now - lastReport >= 1000) {
			double secs = (now - lastReport) / 1000.0;
			printf("\x1b[6;1HKamera FPS   : %5.1f   ", frames / secs);
			if (frames > 0) {
				printf("\x1b[7;1HGri cevirme  : %5.2f ms   ", ticks_to_ms(grayTicks) / frames);
				printf("\x1b[8;1HYuz algilama : %5.2f ms   ", ticks_to_ms(detectTicks) / frames);
				printf("\x1b[9;1HEkrana cizim : %5.2f ms   ", ticks_to_ms(drawTicks) / frames);
				printf("\x1b[10;1HYuz bulunan  : %3lu%% kare   ", framesWithFace * 100 / frames);
			}
			printf("\x1b[11;1HParlaklik    : %3lu / 255   ", brightness);
			printf("\x1b[12;1HEsik (L/R)   : %4.1f   ", qthreshold);
			if (nfaces > 0)
				printf("\x1b[13;1HYuz          : x=%3d y=%3d boyut=%3d q=%5.1f   ",
					(int)faces[0].x, (int)faces[0].y, (int)faces[0].size, faces[0].q);
			else
				printf("\x1b[13;1HYuz          : yok                              ");
			printf("\x1b[14;1HAynalama     : %s   ", mirror ? "acik" : "kapali");

			frames = 0;
			framesWithFace = 0;
			grayTicks = 0;
			detectTicks = 0;
			drawTicks = 0;
			lastReport = now;
		}

		// VBlank beklenmiyor: kare beklemesi zaten döngüyü kamera hızına
		// bağlıyor, burada beklemek bir sonraki kareyi geciktirirdi.
		gfxFlushBuffers();
		if (gotFrame)
			gfxSwapBuffers();
	}

	camera_close();
	face_exit();
	gfxExit();
	return 0;
}
