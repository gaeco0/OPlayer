"""Prepare verified sources before Dart's isolated native build hooks run."""
from pathlib import Path
from github_asset import download_asset

root = Path(__file__).resolve().parents[2]
download_asset(
    'Tencent/ncnn', 658173295,
    '699d9acc67489eee0993a551ca1ebc247bbf0f4e33babe1dec810e6a9a52b988',
    root / '.dart_tool/native-dependencies/ncnn-20261020-full-source.zip',
)
