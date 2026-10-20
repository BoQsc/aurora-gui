"""Digest this refinement without altering the inherited vendor-debt ledger."""
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
previous=json.loads((HERE.parent/'native-text-refined/vendor-manifest-audit.json').read_text())
files=['source/aurora/text/hinter.d','source/aurora/text/truetype.d','docs/FONTS.md']
manifest=CORE/'MANIFEST.sha256'
entries={p:digest for digest,p in (line.split('  ',1) for line in manifest.read_text().splitlines() if line)}
for name in files:entries[name]=hashlib.sha256((CORE/name).read_bytes()).hexdigest()
manifest.write_text(''.join(f'{digest}  {name}\n' for name,digest in sorted(entries.items())),encoding='utf-8')
remaining=[]
for name,digest in entries.items():
    actual=hashlib.sha256((CORE/name).read_bytes()).hexdigest()
    if actual!=digest:remaining.append({'file':name,'recorded':digest,'actual':actual})
assert sorted(remaining,key=lambda r:r['file'])==sorted(previous['unrelated_preexisting_mismatches'],key=lambda r:r['file'])
(HERE/'vendor-manifest-audit.json').write_text(json.dumps({'updated':files,'updated_files_verified':True,
    'unrelated_preexisting_mismatches':remaining,
    'preexisting_debt_in_touched_Vulkan_file':previous['preexisting_debt_in_touched_Vulkan_file'],
    'debt_note':previous['debt_note']},indent=2))
print('3 owned entries verified; inherited vendor debt unchanged')
