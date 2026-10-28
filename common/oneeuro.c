#include <math.h>

#include "oneeuro.h"

static float smoothing_alpha(float cutoff, float dt)
{
	float tau = 1.0f / (2.0f * (float)M_PI * cutoff);
	return 1.0f / (1.0f + tau / dt);
}

void oneeuro_init(OneEuro* f, float minCutoff, float beta, float dCutoff)
{
	f->minCutoff = minCutoff;
	f->beta = beta;
	f->dCutoff = dCutoff;
	oneeuro_reset(f);
}

void oneeuro_reset(OneEuro* f)
{
	f->initialized = false;
}

float oneeuro_filter(OneEuro* f, float x, float dt)
{
	if (!f->initialized || dt <= 0.0f) {
		f->x = x;
		f->dx = 0.0f;
		f->initialized = true;
		return x;
	}

	float dx = (x - f->x) / dt;
	f->dx += smoothing_alpha(f->dCutoff, dt) * (dx - f->dx);

	float cutoff = f->minCutoff + f->beta * fabsf(f->dx);
	f->x += smoothing_alpha(cutoff, dt) * (x - f->x);
	return f->x;
}
