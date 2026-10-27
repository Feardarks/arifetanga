#include <stdlib.h>
#include <string.h>

#include "face.h"
#include "picornt.h"
#include "facefinder_bin.h"

// Kümelemeden önceki ham tespit sınırı. Küçük tutmak cluster_detections'ın
// özyineleme derinliğini de sınırlar.
#define MAX_RAW_DETECTIONS 256

// Pico arama ayarları (160x120 görüntü için).
#define SCALE_FACTOR  1.1f  // pencere boyutu her adımda bu oranla büyür
#define STRIDE_FACTOR 0.1f  // pencere kayma adımı = boyut * bu oran
#define MIN_SIZE      24.0f // piksel

static void* s_cascade;
static float s_rcsq[4 * MAX_RAW_DETECTIONS];

bool face_init(void)
{
	// Kaskat float/int alanları içeriyor; hizalı olması için ayrı belleğe kopyala.
	s_cascade = malloc(facefinder_bin_size);
	if (!s_cascade)
		return false;
	memcpy(s_cascade, facefinder_bin, facefinder_bin_size);
	return true;
}

int face_detect(const u8* gray, int width, int height, float qthreshold, Face* out, int maxOut)
{
	int n = find_objects(s_rcsq, MAX_RAW_DETECTIONS, s_cascade, 0.0f,
		(void*)gray, height, width, width,
		SCALE_FACTOR, STRIDE_FACTOR, MIN_SIZE, (float)height);
	n = cluster_detections(s_rcsq, n);

	int count = 0;
	for (int i = 0; i < n && count < maxOut; i++) {
		float q = s_rcsq[4 * i + 3];
		if (q < qthreshold)
			continue;

		// Güvene göre sıralı ekle.
		int j = count++;
		while (j > 0 && out[j - 1].q < q) {
			out[j] = out[j - 1];
			j--;
		}
		out[j].y = s_rcsq[4 * i + 0];
		out[j].x = s_rcsq[4 * i + 1];
		out[j].size = s_rcsq[4 * i + 2];
		out[j].q = q;
	}
	return count;
}

void face_exit(void)
{
	free(s_cascade);
	s_cascade = NULL;
}
