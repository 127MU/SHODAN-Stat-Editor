"""Build the embedded MiSans font from the user's ZIP. Requires fonttools.

Keep common Chinese, English/Latin and every character used by the editor or
shipped catalog. The UI falls back to system fonts for other user-entered text.
"""
import argparse
import gzip
import io
from pathlib import Path
import zipfile
from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('zip', type=Path)
    parser.add_argument('--catalog', type=Path, required=True)
    args = parser.parse_args()
    with zipfile.ZipFile(args.zip) as archive:
        font = TTFont(io.BytesIO(archive.read('MiSans/MiSans-Regular.ttf')))
    chars = set(range(0x20, 0x250)) | set(range(0x2000, 0x3100)) | set(range(0xFF00, 0xFFF0))
    for high in range(0xa1, 0xf8):
        for low in range(0xa1, 0xff):
            try:
                chars.update(map(ord, bytes([high, low]).decode('gb2312')))
            except UnicodeDecodeError:
                pass
    chars.update(map(ord, gzip.decompress(args.catalog.read_bytes()).decode('utf8')))
    for base in ('desktop/morrow/lib', 'rust/core/src'):
        for path in (ROOT/base).rglob('*'):
            if path.is_file() and path.suffix in ('.dart', '.rs', '.json'):
                chars.update(map(ord, path.read_text(encoding='utf8', errors='ignore')))
    options = subset.Options()
    options.hinting = False
    options.recalc_timestamp = False
    options.name_IDs = ['*']
    builder = subset.Subsetter(options=options)
    builder.populate(unicodes=chars)
    builder.subset(font)
    out = ROOT/'desktop/morrow/assets/fonts/MiSans-Regular.subset.ttf'
    out.parent.mkdir(parents=True, exist_ok=True)
    font.save(out)
    assert all(c in font.getBestCmap() for c in range(0x20, 0x7f))
    print(f'{len(font.getBestCmap())} characters; {out.stat().st_size} bytes')

if __name__ == '__main__':
    main()
