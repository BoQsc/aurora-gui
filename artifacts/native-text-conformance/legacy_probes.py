import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit
h=(audit.BUILD/'current-line-projection-x/source/aurora/text/hinter.d').read_text();t=(audit.CORE/'source/aurora/text/truetype.d').read_text()
cases={}
# Separate legacy outline mode from its sampling lattice.
for name in ['legacy-grid','legacy-hinting','legacy-both']:
 ch=h;ct=t
 if name!='legacy-grid':
  ch=ch.replace('''            _naturalSymmetric = (flags & 8) != 0;''', '''            _naturalSymmetric = (flags & 8) != 0;
            if (_refinedTextExperiment && tableData(tag!"gasp").length >= 2 && be16(tableData(tag!"gasp"),0) == 0)
                _naturalSymmetric = pixelSize > 20;''')
 if name!='legacy-hinting':
  ct=ct.replace('''            try return (naturalGaspFlags''', '''            if (refinedTextExperiment() && tableData(tag!"gasp").length >= 2 && be16(tableData(tag!"gasp"),0) == 0)
                return pixelSize <= 20 ? 8 : 4;
            try return (naturalGaspFlags''')
 cases[name]={'hinter':ch,'truetype':ct}
results={}
def run(name,m):
 exe=audit.compile(name,m);return name,audit.measure(name,exe,families=['courier'],sizes=list(audit.diagnose.SIZES))
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r;print(n,'star12',next(x['error'] for x in r if x['size']==12 and x['character']=='*'))
(audit.HERE/'legacy-combination-hypotheses.json').write_text(json.dumps(results,indent=2))
