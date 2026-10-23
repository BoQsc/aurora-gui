import sys,json,concurrent.futures
sys.path.insert(0,'artifacts/native-text-conformance');import audit
base=(audit.BUILD/'pv-both/source/aurora/text/hinter.d').read_text();t=(audit.CORE/'source/aurora/text/truetype.d').read_text()
h=base.replace('''            _naturalSymmetric = (flags & 8) != 0;''', '''            _naturalSymmetric = (flags & 8) != 0;
            if (_refinedTextExperiment && tableData(tag!"gasp").length >= 2 && be16(tableData(tag!"gasp"),0) == 0)
                _naturalSymmetric = pixelSize > 20;''')
t=t.replace('''            try return (naturalGaspFlags''', '''            if (refinedTextExperiment() && tableData(tag!"gasp").length >= 2 && be16(tableData(tag!"gasp"),0) == 0)
                return pixelSize <= 20 ? 8 : 4;
            try return (naturalGaspFlags''')
cases={'legacy-diagonal':{'hinter':h,'truetype':t},'all-diagonal-IUP':{'hinter':base.replace((audit.BUILD/'current-line-vectors/source/aurora/text/hinter.d').read_text()[(audit.BUILD/'current-line-vectors/source/aurora/text/hinter.d').read_text().index('    private static void interpolateBetween('):(audit.BUILD/'current-line-vectors/source/aurora/text/hinter.d').read_text().index('    private static void swap(')],(audit.BUILD/'IUP-precision/source/aurora/text/hinter.d').read_text()[(audit.BUILD/'IUP-precision/source/aurora/text/hinter.d').read_text().index('    private static void interpolateBetween('):(audit.BUILD/'IUP-precision/source/aurora/text/hinter.d').read_text().index('    private static void swap(')])}}
results={}
def run(n,ms):
 exe=audit.compile(n,ms);return n,audit.measure(n,exe,families=list(audit.diagnose.FONTS),sizes=list(audit.diagnose.SIZES))
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for f in concurrent.futures.as_completed([pool.submit(run,k,v) for k,v in cases.items()]):
  n,r=f.result();results[n]=r
  print(n,[(f,ch,size,next(x['error'] for x in r if x['font']==f and x['size']==size and x['character']==ch)) for f,ch,size in [('tahoma','^',13),('verdana','>',17),('times','>',12),('courier','*',12),('courier','g',17),('arial','A',17)]])
(audit.HERE/'legacy-diagonal-hypotheses.json').write_text(json.dumps(results,indent=2))
