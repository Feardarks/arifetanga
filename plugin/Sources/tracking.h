#pragma once

#include <3ds.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	TRACK_STARTING = 0,
	TRACK_SEARCHING,
	TRACK_LOCKED,
	TRACK_PAUSED,
	TRACK_ERROR,
} TrackState;

typedef struct {
	TrackState state;
	Result error;   // TRACK_ERROR ise hata kodu
	float x, y, z;  // kafa konumu (cm, yumuşatılmış)
	float camFps;
	float detectMs; // kare başına ortalama algılama süresi
} TrackingStatus;

// Takip thread'ini başlatır (oyunla aynı çekirdekte, en düşük öncelikte).
bool tracking_start(void);

// Kamerayı bırakıp bekler / yeniden açar (HOME menüsü, uyku).
void tracking_pause(bool paused);

void tracking_stop(void);

void tracking_get(TrackingStatus* out);

// Teşhis günlüğüne bir satır yazar (main.cpp).
void kt_log(const char* text);

#ifdef __cplusplus
}
#endif
