"""Package explicit parity failures with original pixels and an inspectable glyph viewer."""
import hashlib,html,json,platform,subprocess
from pathlib import Path
import audit


def compare(label):
 rows=[];totals={'improved':0,'equal_error':0,'increased_error':0};regressions=[]
 for p in sorted((audit.HERE/f'full-{label}').glob('*.json')):
  after=json.loads(p.read_text());before=json.loads((audit.HERE/('full-before-sizes' if label.endswith('sizes') else 'full-before')/p.name).read_text());bm={tuple(r[:4]):r for r in before['failures']};am={tuple(r[:4]):r for r in after['failures']};counts={'improved':0,'equal_error':0,'increased_error':0}
  for key in bm.keys()|am.keys():
   old=bm.get(key,[0]*8);new=am.get(key,[0]*8);delta=new[6]-old[6];field='improved' if delta<0 else 'increased_error' if delta>0 else 'equal_error';counts[field]+=1
   if delta>0:regressions.append({'font':after['font'],'size':key[0],'phase_eighths':key[1],'theme':key[2],'glyph_id':key[3],'codepoints':after['codepoints'].get(str(key[3]),[]),'before_ink_mae':old[6],'after_ink_mae':new[6],'delta':delta,'before_different_pixels':old[4],'after_different_pixels':new[4]})
  # Cases absent from both failure maps were exact in both images.
  counts['equal_error']+=after['tested']-len(bm.keys()|am.keys())
  rows.append({'font':after['font'],'tested':after['tested'],'exact':after['exact'],**counts})
  for k,v in counts.items():totals[k]+=v
 return {'scope':label,'fonts':rows,'totals':totals},sorted(regressions,key=lambda r:r['delta'],reverse=True)


def main():
 gates={name:json.loads((audit.HERE/('conformance-'+name+'.json')).read_text()) for name in ['final','final-sizes']};focus=json.loads((audit.HERE/'focus.json').read_text());comp={};reg={}
 for name in gates:comp[name],reg[name]=compare(name)
 (audit.HERE/'regressions.json').write_text(json.dumps(reg,separators=(',',':')))
 (audit.HERE/'comparison.json').write_text(json.dumps(comp,indent=2))
 reference=audit.diagnose.ref.NativeReference(audit.diagnose.FONTS['segoe'])
 try:settings=reference.settings
 finally:reference.close()
 sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (audit.HERE/'after-source').glob('*.d')}
 status={'status':'FAIL','native_parity':False,'default':'C (unchanged)','experiment':'native-refined','architecture':'portable pure D; native reference tooling only','gates':gates,'focus':{k:v for k,v in focus.items() if k!='cases'},'scope_note':'Rasterization with identical glyph IDs and origins; shaping, fallback and all-platform certification are separate. Sizes and fonts are finite tested scopes, not all fonts or sizes.','source_sha256':sources,'platform':platform.platform(),'revision':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'native_reference':settings}
 (audit.HERE/'status.json').write_text(json.dumps(status,indent=2));(audit.HERE/'conformance-status.json').write_text(json.dumps(status,indent=2))
 fonts=list(audit.diagnose.FONTS);names={'segoe':'Segoe UI','consolas':'Consolas','arial':'Arial','calibri':'Calibri','tahoma':'Tahoma','verdana':'Verdana','courier':'Courier New','times':'Times New Roman','inter':'Inter Variable'}
 options=''.join(f'<option value="{f}"'+(' selected' if f=='consolas' else '')+f'>{names[f]}</option>' for f in fonts)
 gate_rows=''.join(f'<tr><td>{title}</td><td>{gates[key]["tested"]:,}</td><td>{gates[key]["exact"]:,}</td><td class="bad">{gates[key]["failed"]:,}</td></tr>' for key,title in [('final','Every glyph in 9 fonts, 13 / 17 / 26px'),('final-sizes','Visible ASCII, 9 fonts, every integer size 1–96px')])+f'<tr><td>Visible ASCII at 17px, 9 fonts, 8 phases, both themes</td><td>{focus["tested"]:,}</td><td>{focus["current_exact"]:,}</td><td class="bad">{focus["tested"]-focus["current_exact"]:,}</td></tr>'
 rows=''.join(f'<tr><td>{names[r["font"]]}</td><td>{r["improved"]:,}</td><td>{r["equal_error"]:,}</td><td class="bad">{r["increased_error"]:,}</td><td><a href="full-final/{r["font"]}.json">Every failed case</a></td></tr>' for r in comp['final']['fonts'])
 data=json.dumps(focus['cases'],separators=(',',':')).replace('</','<\\/')
 page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Aurora text conformance — incomplete</title><style>
body{font:16px/1.55 Segoe UI,Arial,sans-serif;color:#202124;background:#fafafa;max-width:1180px;margin:30px auto;padding:0 20px}h1{font-size:28px}h2{font-size:21px}.bad{color:#a11717;font-weight:600}.notice{border-left:5px solid #a11717;background:#fff1ee;padding:14px 20px}a{color:#0754aa}table{border-collapse:collapse;width:100%;background:white;margin:20px 0}td,th{text-align:left;border-bottom:1px solid #ddd;padding:10px}label{display:inline-block;margin:6px 18px 12px 0}select,input{font:inherit;padding:5px;max-width:190px}.cards{display:flex;gap:20px;flex-wrap:wrap}.card{background:white;border:1px solid #ccc;padding:14px;min-width:220px}.zoom{width:200px;height:232px;image-rendering:pixelated;border:1px solid #eee}.actual{width:50px;height:58px;image-rendering:pixelated;border:1px solid #eee}small{display:block;color:#555}.links{display:flex;gap:24px;flex-wrap:wrap}code{font-family:Consolas,monospace}details{margin:18px 0}summary{cursor:pointer}</style>
<h1>Aurora text conformance</h1><div class="notice"><strong class="bad">Incomplete: exact Windows-native parity still fails.</strong><p>C remains the shared default. These changes are in the opt-in <code>native-refined</code> renderer and remain pure D. Improved averages, nonblank output and passing application tests do not establish glyph quality.</p></div>
<p>The tests compare the same glyph IDs at the same positions against this Windows machine’s native grayscale output. The scopes below overlap. Every unequal pixel is a failure; clipped captures also fail.</p>
<table><thead><tr><th>Tested scope</th><th>Comparisons</th><th>Exact</th><th>Failed</th></tr></thead><tbody>GATE_ROWS</tbody></table>
<h2>Inspect every visible ASCII glyph at 17px</h2><p>Original pixels are shown at 1× and enlarged 4× with nearest-neighbor sampling; the viewer compensates for browser/display DPI. Choose any letter, numeral or symbol. The previous refinement is the source frozen at the start of this work; it already includes the earlier glyph-audit fixes.</p>
<label>Font <select id="font">FONT_OPTIONS</select></label><label>Character <input id="character" value="2" maxlength="1" size="2"></label><label>Phase <select id="phase">PHASE_OPTIONS</select></label><label>Theme <select id="theme"><option value="light">Light</option><option value="dark">Dark</option></select></label><p id="caseStatus"></p><div class="cards" id="cards"></div>
<details><summary>Full 17px sheets at the selected phase/theme</summary><div id="sheets" class="links"></div></details>
<h2>Individual changes across every glyph at 13 / 17 / 26px</h2><p>The change counts use ink error only as a diagnostic. An improvement can still fail the exact native gate. Every increase is retained in <a href="regressions.json">the regression list</a>.</p><table><thead><tr><th>Font</th><th>Lower error</th><th>Equal error</th><th>Higher error</th><th>Native failures</th></tr></thead><tbody>CHANGE_ROWS</tbody></table>
<h2>What changed</h2><p>Diagonal hints now use the moved line for projection and retain a separate original vector. Natural diagonal rounding and cut-in use the appropriate extra resolution. Relative axis distances and IUP interpolation preserve original-point ratios, including Windows’ signed IUP rounding and rounded interval guards. Curve-changing instructions survive into scan conversion. Quadratic intersections remain stable at horizontal extrema.</p>
<p>The 1px refinement skips glyph instructions while retaining the initial scaled coordinates; the nine-font 846-glyph check is unchanged. Native generated-font probes expose this behavior, and still retain unresolved tiny-outline cases.</p>
<p><strong>Remaining gaps:</strong> native dropout controls still do not reach Aurora’s scan converter; Times and Courier can lose thin strokes. Composite child hint programs are not executed. Legacy gasp behavior and additional outline/coverage differences remain. This is a rasterization test, not a certification of shaping, fallback or every platform.</p>
<h2>Application evidence</h2><p><a href="captures.json">Matched application and live GPU captures</a> · <a href="validation.json">Framework and build results</a> · <a href="ui-validation.json">Full host / live Pad++ workflows</a> · <a href="status.json">Scope and native settings</a></p>
<p><a href="README.md">Reproduction and limitations</a> · <a href="comparison.json">Complete comparison totals</a> · <a href="manifest.json">Evidence hashes</a></p>
<script>const cases=FOCUS_DATA;const labels={native:'Windows native',before:'Previous refinement',current:'Current refinement'};let generation=0;
function canvas(img,cp,zoom){const c=document.createElement('canvas');c.width=50;c.height=58;c.className=zoom?'zoom':'actual';const ratio=window.devicePixelRatio||1,scale=zoom?4:1;c.style.width=(50*scale/ratio)+'px';c.style.height=(58*scale/ratio)+'px';const i=cp-33;c.getContext('2d').drawImage(img,i%16*50,Math.floor(i/16)*58,50,58,0,0,50,58);return c;}
async function update(){const token=++generation,f=document.getElementById('font').value,p=Number(document.getElementById('phase').value),t=document.getElementById('theme').value,cp=document.getElementById('character').value.codePointAt(0);if(!(cp>=33&&cp<=126)){document.getElementById('caseStatus').textContent='Enter a visible ASCII character (! through ~).';return;}const r=cases.find(r=>r[0]===f&&r[1]===p&&r[2]===t&&r[3]===cp);document.getElementById('caseStatus').textContent=(r[6]?'Exact native match for this case.':'FAIL: pixels differ from native.')+' Previous ink error '+r[7].toFixed(3)+'; current '+r[8].toFixed(3)+'. Current differing pixels: '+r[10]+'.';document.getElementById('caseStatus').className=r[6]?'':'bad';const cards=document.getElementById('cards'),sheets=document.getElementById('sheets');cards.replaceChildren();sheets.replaceChildren();for(const label of ['native','before','current']){const src='focus/'+f+'-17-p'+p+'-'+t+'-'+label+'.png';const img=new Image();img.src=src;await img.decode();if(token!==generation)return;const card=document.createElement('div');card.className='card';const title=document.createElement('strong');title.textContent=labels[label];card.append(title,document.createElement('br'),canvas(img,cp,false),document.createElement('br'),canvas(img,cp,true));cards.append(card);const a=document.createElement('a');a.href=src;a.textContent=labels[label]+' — complete sheet';sheets.append(a);}}
for(const id of ['font','phase','theme','character'])document.getElementById(id).addEventListener('input',()=>update().catch(e=>{document.getElementById('caseStatus').textContent='Image loading failed: '+e.message;}));window.addEventListener('resize',()=>update());update();</script></html>'''
 page=page.replace('GATE_ROWS',gate_rows).replace('FONT_OPTIONS',options).replace('PHASE_OPTIONS',''.join(f'<option value="{n}">{n}/8 px</option>' for n in range(8))).replace('CHANGE_ROWS',rows).replace('FOCUS_DATA',data)
 (audit.HERE/'index.html').write_text(page,encoding='utf-8')
 files={str(p.relative_to(audit.ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(audit.HERE.rglob('*')) if p.is_file() and
        p.name!='manifest.json' and '__pycache__' not in p.parts and p.suffix!='.pyc'}
 (audit.HERE/'manifest.json').write_text(json.dumps({'sha256':files},indent=2))
 print({k:{'tested':v['tested'],'exact':v['exact'],'failed':v['failed']} for k,v in gates.items()});print(comp)

if __name__=='__main__':main()
