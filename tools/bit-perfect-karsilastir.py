#!/usr/bin/env python3
"""AS-11 (S6): bit-perfect loopback karşılaştırması.

DAC'ın dijital çıkışından (S/PDIF/USB) bilgisayarda kaydedilen sesi kaynak dosyayla bit bit karşılaştırır.
Her iki dosya ffmpeg ile 32 bit tamsayıya (s32le, sola yaslı) çözülür; böylece 16 bitlik bir kaynak 24 bitlik
bir kayıtla da doğrudan karşılaştırılabilir. Kaydın başındaki sessizlik ve gecikme kendiliğinden bulunur
(kaynağın ilk sessiz olmayan 64 karesi kayıtta birebir aranır; ters polarite de denenir).

Kullanım:
    python3 tools/bit-perfect-karsilastir.py kaynak.flac kayit.wav [--ara-saniye 30]

Çıkış kodu: 0 bit-perfect, 1 değil, 2 hata. Gerekenler: python3 ve PATH'te ffmpeg/ffprobe.
"""

import argparse
import json
import subprocess
import sys
from array import array

FRAME_ANCHOR = 64
CHUNK_FRAMES = 1 << 16


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
         "stream=codec_name,sample_rate,channels,bits_per_raw_sample,bits_per_sample,sample_fmt",
         "-of", "json", path],
        capture_output=True, text=True, check=True)
    streams = json.loads(out.stdout).get("streams", [])
    if not streams:
        raise SystemExit(f"Ses izi yok: {path}")
    s = streams[0]
    bits = int(s.get("bits_per_raw_sample") or 0) or int(s.get("bits_per_sample") or 0)
    return {"codec": s.get("codec_name", "?"), "rate": int(s["sample_rate"]), "channels": int(s["channels"]),
            "bits": bits}


def decoder(path):
    return subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0", "-f", "s32le", "-"],
                            stdout=subprocess.PIPE)


def read_frames(proc, frames, frame_bytes):
    """En çok `frames` kare okur (dosya sonunda daha az)."""
    want = frames * frame_bytes
    chunks = []
    while want > 0:
        data = proc.stdout.read(want)
        if not data:
            break
        chunks.append(data)
        want -= len(data)
    return b"".join(chunks)


def negate(data):
    values = array("i")
    values.frombytes(data)
    return array("i", (-v if v != -2147483648 else 2147483647 for v in values)).tobytes()


def find_aligned(haystack, needle, frame_bytes):
    """`needle`'ın kare sınırına hizalı ilk konumu (kare cinsinden); yoksa None."""
    start = 0
    while True:
        index = haystack.find(needle, start)
        if index < 0:
            return None
        if index % frame_bytes == 0:
            return index // frame_bytes
        start = index + 1


def main():
    parser = argparse.ArgumentParser(description="Bit-perfect loopback karşılaştırması (AS-11)")
    parser.add_argument("kaynak")
    parser.add_argument("kayit")
    parser.add_argument("--ara-saniye", type=float, default=30, help="kaydın başında hizalama aranacak süre (s)")
    args = parser.parse_args()

    src = probe(args.kaynak)
    rec = probe(args.kayit)
    print(f"Kaynak: {src['bits'] or '?'} bit · {src['rate']} Hz · {src['channels']} kanal · {src['codec']}")
    print(f"Kayıt:  {rec['bits'] or '?'} bit · {rec['rate']} Hz · {rec['channels']} kanal · {rec['codec']}")
    if src["rate"] != rec["rate"]:
        print(f"SONUÇ: BİT-PERFECT DEĞİL ✗ — örnekleme hızı farklı ({src['rate']} → {rec['rate']} Hz: yeniden örnekleme)")
        return 1
    if src["channels"] != rec["channels"]:
        print(f"SONUÇ: karşılaştırılamaz — kanal sayısı farklı ({src['channels']} / {rec['channels']})")
        return 2
    if rec["bits"] and src["bits"] and rec["bits"] < src["bits"]:
        print(f"Uyarı: kayıt {rec['bits']} bit, kaynak {src['bits']} bit; kayıt alt bitleri kesmiş olabilir.")

    channels = src["channels"]
    frame_bytes = 4 * channels

    # 1. Hizalama: kaynağın ilk sessiz olmayan karesinden 64 kare, kaydın ilk N saniyesinde birebir aranır.
    source = decoder(args.kaynak)
    head = read_frames(source, src["rate"] * 10, frame_bytes)
    values = array("i")
    values.frombytes(head[: len(head) // 4 * 4])
    first = next((i // channels for i, v in enumerate(values) if v != 0), None)
    source.kill()
    if first is None or (len(head) // frame_bytes) - first < FRAME_ANCHOR:
        print("Hata: kaynağın ilk 10 saniyesi sessiz ya da çok kısa.")
        return 2
    anchor = head[first * frame_bytes:(first + FRAME_ANCHOR) * frame_bytes]

    recording = decoder(args.kayit)
    rec_head = read_frames(recording, int(rec["rate"] * args.ara_saniye), frame_bytes)
    recording.kill()
    polarity = 1
    position = find_aligned(rec_head, anchor, frame_bytes)
    if position is None:
        position = find_aligned(rec_head, negate(anchor), frame_bytes)
        polarity = -1
    if position is None:
        print(f"SONUÇ: BİT-PERFECT DEĞİL ✗ — kaynağın ilk {FRAME_ANCHOR} karesi kaydın ilk {args.ara_saniye:g} s'sinde "
              "birebir bulunamadı (ses seviyesi, DSP, dither ya da yeniden örnekleme).")
        return 1
    offset = position - first
    lag_ms = offset / src["rate"] * 1000
    print(f"Hizalama: kayıt kaynağa göre {offset:+d} kare ({lag_ms:+.1f} ms) kaymış; "
          f"polarite {'normal' if polarity == 1 else 'TERS'}")

    # 2. Akış hâlinde tam karşılaştırma (örtüşen bölüm).
    source = decoder(args.kaynak)
    recording = decoder(args.kayit)
    if offset > 0:
        read_frames(recording, offset, frame_bytes)
    elif offset < 0:
        read_frames(source, -offset, frame_bytes)
    compared = 0
    mismatched = 0
    first_mismatch = None
    max_diff = 0
    shift = 32 - (src["bits"] or 24)
    while True:
        a = read_frames(source, CHUNK_FRAMES, frame_bytes)
        b = read_frames(recording, CHUNK_FRAMES, frame_bytes)
        n = min(len(a), len(b)) // frame_bytes
        if n == 0:
            break
        a = a[:n * frame_bytes]
        b = b[:n * frame_bytes]
        if polarity == -1:
            b = negate(b)
        if a != b:
            x = array("i")
            x.frombytes(a)
            y = array("i")
            y.frombytes(b)
            for i, (u, v) in enumerate(zip(x, y)):
                if u != v:
                    mismatched += 1
                    if first_mismatch is None:
                        first_mismatch = compared + i // channels
                    max_diff = max(max_diff, abs(u - v) >> shift)
        compared += n
    source.kill()
    recording.kill()

    seconds = compared / src["rate"]
    print(f"Karşılaştırılan: {compared} kare ({seconds:.1f} s) · farklı örnek: {mismatched}")
    if compared == 0:
        print("Hata: örtüşen bölüm yok.")
        return 2
    if mismatched == 0:
        print("SONUÇ: BİT-PERFECT ✓" + ("" if polarity == 1 else " (polarite ters; değerler birebir)"))
        return 0
    when = first_mismatch / src["rate"]
    print(f"İlk fark: kare {first_mismatch} ({when:.3f} s) · en büyük fark: {max_diff} LSB ({src['bits'] or '?'} bit)")
    print("SONUÇ: BİT-PERFECT DEĞİL ✗")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except FileNotFoundError as error:
        print(f"Hata: {error.filename} bulunamadı (ffmpeg/ffprobe PATH'te mi?)")
        sys.exit(2)
    except subprocess.CalledProcessError as error:
        print(f"Hata: ffprobe çalışmadı: {error}")
        sys.exit(2)
