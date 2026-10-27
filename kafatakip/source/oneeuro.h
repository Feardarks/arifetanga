#pragma once

#include <stdbool.h>

// One-Euro filtresi: yavaş harekette titremeyi keser, hızlı harekette
// gecikmeyi azaltır. https://gery.casiez.net/1euro/
typedef struct {
	float minCutoff; // Hz; düşük = daha az titreme, daha çok gecikme
	float beta;      // hız arttıkça kesme frekansını ne kadar artıracağı
	float dCutoff;   // türev için kesme frekansı (Hz)
	float x;
	float dx;
	bool initialized;
} OneEuro;

void oneeuro_init(OneEuro* f, float minCutoff, float beta, float dCutoff);
void oneeuro_reset(OneEuro* f);

// dt saniye cinsinden.
float oneeuro_filter(OneEuro* f, float x, float dt);
