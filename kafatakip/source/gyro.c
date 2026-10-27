#include <math.h>
#include <string.h>

#include "gyro.h"

#define HISTORY_LEN 128 // ~2 s @ 60 Hz

// Öğrenme
#define RLS_FORGET       0.995f
#define RLS_INIT_P       1000.0f
#define MIN_EXCITATION   0.004f // rad; bundan az dönüşte örnek alınmaz
#define MIN_COEFF_NORM   0.3f   // beklenen ~1; bu aralık dışı = güvenilmez
#define MAX_COEFF_NORM   2.0f

// Sıfır kayması (bias) takibi
#define BIAS_INIT_FRAMES 30
#define BIAS_STILL_DPS   3.0f
#define BIAS_RATE        0.01f

typedef struct {
	u64 ms;
	float d[3];
} Sample;

static float s_coeff;
static float s_bias[3];
static int s_biasFrames;

static Sample s_hist[HISTORY_LEN];
static int s_histHead;

typedef struct {
	float w[3];
	float P[9];
} Rls;

static Rls s_yaw, s_pitch;
static int s_samples;

static void rls_init(Rls* r)
{
	memset(r, 0, sizeof(*r));
	for (int i = 0; i < 3; i++)
		r->P[i * 4] = RLS_INIT_P;
}

static float dot3(const float a[3], const float b[3])
{
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

static void rls_update(Rls* r, const float f[3], float target)
{
	float Pf[3];
	for (int i = 0; i < 3; i++)
		Pf[i] = r->P[i * 3 + 0] * f[0] + r->P[i * 3 + 1] * f[1] + r->P[i * 3 + 2] * f[2];

	float denom = RLS_FORGET + dot3(f, Pf);
	float k[3] = { Pf[0] / denom, Pf[1] / denom, Pf[2] / denom };

	float err = target - dot3(f, r->w);
	for (int i = 0; i < 3; i++)
		r->w[i] += k[i] * err;

	// P = (P - k * f^T * P) / lambda; P simetrik olduğundan f^T P = Pf^T
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			r->P[i * 3 + j] = (r->P[i * 3 + j] - k[i] * Pf[j]) / RLS_FORGET;
}

static float norm3(const float a[3])
{
	return sqrtf(dot3(a, a));
}

bool gyro_init(void)
{
	if (R_FAILED(HIDUSER_EnableGyroscope()))
		return false;
	if (R_FAILED(HIDUSER_GetGyroscopeRawToDpsCoefficient(&s_coeff)) || s_coeff == 0.0f)
		return false;

	memset(s_bias, 0, sizeof(s_bias));
	s_biasFrames = 0;
	memset(s_hist, 0, sizeof(s_hist));
	s_histHead = 0;
	rls_init(&s_yaw);
	rls_init(&s_pitch);
	s_samples = 0;
	return true;
}

void gyro_update(u64 nowMs, float dt, float outDelta[3])
{
	angularRate raw;
	hidGyroRead(&raw);
	float dps[3] = { raw.x * s_coeff, raw.y * s_coeff, raw.z * s_coeff };

	// Açılışta ilk kareler sabit kabul edilip ortalama alınır, sonra sadece
	// konsol durgunken yavaşça güncellenir.
	if (s_biasFrames < BIAS_INIT_FRAMES) {
		s_biasFrames++;
		for (int i = 0; i < 3; i++)
			s_bias[i] += (dps[i] - s_bias[i]) / s_biasFrames;
	} else {
		bool still = true;
		for (int i = 0; i < 3; i++)
			if (fabsf(dps[i] - s_bias[i]) > BIAS_STILL_DPS)
				still = false;
		if (still)
			for (int i = 0; i < 3; i++)
				s_bias[i] += (dps[i] - s_bias[i]) * BIAS_RATE;
	}

	Sample* s = &s_hist[s_histHead];
	s_histHead = (s_histHead + 1) % HISTORY_LEN;
	s->ms = nowMs;
	for (int i = 0; i < 3; i++) {
		float rad = (s_biasFrames < BIAS_INIT_FRAMES) ? 0.0f
			: (dps[i] - s_bias[i]) * (float)M_PI / 180.0f * dt;
		s->d[i] = rad;
		outDelta[i] = rad;
	}
}

void gyro_integral(u64 fromMs, u64 toMs, float out[3])
{
	out[0] = out[1] = out[2] = 0.0f;
	for (int i = 0; i < HISTORY_LEN; i++) {
		const Sample* s = &s_hist[i];
		if (s->ms > fromMs && s->ms <= toMs) {
			out[0] += s->d[0];
			out[1] += s->d[1];
			out[2] += s->d[2];
		}
	}
}

void gyro_head_shift(const float rot[3], float z, float* dx, float* dy)
{
	*dx = -z * dot3(rot, s_yaw.w);
	*dy = z * dot3(rot, s_pitch.w);
}

void gyro_learn(const float rot[3], float headDx, float headDy, float z)
{
	if (norm3(rot) < MIN_EXCITATION || z <= 0.0f)
		return;
	rls_update(&s_yaw, rot, -headDx / z);
	rls_update(&s_pitch, rot, headDy / z);
	s_samples++;
}

bool gyro_trained(void)
{
	if (s_samples < GYRO_MIN_SAMPLES)
		return false;
	float ny = norm3(s_yaw.w), np = norm3(s_pitch.w);
	return ny > MIN_COEFF_NORM && ny < MAX_COEFF_NORM
		&& np > MIN_COEFF_NORM && np < MAX_COEFF_NORM;
}

int gyro_samples(void)
{
	return s_samples;
}

void gyro_exit(void)
{
	HIDUSER_DisableGyroscope();
}
