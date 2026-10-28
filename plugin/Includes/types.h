#pragma once

// libctrpf paketinin genel başlıkları "types.h" bekliyor ama paket bu dosyayı
// içermiyor (CTRPF deposunda libctru'nun types.h'ının genişletilmiş bir
// kopyası). Tipleri libctru'dan al, eksik kalan makroları ekle.
#include <3ds/types.h>

#ifndef NORETURN
#define NORETURN __attribute__((noreturn))
#endif
