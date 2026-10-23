"""Package original glyph pixels and explicit failures; no visual approval claim."""
import hashlib
from html import escape
import json
from pathlib import Path
import shutil
import sys
from PIL import Image, ImageDraw, ImageFont
import audit

HERE=audit.HERE
ROOT=audit.ROOT

def read(name):return json.loads((HERE/name).read_text())
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    matrix=read('character-matrix.json');data=read('measurements.json')
    for name,digest in data['source_sha256'].items():assert sha(ROOT/name)==digest,('Stale corpus source',name)
    if 'provenance' in matrix:
        for name,digest in matrix['provenance']['source_sha256'].items():assert sha(ROOT/name)==digest
    groups={k:v for k,v in matrix.items() if k!='provenance'}
    pixels=HERE/'pixels';pixels.mkdir(exist_ok=True)
    sheets={};regressions=[]
    for group,d in groups.items():
        before,after=[d['comparisons'][k] for k in ['before','after']]
        for c,b,a in zip(d['comparisons']['C'],before,after):
            family,size,phase,theme,cp,error=a
            name=f'{family}-{size}-p{phase}-{theme}'
            if name not in sheets:
                info=json.loads((audit.BUILD/'matrix-after'/(name+'.json')).read_text())
                old=json.loads((audit.BUILD/'matrix-before'/(name+'.json')).read_text())
                approved=json.loads((audit.BUILD/'matrix-C'/(name+'.json')).read_text())
                assert info==old==approved,('Glyph origins or IDs changed',name)
                for label,folder,suffix in [('C','matrix-C','aurora'),('before','matrix-before','aurora'),('after','matrix-after','aurora'),('native','matrix-after','native')]:
                    src=audit.BUILD/folder/(name+'-'+suffix+'.png');shutil.copyfile(src,pixels/(name+'-'+label+'.png'))
                sheets[name]={'width':info['cell_width'],'height':info['cell_height'],'C':{},'before':{},'after':{}}
            sheets[name]['C'][cp]=c[5];sheets[name]['before'][cp]=b[5];sheets[name]['after'][cp]=error
            if error>b[5]:regressions.append({'group':group,'font':family,'size':size,'phase':phase,'theme':theme,'character':chr(cp),'codepoint':cp,'before':b[5],'after':error,'increase':error-b[5]})
    regressions.sort(key=lambda r:-r['increase'])
    (HERE/'regressions.json').write_text(json.dumps(regressions,indent=2))
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',16)
    panels=[]
    for family,chars in [('consolas','0123456789efmW'),('courier','03dgqsD)*'),('inter','0123456789efm')]:
        name=f'{family}-17-p0-light';sheet=sheets[name];w=sheet['width'];h=sheet['height']
        panel=Image.new('RGB',(210+len(chars)*88,42+3*160),'#e5e9ef');draw=ImageDraw.Draw(panel)
        draw.text((10,8),f'{family} 17px / phase 0 / 4x original pixels',fill='black',font=font)
        for i,label in enumerate(['before','after','native']):
            img=Image.open(pixels/(name+'-'+label+'.png')).convert('RGB');draw.text((10,65+i*160),{'before':'Previous refined D','after':'Updated experimental D','native':'Windows grayscale'}[label],font=font,fill='black')
            for j,ch in enumerate(chars):
                cell=ord(ch)-33;x=cell%16*w;y=cell//16*h
                panel.paste(img.crop((x+6,y+5,x+28,y+39)).resize((88,136),Image.Resampling.NEAREST),(210+j*88,40+i*160))
        panels.append(panel)
    montage=Image.new('RGB',(max(p.width for p in panels),sum(p.height+12 for p in panels)),'#c4cbd5');y=0
    for p in panels:montage.paste(p,(0,y));y+=p.height+12
    montage.save(HERE/'17px-characters.png')
    summary_rows=''.join(f"<tr><td>{escape(k)}</td><td>{d['summary']['improved']}</td><td>{d['summary']['equal']}</td><td class=bad>{d['summary']['regressed']}</td><td>{d['summary']['before_mean']:.3f} → {d['summary']['after_mean']:.3f}</td></tr>" for k,d in groups.items())
    failures=''.join(f"<tr><td>{r['font']}</td><td>{r['size']}</td><td>{r['phase']}/8</td><td>{r['theme']}</td><td>{escape(r['character'])}</td><td>{r['before']:.3f}</td><td class=bad>{r['after']:.3f}</td></tr>" for r in regressions[:40])
    template='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Aurora damaged-glyph audit</title><style>
body{font:16px/1.55 'Segoe UI',sans-serif;margin:28px auto;max-width:1280px;padding:0 22px;background:#f5f7fa;color:#172033}a{color:#164bad}
h1,h2{line-height:1.25}.warning{background:#fff0da;border-left:5px solid #a85b00;padding:16px}.bad{color:#9a1d13;font-weight:600}
.controls{display:flex;flex-wrap:wrap;gap:16px;margin:18px 0}label{display:grid;gap:4px}select,input,button{font:inherit;padding:7px}input{width:75px}
.cards{display:flex;flex-wrap:wrap;gap:14px}.card{padding:12px;background:white;border:1px solid #c9d1de}.card canvas{image-rendering:pixelated;border:1px solid #ddd;display:block}
.scroll{overflow:auto;max-height:65vh;background:white}img.original{max-width:none;image-rendering:pixelated}table{border-collapse:collapse;background:white}td,th{border:1px solid #ccd3dc;padding:6px 10px;text-align:left}details{margin:20px 0}figure{margin:0}.montage{max-width:100%}code{background:#e7edf5;padding:2px}
</style><h1>Damaged glyphs: reproduced and audited</h1><p>22 October 2026 · <b>C remains the shared default.</b> Updated refined D is experimental.</p>
<div class="warning"><b>The earlier assessment was too broad.</b> Whole-line averages and a numeral-only test missed malformed letters. Consolas 17px <code>e</code> has a misplaced crossbar in the previous renderer; Courier still has substantial shape errors. The fixes below reduce those gaps, but individual regressions remain. <b>This is not a quality approval or a native-parity claim.</b></div>
<p>The interpolation fix preserves the original outline ratio, rounded phantom points, and nearest F26.6 result. Retained quadratic curves replace coarse line segments. Uninstructed simple outlines keep their design heights; composite and failed-hint fallbacks retain their existing alignment. Defaults, gamma, contrast, and the ink guard are unchanged.</p>
<h2>Inspect any character</h2><p>These are saved renderer pixels, not browser text. The microscope uses nearest-neighbor enlargement. Select 1× to inspect native size. Sheet images below retain their original dimensions.</p>
<div class="controls"><label>Font<select id="family"></select></label><label>Pixels<select id="size"></select></label><label>Horizontal phase<select id="phase"></select></label><label>Theme<select id="theme"><option>light</option><option>dark</option></select></label><label>Character<input id="character" value="e" maxlength="1"></label><label>Zoom<select id="zoom"><option value="8">8×</option><option value="1">1×</option><option value="4">4×</option><option value="12">12×</option></select></label></div>
<p id="score"></p><div class="cards" id="cards"></div><h3>All 94 non-space printable ASCII characters at 1×</h3><label>Sheet<select id="sheet"><option value="after">Updated experimental D</option><option value="C">Approved C default</option><option value="before">Previous refined D</option><option value="native">Windows grayscale</option></select></label><div class="scroll"><img class="original" id="full" alt="Original glyph sheet"></div>
<h2>Remaining regressions are visible</h2><p>Each row below compares the updated experiment with the renderer at the start of this audit. Error is 8-bit MAE over the union of ink pixels. It is a diagnostic, not a readability score. The broad and focused corpora overlap and must not be added.</p>
<table><tr><th>Corpus</th><th>Improved</th><th>Equal</th><th>Regressed</th><th>Mean before → after</th></tr>__SUMMARY__</table>
<p><a href="regressions.json">Every regression, including every phase and theme</a> · <a href="character-matrix.json">All character measurements</a> · <a href="README.md">Diagnosis, reproduction and limitations</a></p>
<details><summary>40 largest character error increases</summary><div class="scroll"><table><tr><th>Font</th><th>px</th><th>Phase</th><th>Theme</th><th>Glyph</th><th>Before</th><th>After</th></tr>__FAILURES__</table></div></details>
<h2>17px shapes, with the Windows reference</h2><img class="montage" src="17px-characters.png" alt="Previous, updated and Windows glyphs">
<h2>Application and framework evidence</h2><p><a href="padpp-live-120/review.html">Live Pad++ at 120 DPI: C / updated experiment</a> · <a href="captures.json">Software / live Vulkan captures</a> · <a href="validation.json">Framework checks and isolated release builds</a> · <a href="ui-validation.json">Full host / Pad++ workflows</a> · <a href="native-ip-probe.json">Independent Windows interpolation probe</a> · <a href="measurements.json">144 whole-line comparisons</a> · <a href="colors.json">288 RGB comparisons</a></p>
<script>const sheets=__SHEETS__;
const el=id=>document.getElementById(id),families=[...new Set(Object.keys(sheets).map(k=>k.split('-')[0]))];
function options(id,values,current){el(id).replaceChildren(...values.map(v=>{const o=document.createElement('option');o.value=v;o.textContent=id==='phase'?`${v}/8`:v;return o}));el(id).value=values.includes(current)?current:values[0]}
options('family',families,'consolas');options('size',['11','12','13','17','18','20','26','34'],'17');options('phase',['0'],'0');
let generation=0;
async function draw(){const token=++generation,f=el('family').value,s=el('size').value;
const focused=s==='17'&&['consolas','courier'].includes(f),phases=focused?['0','1','2','3','4','5','6','7']:['0'];if(el('phase').options.length!==phases.length)options('phase',phases,el('phase').value);
el('theme').disabled=!focused;if(!focused)el('theme').value='light';
const name=`${f}-${s}-p${el('phase').value}-${el('theme').value}`,d=sheets[name],cp=el('character').value.codePointAt(0)||101;
if(!d||cp<33||cp>126){el('score').textContent='Choose one printable ASCII character (! through ~).';return}
const c=d.C[cp],b=d.before[cp],a=d.after[cp];el('score').textContent=`${String.fromCodePoint(cp)} · approved C error ${c.toFixed(3)} · previous refined D ${b.toFixed(3)} · updated ${a.toFixed(3)} · ${a>b?'REGRESSION':a<b?'improved':'equal'}. Windows is the reference.`;el('score').className=a>b?'bad':'';
el('cards').replaceChildren();const index=cp-33,x=index%16*d.width,y=Math.floor(index/16)*d.height,scale=Number(el('zoom').value);
for(const [label,title] of [['C','Approved C default'],['before','Previous refined D'],['after','Updated experimental D'],['native','Windows grayscale']]){const im=new Image();im.src=`pixels/${name}-${label}.png`;await im.decode();if(token!==generation)return;const card=document.createElement('figure');card.className='card';const cap=document.createElement('figcaption');cap.textContent=title;const c=document.createElement('canvas');c.width=d.width*scale;c.height=d.height*scale;const ctx=c.getContext('2d');ctx.imageSmoothingEnabled=false;ctx.drawImage(im,x,y,d.width,d.height,0,0,c.width,c.height);card.append(cap,c);el('cards').append(card)}el('full').src=`pixels/${name}-${el('sheet').value}.png`;
}
for(const id of ['family','size','phase','theme','character','zoom','sheet'])el(id).addEventListener('change',draw);draw();</script></html>'''
    (HERE/'index.html').write_text(template.replace('__SUMMARY__',summary_rows).replace('__FAILURES__',failures).replace('__SHEETS__',json.dumps(sheets,separators=(',',':'))),encoding='utf-8')
    status={'default':'C','default_changed':False,'promotion_proposed':False,'status':'character-audit-incomplete',
        'remaining_character_regressions':{k:v['summary']['regressed'] for k,v in groups.items()},'exact_native_parity':False}
    (HERE/'status.json').write_text(json.dumps(status,indent=2))
    protected=read('../native-text-next/decision.json')['image_hashes'];count=0
    for folder,images in protected.items():
        for name,digest in images.items():assert sha(ROOT/folder/(name+'.png'))==digest;count+=1
    earlier=read('../native-text-refined/manifest.json')['sha256']
    for name,digest in earlier.items():assert sha(ROOT/name)==digest,('Earlier evidence changed',name)
    original=read('prior-glyphs-manifest.json')['sha256']
    correction=read('prior-glyphs-correction.json')['changed_only_presentation_and_status']
    corrected={r['file']:r for r in correction}
    for name,digest in original.items():
        if name in corrected:
            assert sha(HERE/'prior-glyphs-text'/Path(name).name)==digest
            assert sha(ROOT/name)==corrected[name]['corrected_sha256']
        else:assert sha(ROOT/name)==digest,('Prior glyph measurement/image changed',name)
    (HERE/'source-audit.json').write_text(json.dumps({'current_source_sha256':data['source_sha256'],
        'before_source':read('before-source/provenance.json'),'C_D_144_image_corpora_unchanged':data['C_D_pixels_unchanged'],
        'protected_D_review_images_verified':count,'earlier_refinement_files_verified':len(earlier),
        'prior_glyph_files_verified':len(original),'prior_glyph_presentation_corrections':len(corrected),
        'glyph_origins_and_ids_unchanged':True,'approved_C_character_sheets_included':True,'original_sheet_count':len(sheets),
        'documentation_sha256':{str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'AURORA-PATCHES.md',ROOT/'AURORA-QUALITY-RATCHET.md',audit.CORE/'docs/FONTS.md']}},indent=2))
    files=[p for p in HERE.rglob('*') if p.is_file() and p.name!='manifest.json' and '__pycache__' not in p.parts]
    (HERE/'manifest.json').write_text(json.dumps({'sha256':{str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for p in files}},indent=2))
    print('Packaged',len(sheets),'original sheets; every regression exposed; C default retained')

if __name__=='__main__':main()
