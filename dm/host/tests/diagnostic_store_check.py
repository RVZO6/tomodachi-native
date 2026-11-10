#!/usr/bin/env python3
# 確認 ZIP CRC、說明、資料與不跟隨符號鏈接；測試資料自動清除。
# Check ZIP CRCs, notes, payload and symlink exclusion; automatically remove test data.
import json
import subprocess
import sys
import tempfile
import zipfile

with tempfile.TemporaryDirectory(prefix="diagnostic-store-") as root:
    result = subprocess.run([sys.argv[1], root], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Store test failed ({result.returncode}): {result.stderr}")
    with zipfile.ZipFile(result.stdout.strip()) as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert "Descriptions.txt" in names
        manifest = next(n for n in names if n.endswith("/report.json"))
        metadata = json.loads(archive.read(manifest))
        assert metadata["note"] == "Edited note / 聲音中斷"
        assert metadata["actual_history_seconds"] == 60
        assert not any(n.endswith("/thumbnail.jpg") for n in names)
        assert "聲音中斷" in archive.read("Descriptions.txt").decode()
        assert all(b"PRIVATE NOT FOR EXPORT" not in archive.read(n) for n in names)
    print("PASS diagnostic store: quota, edits, traversal, staging recovery, ZIP CRC, descriptions and symlinks")
