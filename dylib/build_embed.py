from pathlib import Path

root = Path(__file__).resolve().parent.parent
plist = root / 'Translations.plist'
out = Path(__file__).resolve().parent / 'TranslationsData.m'

data = plist.read_bytes()

# Embed the plist bytes directly. Avoid runtime zlib decompression entirely.
hex_bytes = [f'0x{b:02x}' for b in data]
chunks = [hex_bytes[i:i+24] for i in range(0, len(hex_bytes), 24)]

with out.open('w', encoding='utf-8') as f:
    f.write('// Auto-generated. Do not edit.\n')
    f.write('#include <Foundation/Foundation.h>\n\n')
    f.write('const unsigned char ZLCNTranslationsPlist[] = {\n')
    for chunk in chunks:
        f.write('    ' + ', '.join(chunk) + ',\n')
    f.write('};\n')
    f.write('const unsigned long ZLCNTranslationsPlistLength = sizeof(ZLCNTranslationsPlist);\n')

print(f'Embedded raw plist: {len(data)} bytes')
