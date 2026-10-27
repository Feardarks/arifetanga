#pragma once

#include <3ds.h>

// Üst ekranın fiziksel boyutu (cm). Old 3DS (3.53"). Old 3DS XL için
// yaklaşık 10.6 x 6.4.
#define SCREEN_W_CM 7.7f
#define SCREEN_H_CM 4.6f

// Ekranın arkasındaki "akvaryum" kutusunun derinliği (cm).
#define BOX_DEPTH_CM 12.0f

bool scene_init(void);

// Bir göz için sahneyi çizer. Göz konumu ekran merkezine göre cm cinsinden:
// x sağa, y yukarı, z ekrandan izleyiciye doğru (pozitif).
// timeSec, hareketli nesnelerin animasyonu için.
void scene_render_eye(float eyeX, float eyeY, float eyeZ, float timeSec);

void scene_exit(void);
