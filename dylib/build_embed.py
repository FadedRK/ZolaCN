from pathlib import Path
import base64
import zlib

root = Path(__file__).resolve().parent.parent
plist = root / 'Translations.plist'
out = Path(__file__).resolve().parent / 'TranslationsData.m'

data = plist.read_bytes()
compressed = zlib.compress(data, 9)
b64 = base64.b64encode(compressed).decode('ascii')
chunks = [b64[i:i+120] for i in range(0, len(b64), 120)]

with out.open('w', encoding='utf-8') as f:
    f.write('// Auto-generated. Do not edit.\n')
    f.write('#include <Foundation/Foundation.h>\n\n')
    f.write('const unsigned char ZLCNTranslationsZlib[] =\n')
    for chunk in chunks:
        f.write('"' + chunk + '"\n')
    f.write(';\n')
    f.write('const unsigned long ZLCNTranslationsZlibLength = sizeof(ZLCNTranslationsZlib) - 1;\n')

print(f'Embedded {len(data)} bytes -> {len(compressed)} compressed bytes')
