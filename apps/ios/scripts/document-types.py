#!/usr/bin/env python3
"""Generate the iOS document declarations from the repository catalog."""
import argparse
import json
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[3]
CATALOG = ROOT / 'guest/catalog/catalog.json'
SNAPSHOT = ROOT / 'apps/ios/Caboose/DocumentTypes.generated.plist'
BASE = ROOT / 'apps/ios/Caboose/Info.plist'
# Known extension aliases for types used by the catalog. Unknown extensions get a
# Caboose imported type, so an added catalog extension cannot silently disappear.
KNOWN = {
 'psd':'com.adobe.photoshop-image', 'png':'public.png', 'jpg':'public.jpeg', 'jpeg':'public.jpeg',
 'tif':'public.tiff', 'tiff':'public.tiff', 'webp':'org.webmproject.webp', 'gif':'com.compuserve.gif',
 'bmp':'com.microsoft.bmp', 'heic':'public.heic', 'heif':'public.heif', 'dng':'com.adobe.raw-image',
 'mp4':'public.mpeg-4', 'm4v':'com.apple.m4v-video', 'mov':'com.apple.quicktime-movie',
 'mkv':'org.matroska.mkv', 'webm':'org.webmproject.webm', 'avi':'public.avi', 'mpeg':'public.mpeg',
 'svg':'public.svg-image', 'ai':'com.adobe.illustrator.ai-image', 'pdf':'com.adobe.pdf', 'idml':'com.adobe.indesign-idml',
 'docx':'org.openxmlformats.wordprocessingml.document', 'doc':'com.microsoft.word.doc',
 'odt':'org.oasis-open.opendocument.text', 'rtf':'public.rtf', 'md':'net.daringfireball.markdown',
 'html':'public.html', 'txt':'public.plain-text', 'xlsx':'org.openxmlformats.spreadsheetml.sheet',
 'csv':'public.comma-separated-values-text', 'tsv':'public.tab-separated-values-text',
 'pptx':'org.openxmlformats.presentationml.presentation', 'dxf':'com.autodesk.dxf',
 'dwg':'com.autodesk.dwg', 'wav':'com.microsoft.waveform-audio', 'aiff':'public.aiff-audio',
 'flac':'org.xiph.flac', 'mp3':'public.mp3', 'mid':'public.midi-audio', 'epub':'org.idpf.epub-container',
}

def declarations(catalog):
    extensions = sorted({ext.lower() for app in catalog['apps'] for ext in app['fileTypes']['extensions']})
    types = {t for app in catalog['apps'] for t in app['fileTypes']['utTypes']}
    imports = {}
    for uti in types:
        if not uti.startswith(('public.', 'com.apple.')):
            aliases = [ext for ext in extensions if KNOWN.get(ext) == uti]
            imports[uti] = {'UTTypeIdentifier': uti, 'UTTypeConformsTo': ['public.data']}
            if aliases:
                imports[uti]['UTTypeTagSpecification'] = {'public.filename-extension': aliases}
    for ext in extensions:
        if not ext or not all(c.isascii() and (c.isalnum() or c in '_-') for c in ext):
            raise ValueError('Invalid catalog extension: ' + repr(ext))
        uti = KNOWN.get(ext, 'com.braedonsaunders.caboose.document.' + ext.replace('_', '-'))
        types.add(uti)
        if uti.startswith('com.braedonsaunders.caboose.document.'):
            imports[uti] = {'UTTypeIdentifier': uti, 'UTTypeDescription': ext.upper() + ' document',
                            'UTTypeConformsTo': ['public.data'], 'UTTypeTagSpecification': {'public.filename-extension': [ext]}}
    return {'CFBundleDocumentTypes': [{'CFBundleTypeName': 'Computer document', 'CFBundleTypeRole': 'Editor',
             'LSHandlerRank': 'Alternate', 'LSItemContentTypes': sorted(types)}],
            'UTImportedTypeDeclarations': [imports[t] for t in sorted(imports)],
            'LSSupportsOpeningDocumentsInPlace': True}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--write', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    generated = declarations(json.loads(CATALOG.read_text()))
    data = plistlib.dumps(generated, sort_keys=True)
    if args.write:
        SNAPSHOT.write_bytes(data)
    if args.check and (not SNAPSHOT.exists() or SNAPSHOT.read_bytes() != data):
        sys.exit('Document types have drifted from the catalog; run apps/ios/scripts/document-types.py --write')
    if args.output:
        base = plistlib.loads(BASE.read_bytes())
        base.update(generated)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(plistlib.dumps(base, sort_keys=True))
    if not (args.write or args.check or args.output):
        parser.error('pass --write, --check or --output')

if __name__ == '__main__':
    main()
