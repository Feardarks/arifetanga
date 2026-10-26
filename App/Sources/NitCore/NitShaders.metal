#include <metal_stdlib>
using namespace metal;

// Swift tarafındaki `NitUniforms` ile birebir aynı düzen: yalnızca float4 alanlar.
struct NitUniforms {
    float4 yRange;   // yOffset, yScale, cOffset, cScale
    float4 ycc0;     // Y'CbCr → R'G'B' satırları
    float4 ycc1;
    float4 ycc2;
    float4 gam0;     // doğrusal kaynak RGB → doğrusal Display P3 satırları
    float4 gam1;
    float4 gam2;
    float4 curve;    // D, u_k, x_k, g
    float4 tone;     // H_eff, transfer (0 SDR, 1 PQ, 2 HLG, 3 DV P5), SDR gaması, 1 / L_ref
    float4 dither;   // açık (0/1), genlik, tohum, -
    float4 pattern;  // tür (0 = video), pencere oranı, seviye (nit ya da PQ kodu), pencere merkezi x
    float4 scaler;   // kalite (0 bilineer, 1 kaliteli), ölçek (hedef/kaynak), 1/hedef genişlik, 1/hedef yükseklik
};

// Dolby Vision P5 (S2.4): Swift'teki `DolbyVisionReshape.packed` ile birebir aynı düzen (184 × float4).
struct DoviComponent {
    float4 pivots[2];   // iç pivotlar (en çok 7), kalanı 1e9
    float4 coeffs[8];   // parça başına: polinom (a0, a1, a2, 0) ya da MMR (sabit, yuva, 0, derece)
    float4 range;       // giriş alt / üst sınırı (ilk ve son pivot)
};

struct DoviParams {
    DoviComponent comp[3];
    float4 nonlinear[3];  // IPT → L'M'S' satırları; .w = −satır · ofset
    float4 linear[3];     // LMS → doğrusal BT.2020 satırları
    float4 info;          // doku örneği → kod / 2^bit çarpanı
    float4 mmr[3][48];    // derece başına (x, y, z, 0) ve (xy, xz, yz, xyz)
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

// Tek üçgenle tam ekran.
vertex VOut nitVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float pqEOTF(float e) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = 2413.0 / 4096.0 * 32.0;
    const float c3 = 2392.0 / 4096.0 * 32.0;
    float ep = pow(max(e, 0.0), 1.0 / m2);
    return 10000.0 * pow(max(ep - c1, 0.0) / (c2 - c3 * ep), 1.0 / m1);
}

// DV P5 (IPTPQc2) → doğrusal BT.2020, nit. libplacebo `pl_shader_dovi_reshape` + DOLBYVISION kod çözümü:
// her bileşen kendi pivot aralığına kırpılır, parça polinom ya da MMR'dir (MMR üç bileşeni de okur),
// sonra IPT → L'M'S' → PQ EOTF → LMS → BT.2020. Başvuru: NitMath `DolbyVisionReshape.decode`.
static float3 doviDecode(float3 sample, constant DoviParams &dv) {
    float3 lo = float3(dv.comp[0].range.x, dv.comp[1].range.x, dv.comp[2].range.x);
    float3 hi = float3(dv.comp[0].range.y, dv.comp[1].range.y, dv.comp[2].range.y);
    float3 sig = clamp(sample * dv.info.x, lo, hi);
    float4 sigX = float4(sig.xxy * sig.yzz, sig.x * sig.y * sig.z);
    float3 ipt = float3(0.0);
    for (int c = 0; c < 3; c++) {
        float s = sig[c];
        // Pivotlar sıralı: s'ye eşit ya da küçük iç pivot sayısı parça indeksidir.
        float4 below0 = select(float4(0.0), float4(1.0), float4(s) >= dv.comp[c].pivots[0]);
        float4 below1 = select(float4(0.0), float4(1.0), float4(s) >= dv.comp[c].pivots[1]);
        int piece = min(int(dot(below0, float4(1.0)) + dot(below1, float4(1.0))), 7);
        float4 k = dv.comp[c].coeffs[piece];
        float r;
        if (k.w == 0.0) {
            r = (k.z * s + k.y) * s + k.x;
        } else {
            int m = int(k.y);
            r = k.x + dot(dv.mmr[c][m].xyz, sig) + dot(dv.mmr[c][m + 1], sigX);
            if (k.w >= 2.0) {
                float3 sig2 = sig * sig;
                float4 sigX2 = sigX * sigX;
                r += dot(dv.mmr[c][m + 2].xyz, sig2) + dot(dv.mmr[c][m + 3], sigX2);
                if (k.w >= 3.0) {
                    r += dot(dv.mmr[c][m + 4].xyz, sig2 * sig) + dot(dv.mmr[c][m + 5], sigX2 * sigX);
                }
            }
        }
        ipt[c] = clamp(r, 0.0, 1.0);
    }
    float3 lmsSignal = clamp(float3(dot(dv.nonlinear[0].xyz, ipt) + dv.nonlinear[0].w,
                                    dot(dv.nonlinear[1].xyz, ipt) + dv.nonlinear[1].w,
                                    dot(dv.nonlinear[2].xyz, ipt) + dv.nonlinear[2].w), float3(0.0), float3(1.0));
    float3 lms = float3(pqEOTF(lmsSignal.x), pqEOTF(lmsSignal.y), pqEOTF(lmsSignal.z));
    return float3(dot(dv.linear[0].xyz, lms), dot(dv.linear[1].xyz, lms), dot(dv.linear[2].xyz, lms));
}

static float hlgInverseOETF(float e) {
    const float a = 0.17883277;
    const float b = 1.0 - 4.0 * a;
    const float c = 0.5 - a * log(4.0 * a);
    e = max(e, 0.0);
    return e <= 0.5 ? e * e / 3.0 : (exp((e - c) / a) + b) / 12.0;
}

// Sinyal → doğrusal ışık. SDR: beyaz-göreli. PQ/HLG: mutlak nit.
static float3 decodeTransfer(float3 s, int tf, float gamma) {
    if (tf == 1) {
        return float3(pqEOTF(s.r), pqEOTF(s.g), pqEOTF(s.b));
    }
    if (tf == 2) {
        float3 scene = float3(hlgInverseOETF(s.r), hlgInverseOETF(s.g), hlgInverseOETF(s.b));
        float ys = dot(float3(0.2627, 0.6780, 0.0593), scene);
        return scene * (1000.0 * pow(max(ys, 1e-6), 0.2));
    }
    return pow(max(s, float3(0.0)), float3(gamma));
}

// Nit eğrisi (02-cozum §3.5): doğrusal bölge + log uzayında üstel omuz; çıkış < 1.
static float nitCurve(float x, float4 c) {
    if (x <= c.z) {
        return c.w * x;
    }
    return exp2(-c.x * exp(-(log2(x) - c.y) / c.x));
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Desenler: (sinyal, HDR mi) üretir. HDR ise değer mutlak nit, SDR ise sinyal.
static float3 patternSignal(float2 uv, float4 pat, thread bool &isHDR) {
    int kind = int(pat.x);
    float half_ = 0.5 * sqrt(clamp(pat.y, 0.0, 1.0));
    bool inside = abs(uv.x - pat.w) <= half_ && abs(uv.y - 0.5) <= half_;
    switch (kind) {
        case 1: // SDR beyaz pencere
            isHDR = false;
            return float3(inside ? 1.0 : 0.0);
        case 2: // PQ beyaz pencere, seviye nit cinsinden
            isHDR = true;
            return float3(inside ? pat.z : 0.0);
        case 3: // ince rampa: SDR sinyali 0,45 → 0,55, sürekli
            isHDR = false;
            return float3(mix(0.45, 0.55, uv.x));
        case 4: // karanlık rampa: SDR sinyali 0 → 0,15, sürekli
            isHDR = false;
            return float3(mix(0.0, 0.15, uv.x));
        case 5: // SDR gri rampa, 16 basamak
            isHDR = false;
            return float3(floor(uv.x * 16.0) / 15.0);
        case 6: // okunabilirlik: tam alan PQ 10000 nit
            isHDR = true;
            return float3(10000.0);
        default:
            isHDR = false;
            return float3(0.0);
    }
}

// Catmull-Rom bicubic, 9 bilineer örnekle (büyütme için).
static float sampleCatmullRom(texture2d<float> tex, sampler s, float2 uv) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 pos = uv * size;
    float2 p1 = floor(pos - 0.5) + 0.5;
    float2 f = pos - p1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (p1 - 1.0) / size;
    float2 t12 = (p1 + w2 / w12) / size;
    float2 t3 = (p1 + 2.0) / size;
    float r = 0.0;
    r += tex.sample(s, float2(t0.x, t0.y)).r * w0.x * w0.y;
    r += tex.sample(s, float2(t12.x, t0.y)).r * w12.x * w0.y;
    r += tex.sample(s, float2(t3.x, t0.y)).r * w3.x * w0.y;
    r += tex.sample(s, float2(t0.x, t12.y)).r * w0.x * w12.y;
    r += tex.sample(s, float2(t12.x, t12.y)).r * w12.x * w12.y;
    r += tex.sample(s, float2(t3.x, t12.y)).r * w3.x * w12.y;
    r += tex.sample(s, float2(t0.x, t3.y)).r * w0.x * w3.y;
    r += tex.sample(s, float2(t12.x, t3.y)).r * w12.x * w3.y;
    r += tex.sample(s, float2(t3.x, t3.y)).r * w3.x * w3.y;
    return r;
}

// Parlaklık (Y') örneklemesi: büyütmede bicubic, küçültmede (4K → 1125p) 2×2 süper örnekleme.
static float sampleLuma(texture2d<float> tex, sampler s, float2 uv, float4 sc) {
    if (sc.x < 0.5) {
        return tex.sample(s, uv).r;
    }
    if (sc.y >= 1.0) {
        return sampleCatmullRom(tex, s, uv);
    }
    float2 d = 0.25 * sc.zw;
    return 0.25 * (tex.sample(s, uv + float2(-d.x, -d.y)).r + tex.sample(s, uv + float2(d.x, -d.y)).r
                 + tex.sample(s, uv + float2(-d.x, d.y)).r + tex.sample(s, uv + float2(d.x, d.y)).r);
}

fragment float4 nitFragment(VOut in [[stage_in]],
                            texture2d<float> lumaTex [[texture(0)]],
                            texture2d<float> chromaTex [[texture(1)]],
                            constant NitUniforms &u [[buffer(0)]],
                            constant DoviParams &dv [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Referans yaması (eşitlik testi): PQ renk uzaylı katmana PQ kodu doğrudan yazılır,
    // ton eşlemeyi sistem yapar. Nit eğrisi uygulanmaz.
    if (int(u.pattern.x) == 7) {
        float half_ = 0.5 * sqrt(clamp(u.pattern.y, 0.0, 1.0));
        bool inside = abs(in.uv.x - u.pattern.w) <= half_ && abs(in.uv.y - 0.5) <= half_;
        return float4(float3(inside ? u.pattern.z : 0.0), 1.0);
    }

    int tf = int(u.tone.y);
    bool isHDR = tf != 0;
    float3 lin;

    if (u.pattern.x < 0.5) {
        float y = sampleLuma(lumaTex, s, in.uv, u.scaler);
        float2 c = chromaTex.sample(s, in.uv).rg;
        if (tf == 3) {
            // DV P5: doğrudan doğrusal BT.2020 (nit).
            lin = doviDecode(float3(y, c), dv);
        } else {
            float3 ycc = float3((y - u.yRange.x) * u.yRange.y,
                                (c.x - u.yRange.z) * u.yRange.w,
                                (c.y - u.yRange.z) * u.yRange.w);
            float3 rgbSignal = clamp(float3(dot(u.ycc0.xyz, ycc), dot(u.ycc1.xyz, ycc), dot(u.ycc2.xyz, ycc)), float3(0.0), float3(1.0));
            lin = decodeTransfer(rgbSignal, tf, u.tone.z);
        }
    } else {
        float3 sig = patternSignal(in.uv, u.pattern, isHDR);
        lin = isHDR ? sig : pow(max(sig, float3(0.0)), float3(u.tone.z));
    }

    // HDR: mutlak nit → beyaz-göreli (L_ref = 1).
    if (isHDR) {
        lin *= u.tone.w;
    }

    // Gamut: kaynak primerleri → Display P3 (doğrusal). Gamut dışı negatifler kırpılır.
    float3 p3 = max(float3(dot(u.gam0.xyz, lin), dot(u.gam1.xyz, lin), dot(u.gam2.xyz, lin)), float3(0.0));

    float H = u.tone.x;
    float3 outc;
    if (!isHDR) {
        outc = min(p3, float3(1.0)) * H;          // SDR: beyaz = H
    } else {
        float m = max(p3.r, max(p3.g, p3.b));
        outc = m > 0.0 ? p3 * (H * nitCurve(m, u.curve) / m) : float3(0.0);
    }

    // Çıkış titreşimi (AS-33): üçgen dağılımlı, değere orantılı ±1 LSB.
    if (u.dither.x > 0.5) {
        float2 p = in.position.xy + u.dither.z;
        float n = hash12(p) + hash12(p + 17.31) - 1.0;
        outc *= 1.0 + n * u.dither.y;
    }

    return float4(min(outc, float3(H)), 1.0);
}

static float pqInverseEOTF(float nits) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = 2413.0 / 4096.0 * 32.0;
    const float c3 = 2392.0 / 4096.0 * 32.0;
    float y = pow(max(nits, 0.0) / 10000.0, m1);
    return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
}

// Sahne beyazı histogramı (02-cozum §3.5.1): ekrandaki video alanının 1/4 çözünürlüğünde,
// piksel başına maxRGB'nin PQ kodu, 256 kutu. HDR10'da R'G'B' zaten PQ'dur (PQ monoton:
// max(R',G',B') = PQ(maxRGB)); HLG önce nite, sonra PQ'ya çevrilir. Kaynak kod değerlerinden
// hesaplanır, çıkıştan değil; bu yüzden headroom ile geri besleme kurulamaz.
kernel void nitHistogram(texture2d<float> lumaTex [[texture(0)]],
                         texture2d<float> chromaTex [[texture(1)]],
                         constant NitUniforms &u [[buffer(0)]],
                         device atomic_uint *hist [[buffer(1)]],
                         constant DoviParams &dv [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 grid [[threads_per_grid]],
                         uint lid [[thread_index_in_threadgroup]],
                         uint2 tgSize [[threads_per_threadgroup]]) {
    threadgroup atomic_uint local[256];
    uint count = tgSize.x * tgSize.y;
    for (uint i = lid; i < 256; i += count) {
        atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(grid);
    float y = lumaTex.sample(s, uv).r;
    float2 c = chromaTex.sample(s, uv).rg;
    float3 ycc = float3((y - u.yRange.x) * u.yRange.y,
                        (c.x - u.yRange.z) * u.yRange.w,
                        (c.y - u.yRange.z) * u.yRange.w);
    float3 sig = clamp(float3(dot(u.ycc0.xyz, ycc), dot(u.ycc1.xyz, ycc), dot(u.ycc2.xyz, ycc)), float3(0.0), float3(1.0));
    float pq;
    if (int(u.tone.y) == 3) {
        float3 nits = max(doviDecode(float3(y, c), dv), float3(0.0));
        pq = pqInverseEOTF(max(nits.r, max(nits.g, nits.b)));
    } else if (int(u.tone.y) == 2) {
        float3 nits = decodeTransfer(sig, 2, 1.0);
        pq = pqInverseEOTF(max(nits.r, max(nits.g, nits.b)));
    } else {
        pq = max(sig.r, max(sig.g, sig.b));
    }
    uint bin = min(uint(pq * 256.0), 255u);
    atomic_fetch_add_explicit(&local[bin], 1u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = lid; i < 256; i += count) {
        uint v = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (v > 0) {
            atomic_fetch_add_explicit(&hist[i], v, memory_order_relaxed);
        }
    }
}
