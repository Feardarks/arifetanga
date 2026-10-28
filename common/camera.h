#pragma once

#include <3ds.h>

// Ön kamera 160x120 (QQVGA), RGB565 çıktı.
#define CAM_W 160
#define CAM_H 120

// Ön kamerayı açar ve yakalamayı başlatır.
Result camera_open(void);

// Yeni bir kare gelene kadar en fazla timeout_ns bekler.
// Yeni kare geldiyse true döner; kare camera_frame() ile okunur.
bool camera_wait_frame(u64 timeout_ns);

// Son alınan kare (CAM_W * CAM_H piksel, RGB565).
const u16* camera_frame(void);

void camera_close(void);
