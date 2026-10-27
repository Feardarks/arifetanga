#pragma once

#include <3ds.h>

#include "face.h"

// Yüz takipçisi: yüz bulunduysa sonraki karelerde sadece onun çevresinde
// arar (hızlı); kaybederse tüm görüntüyü tarar.
typedef struct {
	bool locked;
	bool lastWasFullScan;
	Face face;
} Tracker;

void tracker_init(Tracker* t);

// Yeni gri karede yüzü günceller. Yüz bulunduysa true döner.
bool tracker_update(Tracker* t, const u8* gray, int width, int height, float qthreshold);
