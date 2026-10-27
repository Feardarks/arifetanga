#pragma once

#include <stdbool.h>

#include "face.h"

// Kafanın (göz ortasının) ekran merkezine göre konumu, cm.
// x sağa, y yukarı, z ekrandan izleyiciye doğru.
typedef struct {
	float x, y, z;
} HeadPos;

// Kamera görüntüsündeki yüzden kafa konumunu hesaplar. Yüz genişliği cetvel
// olarak kullanılır: yatay/dikey kayma için kameranın görüş açısı gerekmez,
// sadece uzaklık (z) için gerekir.
HeadPos head_from_face(const Face* face, int camWidth, int camHeight, bool flipX, bool flipY);
