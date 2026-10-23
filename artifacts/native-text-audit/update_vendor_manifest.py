"""Update only owned vendor entries, preserving inherited debt exactly."""
import hashlib
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
previous=json.loads((HERE.parent/'native-text-glyphs/vendor-manifest-audit.json').read_text())
files=['source/aurora/text/hinter.d','source/aurora/text/truetype.d','source/aurora/text/rasterizer.d','docs/FONTS.md']
manifest=CORE/'MANIFEST.sha256';backup=HERE/'before-source/MANIFEST.sha256'
if not backup.exists():backup.write_bytes(manifest.read_bytes())
entries={p:digest for digest,p in (line.split('  ',1) for line in manifest.read_text().splitlines() if line)}
for name in files:entries[name]=hashlib.sha256((CORE/name).read_bytes()).hexdigest()
remaining=[]
for name,digest in entries.items():
    actual=hashlib.sha256((CORE/name).read_bytes()).hexdigest()
    if actual!=digest:remaining.append({'file':name,'recorded':digest,'actual':actual})
inherited=json.loads((HERE/'inherited-vendor-debt.json').read_text())
assert sorted(remaining,key=lambda r:r['file'])==sorted(inherited['mismatches'],key=lambda r:r['file']),remaining
manifest.write_text(''.join(f'{digest}  {name}\n' for name,digest in sorted(entries.items())),encoding='utf-8')
(HERE/'vendor-manifest-audit.json').write_text(json.dumps({'updated':files,'updated_files_verified':True,
    'unrelated_preexisting_mismatches':remaining,'inherited_baseline':inherited,
    'preexisting_debt_in_touched_Vulkan_file':previous['preexisting_debt_in_touched_Vulkan_file'],
    'debt_note':previous['debt_note']},indent=2))
print('4 owned vendor entries updated; unrelated debt unchanged')
