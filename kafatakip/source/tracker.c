#include "tracker.h"

// Bölge, son yüz boyutunun bu katı kadar kenar uzunluğunda bir kare.
// Kareler arası kafa hareketine pay bırakır.
#define REGION_SCALE 2.4f
// Bölge aramasında izin verilen boyut değişimi.
#define SIZE_MIN_RATIO 0.75f
#define SIZE_MAX_RATIO 1.35f

#define MAX_CANDIDATES 4

void tracker_init(Tracker* t)
{
	t->locked = false;
	t->lastWasFullScan = false;
}

bool tracker_update(Tracker* t, const u8* gray, int width, int height, float qthreshold)
{
	Face found[MAX_CANDIDATES];
	int n = 0;

	if (t->locked) {
		float side = t->face.size * REGION_SCALE;
		int rx = (int)(t->face.x - side / 2);
		int ry = (int)(t->face.y - side / 2);
		n = face_detect_region(gray, width, height, rx, ry, (int)side, (int)side,
			t->face.size * SIZE_MIN_RATIO, t->face.size * SIZE_MAX_RATIO,
			qthreshold, found, MAX_CANDIDATES);
		t->lastWasFullScan = false;
	}

	if (n == 0) {
		n = face_detect(gray, width, height, qthreshold, found, MAX_CANDIDATES);
		t->lastWasFullScan = true;
	}

	if (n == 0) {
		t->locked = false;
		return false;
	}

	// En güvenilir yüz (liste güvene göre sıralı).
	t->face = found[0];
	t->locked = true;
	return true;
}
