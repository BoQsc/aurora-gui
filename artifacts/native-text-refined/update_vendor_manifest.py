"""Digest owned changes and retain the historical Vulkan vendor-debt record."""
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
previous=json.loads((HERE.parent/'native-text-next/vendor-manifest-audit.json').read_text())
files=previous['updated']+[
    'source/aurora/text/alphacorrection.d','source/aurora/text/fontprofile.d',
    'source/aurora/render/vulkan.d','source/aurora/vulkan/shaders.d','tools/make_spirv.py',
    'shaders/aurora-quantized.frag.spv','licenses/Microsoft-Terminal-MIT.txt','tests/native_alpha.d']
manifest=CORE/'MANIFEST.sha256'
entries={p:digest for digest,p in (line.split('  ',1) for line in manifest.read_text().splitlines() if line)}
historical=previous['unrelated_preexisting_mismatches']
for name in files:entries[name]=hashlib.sha256((CORE/name).read_bytes()).hexdigest()
manifest.write_text(''.join(f'{digest}  {name}\n' for name,digest in sorted(entries.items())),encoding='utf-8')
remaining=[]
for name,digest in entries.items():
    actual=hashlib.sha256((CORE/name).read_bytes()).hexdigest()
    if actual!=digest:remaining.append({'file':name,'recorded':digest,'actual':actual})
expected=[p for p in historical if p['file']!='source/aurora/render/vulkan.d']
assert sorted(remaining,key=lambda p:p['file'])==sorted(expected,key=lambda p:p['file'])
(HERE/'vendor-manifest-audit.json').write_text(json.dumps({
    'updated':files,'updated_files_verified':True,'unrelated_preexisting_mismatches':remaining,
    'preexisting_debt_in_touched_Vulkan_file':[p for p in historical if p['file']=='source/aurora/render/vulkan.d'],
    'debt_note':'Vulkan already differed from the vendor manifest before this experiment. Re-digesting the new optional shader selection does not certify those earlier changes.'},indent=2))
print(len(files),'owned entries verified;',len(remaining),'untouched preexisting mismatches; prior Vulkan debt retained')
