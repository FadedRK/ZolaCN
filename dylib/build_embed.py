from pathlib import Path
import zlib

root = Path(__file__).resolve().parent.parent
plist = root / 'Translations.plist'
out = Path(__file__).resolve().parent / 'TranslationsData.m'

data = plist.read_bytes()
compressed = zlib.compress(data, 9)

# Emit the actual compressed bytes as a C byte array.
# The previous version emitted base64 text but the dylib treated it as
# raw zlib bytes, so decompression always failed and the translation count
# was 0 at runtime.
hex_bytes = [f'0x{b:02x}' for b in compressed]
chunks = [hex_bytes[i:i+24] for i in range(0, len(hex_bytes), 24)]

with out.open('w', encoding='utf-8') as f:
    f.write('// Auto-generated. Do not edit.\n')
    f.write('#include <Foundation/Foundation.h>\n\n')
    f.write('const unsigned char ZLCNTranslationsZlib[] = {\n')
    for chunk in chunks:
        f.write('    ' + ', '.join(chunk) + ',\n')
    f.write('};\n')
    f.write('const unsigned long ZLCNTranslationsZlibLength = sizeof(ZLCNTranslationsZlib);\n')

print(f'Embedded {len(data)} bytes -> {len(compressed)} compressed bytes')
