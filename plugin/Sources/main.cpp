// KafaTakip 3GX plugin'i.
//
// Oyunun içinde ön kamerayla kafayı takip eder, durumu oyun ekranının köşesine
// yazar ve istenirse kafa hareketini circle pad girdisine çevirir.
// Menü: oyun içinde SELECT (CTRPF varsayılanı).

#include <3ds.h>
#include <CTRPluginFramework.hpp>

#include <cmath>
#include <cstdio>

#include "tracking.h"

extern "C" vu32* hidSharedMem;

// Teşhis günlüğü: plugin'in hangi adımda kaldığını görmek için SD karta yazar.
// Ana thread ve takip thread'i birlikte yazabildiği için kilitli.
static const char* LOG_PATH = "/luma/plugins/kafatakip_log.txt";
static LightLock s_logLock;
static bool s_logReady;

static void LogInit(void)
{
	LightLock_Init(&s_logLock);
	CTRPluginFramework::File::Remove(LOG_PATH);
	s_logReady = true;
}

extern "C" void kt_log(const char* text)
{
	using CTRPluginFramework::File;
	if (!s_logReady)
		return;
	LightLock_Lock(&s_logLock);
	File f;
	if (File::Open(f, LOG_PATH, File::WRITE | File::CREATE | File::APPEND) == File::SUCCESS) {
		f.WriteLine(text);
		f.Close();
	}
	LightLock_Unlock(&s_logLock);
}

namespace CTRPluginFramework
{
	// Kafa -> circle pad eşlemesi (cm)
	static const float PAD_DEADZONE_CM = 1.0f;
	static const float PAD_FULL_CM = 5.0f;
	static const int PAD_MAX = 156;
	static const int PAD_KEY_THRESHOLD = 40; // bu değeri geçince yön tuşu biti de basılır

	static MenuEntry* s_osdEntry;
	static float s_centerX, s_centerY;
	static bool s_haveCenter;

	static bool DrawStatus(const Screen& screen)
	{
		if (!screen.IsTop || !s_osdEntry || !s_osdEntry->IsActivated())
			return false;

		TrackingStatus st;
		tracking_get(&st);

		char line[96];
		Color color = Color::White;
		switch (st.state) {
		case TRACK_LOCKED:
			snprintf(line, sizeof(line), "KafaTakip X%+5.1f Y%+5.1f Z%3.0f  %4.1ffps %4.1fms",
				st.x - (s_haveCenter ? s_centerX : 0.0f), st.y - (s_haveCenter ? s_centerY : 0.0f),
				st.z, st.camFps, st.detectMs);
			color = Color::LimeGreen;
			break;
		case TRACK_SEARCHING:
			snprintf(line, sizeof(line), "KafaTakip: yuz araniyor  %4.1ffps %4.1fms", st.camFps, st.detectMs);
			color = Color::Yellow;
			break;
		case TRACK_PAUSED:
			snprintf(line, sizeof(line), "KafaTakip: duraklatildi");
			break;
		case TRACK_ERROR:
			snprintf(line, sizeof(line), "KafaTakip: kamera acilamadi 0x%08lX", st.error);
			color = Color::Red;
			break;
		default:
			snprintf(line, sizeof(line), "KafaTakip: basliyor...");
			break;
		}

		screen.Draw(line, 4, 4, color, Color(0, 0, 0, 160));
		return true;
	}

	static int AxisFromHead(float d)
	{
		float mag = std::fabs(d);
		if (mag <= PAD_DEADZONE_CM)
			return 0;
		float t = (mag - PAD_DEADZONE_CM) / (PAD_FULL_CM - PAD_DEADZONE_CM);
		if (t > 1.0f)
			t = 1.0f;
		int v = (int)(t * PAD_MAX);
		return d < 0 ? -v : v;
	}

	// HID paylaşımlı belleğindeki 8 girişlik tuş halkasına circle pad değerini yazar.
	// Her giriş: [0] basılı tuşlar, [1] yeni basılan, [2] bırakılan, [3] circle pad (s16 x, s16 y).
	// HID modülü bunu birkaç ms'de bir yeniden yazdığı için oyunun okuma zamanına göre
	// bazı karelerde etkisiz kalabilir (CTRPF'in InjectKey'i ile aynı yöntem).
	static void InjectCirclePad(int x, int y)
	{
		u32 keys = 0;
		if (x > PAD_KEY_THRESHOLD) keys |= KEY_CPAD_RIGHT;
		if (x < -PAD_KEY_THRESHOLD) keys |= KEY_CPAD_LEFT;
		if (y > PAD_KEY_THRESHOLD) keys |= KEY_CPAD_UP;
		if (y < -PAD_KEY_THRESHOLD) keys |= KEY_CPAD_DOWN;

		u32 pad = (u32)(u16)(s16)x | ((u32)(u16)(s16)y << 16);
		for (int i = 0; i < 8; i++) {
			int j = 10 + i * 4;
			hidSharedMem[j] |= keys;
			hidSharedMem[j + 3] = pad;
		}
	}

	static void HeadToCirclePad(MenuEntry* entry)
	{
		TrackingStatus st;
		tracking_get(&st);
		if (st.state != TRACK_LOCKED)
			return;

		// İlk açılışta şu anki konum merkez olur.
		if (entry->WasJustActivated() || !s_haveCenter) {
			s_centerX = st.x;
			s_centerY = st.y;
			s_haveCenter = true;
		}

		InjectCirclePad(AxisFromHead(st.x - s_centerX), AxisFromHead(st.y - s_centerY));
	}

	// Durum yazısı girişi sadece aç/kapa anahtarı; çizimi DrawStatus yapar.
	static void OsdToggle(MenuEntry*)
	{
	}

	static void Recenter(MenuEntry*)
	{
		TrackingStatus st;
		tracking_get(&st);
		if (st.state != TRACK_LOCKED) {
			OSD::Notify("KafaTakip: yuz yok, merkez ayarlanamadi", Color::Red);
			return;
		}
		s_centerX = st.x;
		s_centerY = st.y;
		s_haveCenter = true;
		OSD::Notify("KafaTakip: merkez ayarlandi", Color::LimeGreen);
	}

	static void OnProcessEvent(Process::Event event)
	{
		switch (event) {
		case Process::Event::EXIT:
			tracking_stop();
			break;
		case Process::Event::HOME_ENTER:
		case Process::Event::SLEEP_ENTER:
		case Process::Event::SWAP_ENTER:
			tracking_pause(true);
			break;
		case Process::Event::HOME_EXIT:
		case Process::Event::SLEEP_EXIT:
		case Process::Event::SWAP_EXIT:
			tracking_pause(false);
			break;
		}
	}

	// main'den önce, oyun başlamadan çağrılır.
	void PatchProcess(FwkSettings&)
	{
		LogInit();
		kt_log("PatchProcess: plugin yuklendi");
	}

	int main(void)
	{
		kt_log("main: basladi");
		PluginMenu* menu = new PluginMenu("KafaTakip", 0, 1, 0,
			"On kamerayla kafa takibi.\n"
			"Durum yazisi oyun ekraninin sol ustunde.\n"
			"Kafa -> circle pad acikken kafani egerek yuru.");
		menu->SynchronizeWithFrame(true);

		s_osdEntry = new MenuEntry("Durum yazisi", OsdToggle, "Takip durumunu ust ekranda gosterir.");
		*menu += s_osdEntry;
#ifndef KAFATAKIP_MINIMAL
		*menu += new MenuEntry("Kafa -> circle pad", HeadToCirclePad,
			"Kafani saga/sola/yukari/asagi egince circle pad o yone itilir.\n"
			"Acildigi andaki kafa konumu merkez olur.");
		*menu += new MenuEntry("Merkezle", nullptr, Recenter, "Su anki kafa konumunu merkez yapar.");
#endif
		s_osdEntry->Enable();
		kt_log("main: menu olusturuldu");

#ifdef KAFATAKIP_MINIMAL
		// Test sürümü: kamera/takip yok, sadece plugin'in yüklenip menünün açıldığını gösterir.
		OSD::Notify("KafaTakip TEST yuklendi. Menu: SELECT", Color::LimeGreen);
#else
		Process::SetProcessEventCallback(OnProcessEvent);
		OSD::Run(DrawStatus);
		kt_log("main: OSD baglandi");

		if (!tracking_start()) {
			kt_log("main: takip thread'i baslatilamadi");
			OSD::Notify("KafaTakip: takip thread'i baslatilamadi", Color::Red);
		} else {
			kt_log("main: takip thread'i baslatildi");
			OSD::Notify("KafaTakip yuklendi. Menu: SELECT", Color::LimeGreen);
		}
#endif

		kt_log("main: menu calisiyor");
		menu->Run();

#ifndef KAFATAKIP_MINIMAL
		tracking_stop();
#endif
		kt_log("main: bitti");
		delete menu;
		return 0;
	}
}
