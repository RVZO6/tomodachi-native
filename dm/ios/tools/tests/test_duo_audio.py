# 使用合成音訊驗證解碼器，不讀取或攜帶遊戲資料。
# Test the decoder with synthetic audio, without reading or carrying game data.
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location('duo_audio', Path(__file__).parents[1] / 'duo_audio.py')
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


def bwav(codec=0, channels=1, count=4, payload=None, start=0, end=-1):
    header = bytearray(16 + channels * 0x4c)
    header[:8] = b'BWAV\xff\xfe\x01\x00'
    struct.pack_into('<HH', header, 12, 0, channels)
    payload = payload if payload is not None else struct.pack('<4h', -32768, -1, 1, 32767)
    for c in range(channels):
        p = 16 + c * 0x4c
        struct.pack_into('<HHIII', header, p, codec, c, 48000, count, count)
        struct.pack_into('<I', header, p + 0x34, len(header) + c * len(payload))
        struct.pack_into('<ii', header, p + 0x3c, end, start)
    return bytes(header) + payload * channels


class DecodeTests(unittest.TestCase):
    def test_pcm(self):
        rate, channels, start, end, pcm = audio.decode_bwav(bwav())
        self.assertEqual((rate, channels, start, end), (48000, 1, 0, -1))
        self.assertEqual(list(pcm), [-32768, -1, 1, 32767])

    def test_stereo_interleave(self):
        *_, pcm = audio.decode_bwav(bwav(channels=2))
        self.assertEqual(list(pcm), [-32768, -32768, -1, -1, 1, 1, 32767, 32767])

    def test_adpcm_partial_frame(self):
        *_, pcm = audio.decode_bwav(bwav(codec=1, count=3, payload=bytes([0, 0x17, 0x80])))
        self.assertEqual(list(pcm), [1, 7, -8])

    def test_adpcm_history_and_clamp(self):
        data = bytearray(bwav(codec=1, count=3, payload=bytes([0, 0, 0])))
        struct.pack_into('<hh', data, 16 + 0x10, 2048, 2048)
        struct.pack_into('<hh', data, 16 + 0x46, 20000, 20000)
        *_, pcm = audio.decode_bwav(data)
        self.assertEqual(list(pcm), [32767] * 3)

    def test_bad_predictor(self):
        with self.assertRaises(ValueError):
            audio.decode_bwav(bwav(codec=1, count=1, payload=bytes([0x80, 0])))

    def test_invalid_inputs(self):
        for data in (b'', bwav()[:-1], bwav(start=4, end=2), bwav(codec=9)):
            with self.subTest(data=data[:16]), self.assertRaises((ValueError, struct.error)):
                audio.decode_bwav(data)

    def test_archive_member(self):
        name = b'SE_UI_Cursor'
        metadata = bytearray(16)
        metadata[:4] = b'AMTA'
        metadata += name + b'\0'
        struct.pack_into('<I', metadata, 8, len(metadata))
        data = bytearray(28)
        data[:4] = b'BARS'
        data[8:10] = b'\xff\xfe'
        struct.pack_into('<I', data, 12, 1)
        struct.pack_into('<II', data, 20, len(data), len(data) + len(metadata))
        data += metadata + bwav()
        struct.pack_into('<I', data, 4, len(data))
        self.assertEqual(audio.bars_wave(data, name.decode()), bwav())
        with self.assertRaises(ValueError):
            audio.bars_wave(data, 'Cursor')

    def test_extract_loop_and_remove_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'music.bwav').write_bytes(bwav(start=1, end=3))
            manifest = root / 'menu_audio.tsv'
            manifest.write_text('music\tmusic.bwav\t-\n')
            out = root / 'out'
            audio.extract(root, manifest, out)
            with wave.open(str(out / 'menu_music.wav')) as wav:
                self.assertEqual(wav.getnframes(), 2)
                self.assertEqual(wav.readframes(2), struct.pack('<hh', -1, 1))
            manifest.write_text('music\tmissing.bwav\t-\n')
            audio.extract(root, manifest, out)
            self.assertFalse((out / 'menu_music.wav').exists())


if __name__ == '__main__':
    unittest.main()
