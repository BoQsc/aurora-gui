import sys,json
sys.path.insert(0,'artifacts/native-text-next')
from diagnose import HERE,BUILD,FONTS,SIZES,ref
from alpha_experiments import corrected
from PIL import Image
records={}
for variant in ['C','msirp-cutin','signatures','both-cutin','signatures-cutin','post-cutin','curves-64','curves-256','curves-vacuform']:
 rows=[]
 for fam in FONTS:
  for size in SIZES:
   raw=Image.open(BUILD/variant/f'{fam}-{size}-light-raw.png').convert('L')
   for dark in [False,True]:
    fg,bg,theme=(240,24,'dark') if dark else (0,255,'light')
    target=Image.open(BUILD/'C'/f'{fam}-{size}-{theme}-native.png').convert('RGB')
    actual=raw.point([round(bg+(fg-bg)*corrected((255-v)/255,fg,fam=='courier')) for v in range(256)]).convert('RGB')
    error=ref.grayscale_error(actual,target,bg)['mean_absolute_error']
    rows.append({'font':fam,'size':size,'theme':theme,'error':error})
 base=json.load(open(HERE/'cutin-experiments.json'))['comparisons']['C']
 print(variant,'mean',round(sum(x['error'] for x in rows)/144,4),'improve',sum(a['error']<b['monitor_error'] for a,b in zip(rows,base)),'regress',sum(a['error']>b['monitor_error'] for a,b in zip(rows,base)))
 records[variant]=rows
(HERE/'combined-alpha-experiments.json').write_text(json.dumps(records,indent=2))
