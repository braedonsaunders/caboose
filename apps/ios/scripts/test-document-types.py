#!/usr/bin/env python3
import importlib.util
import json
import plistlib
import subprocess
import sys
from pathlib import Path

script = Path(__file__).with_name('document-types.py')
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('document_types', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
catalog = json.loads(module.CATALOG.read_text())
assert plistlib.loads(module.SNAPSHOT.read_bytes()) == module.declarations(catalog)
original = module.declarations(catalog)
catalog['apps'][0]['fileTypes']['extensions'].append('newtype')
changed = module.declarations(catalog)
assert changed != original
assert 'com.braedonsaunders.caboose.document.newtype' in changed['CFBundleDocumentTypes'][0]['LSItemContentTypes']
assert any('newtype' in item.get('UTTypeTagSpecification', {}).get('public.filename-extension', []) for item in changed['UTImportedTypeDeclarations'])
subprocess.run([sys.executable, str(script), '--check'], check=True)
print('Catalog document declarations and drift check passed')
