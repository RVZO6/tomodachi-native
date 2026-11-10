#!/usr/bin/env python3
# 從本機遊戲資料解碼設定音樂與按鍵聲；不下載或提交音效。
# Decode settings music and button sounds from local game data; never download or commit audio.
import array
import json
from pathlib import Path
import struct
import subprocess
import sys
import wave


def decode_bwav(data):
    if data[:8] != b'BWAV\xff\xfe\x01\x00' or len(data) < 16:
        raise ValueError('unsupported BWAV header')
    prefetch, channels = struct.unpack_from('<HH', data, 12)
    if prefetch or not 1 <= channels <= 2:
        raise ValueError('prefetched or unsupported channel count')
    outputs = []
    common = None
    for channel in range(channels):
        p = 16 + channel * 0x4c
        codec, _, rate, full, count = struct.unpack_from('<HHIII', data, p)
        offset = struct.unpack_from('<I', data, p + 0x34)[0]
        end, start = struct.unpack_from('<ii', data, p + 0x3c)
        info = (rate, count, start, end)
        if full != count or not 8000 <= rate <= 192000 or not 0 < count <= rate * 600:
            raise ValueError('invalid or partial BWAV samples')
        if common is not None and info != common:
            raise ValueError('channel timing mismatch')
        common = info
        frames, tail = divmod(count, 14)
        size = count * 2 if codec == 0 else frames * 8 + (1 + (tail + 1) // 2 if tail else 0)
        if offset < 16 + channels * 0x4c or offset + size > len(data):
            raise ValueError('truncated BWAV samples')
        samples = array.array('h')
        if codec == 0:
            samples.frombytes(data[offset:offset + size])
            if sys.byteorder != 'little':
                samples.byteswap()
        elif codec == 1:
            coefficients = struct.unpack_from('<16h', data, p + 0x10)
            h1, h2 = struct.unpack_from('<hh', data, p + 0x46)
            for frame in range(offset, offset + size, 8):
                predictor, shift = data[frame] >> 4, data[frame] & 15
                if predictor > 7:
                    raise ValueError('invalid DSP predictor')
                c1, c2 = coefficients[2 * predictor:2 * predictor + 2]
                for i in range(min(14, count - len(samples))):
                    value = (data[frame + 1 + i // 2] >> (0 if i & 1 else 4)) & 15
                    if value >= 8:
                        value -= 16
                    value = ((value << shift) * 2048 + c1 * h1 + c2 * h2 + 1024) >> 11
                    value = max(-32768, min(32767, value))
                    samples.append(value)
                    h2, h1 = h1, value
        else:
            raise ValueError(f'unsupported BWAV codec {codec}')
        outputs.append(samples)
    if end != -1 and not 0 <= start < end <= count:
        raise ValueError('invalid loop points')
    pcm = array.array('h', (outputs[c][i] for i in range(count) for c in range(channels)))
    return rate, channels, start, end, pcm


def bars_wave(data, name):
    if data[:10] != b'BARS' + struct.pack('<I', len(data)) + b'\xff\xfe':
        raise ValueError('unsupported BARS header')
    count = struct.unpack_from('<I', data, 12)[0]
    if 16 + count * 12 > len(data):
        raise ValueError('truncated BARS table')
    for i in range(count):
        meta, audio = struct.unpack_from('<II', data, 16 + count * 4 + i * 8)
        if data[meta:meta + 4] != b'AMTA':
            raise ValueError('invalid BARS metadata')
        size = struct.unpack_from('<I', data, meta + 8)[0]
        if meta + size > len(data) or size < 16 or data[audio:audio + 4] != b'BWAV':
            raise ValueError('invalid BARS member')
        # 名稱前的二進位資料可能含零；用完整的結尾名稱比對。
        # Binary fields before the name can contain zeros; match the complete trailing name.
        if data[meta:meta + size].rstrip(b'\0').endswith(b'\0' + name.encode()):
            return data[audio:]
    raise ValueError(f'missing BARS sound {name}')


def extract(romfs, manifest, out):
    out.mkdir(parents=True, exist_ok=True)
    # 先清除舊產物，失敗時不會沿用別的版本的音效。
    # Clear old outputs first so failures cannot reuse audio from another version.
    for name in ('menu_music', 'menu_select', 'menu_confirm', 'menu_back'):
        (out / f'{name}.wav').unlink(missing_ok=True)
    (out / 'menu_audio.json').unlink(missing_ok=True)
    metadata = {}
    archives = {}
    for line in manifest.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        role, source, member = line.split('\t')
        if role not in ('music', 'select', 'confirm', 'back'):
            raise ValueError(f'unknown audio role {role}')
        try:
            if source not in archives:
                path = romfs / source
                archives[source] = subprocess.check_output(['zstd', '-dc', str(path)]) if source.endswith('.zs') else path.read_bytes()
            data = bars_wave(archives[source], member) if member != '-' else archives[source]
            rate, channels, start, end, pcm = decode_bwav(data)
            # 音樂只取原始循環區段；不拼接或混入其他曲目。
            # Music uses only its original loop region; never splice or mix other tracks.
            if role == 'music' and end != -1:
                pcm = pcm[start * channels:end * channels]
            if sys.byteorder != 'little':
                pcm.byteswap()
            with wave.open(str(out / f'menu_{role}.wav'), 'wb') as target:
                target.setparams((channels, 2, rate, 0, 'NONE', 'not compressed'))
                target.writeframes(pcm.tobytes())
            metadata[role] = {'source': source, 'member': member, 'loop_start': start, 'loop_end': end}
            print(f'duo_audio: {role}: {len(pcm) / channels / rate:.2f} s')
        except (OSError, ValueError, struct.error, subprocess.CalledProcessError) as error:
            print(f'duo_audio: {role} unavailable: {error}', file=sys.stderr)
    (out / 'menu_audio.json').write_text(json.dumps(metadata, indent=2) + '\n')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit('usage: duo_audio.py <RomFS> <profile/menu_audio.tsv> <output>')
    extract(*(Path(arg) for arg in sys.argv[1:]))
