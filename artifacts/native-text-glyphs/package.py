"""Package the numeral fix with original pixels and protected earlier evidence."""
import hashlib
from html import escape
import json
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BUILD=ROOT/'build-validation/native-text-glyphs'
sys.path.insert(0,str(HERE.parent/'text-coverage-candidate'))
from review import make_review


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(name):return json.loads((HERE/name).read_text())


def main():
    data=read('measurements.json');colors=read('colors.json');digits=read('digits.json')
    validation=read('validation.json');ui=read('ui-validation.json');captures=read('captures.json')
    assert all(not r['exit_code'] for group in [validation,ui] for c in group['checks'] for r in c['records'])
    for name,digest in data['source_sha256'].items():assert sha(ROOT/name)==digest,('Stale source',name)
    old=json.loads((HERE.parent/'native-text-refined/measurements.json').read_text())
    normalized={key.replace('\\','/'):value for key,value in old['source_sha256'].items()}
    baseline={}
    for path in (HERE/'baseline-refined').glob('*.d'):
        key='vendor/aurora-d-0.4.5/source/aurora/text/'+path.name
        assert sha(path)==normalized[key],('Baseline differs from measured prior source',path)
        baseline[str(path.relative_to(ROOT))]=sha(path)
    prior=json.loads((HERE.parent/'native-text-refined/manifest.json').read_text())['sha256']
    for name,digest in prior.items():assert sha(ROOT/name)==digest,('Prior refinement evidence changed',name)
    protected=json.loads((HERE.parent/'native-text-next/decision.json').read_text())['image_hashes']
    count=0
    for folder,images in protected.items():
        for name,digest in images.items():
            assert sha(ROOT/folder/(name+'.png'))==digest
            count+=1
    audit={'default':'approved C','current_source_sha256':data['source_sha256'],
        'font_documentation_sha256':sha(ROOT/'vendor/aurora-d-0.4.5/docs/FONTS.md'),
        'baseline_refined_source_sha256':baseline,
        'baseline_git_revision':json.loads((HERE/'baseline-refined/provenance.json').read_text())['git_revision'],
        'C_D_144_image_corpora_unchanged':data['C_D_pixels_unchanged'],
        'C_10_app_images_unchanged':captures['C_app_pixels_unchanged'],
        'C_live_pixels_unchanged':ui['C_live_pixels_unchanged'],
        'earlier_refinement_files_verified':len(prior),'protected_D_images_verified':count}
    (HERE/'source-audit.json').write_text(json.dumps(audit,indent=2))

    pixels=HERE/'digit-pixels';pixels.mkdir(exist_ok=True)
    panels=[];font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',13)
    for family in ['consolas','courier']:
        for phase in range(8):
            strips=[]
            for label,suffix in [('before','light.ppm'),('after','light.ppm'),('Windows','light-native.png')]:
                parts=[]
                for digit in '0123456789':
                    mode='after' if label=='Windows' else label
                    path=BUILD/'digits'/f'{family}-{phase}-{digit}-{mode}-{suffix}'
                    parts.append(Image.open(path).convert('RGB').crop((5,5,24,29)))
                    before=json.loads((BUILD/'digits'/f'{family}-{phase}-{digit}-before.json').read_text())
                    after=json.loads((BUILD/'digits'/f'{family}-{phase}-{digit}-after.json').read_text())
                    assert before['glyphs']==after['glyphs'],'Numeral layout changed'
                strip=Image.new('RGB',(sum(im.width for im in parts),24),'white');x=0
                for im in parts:strip.paste(im,(x,0));x+=im.width
                strip.save(pixels/f'{family}-phase{phase}-{label}.png');strips.append(strip)
            if phase==0:
                panel=Image.new('RGB',(strips[0].width*6+175,35+sum(im.height*6+10 for im in strips)),'#e3e7ee')
                draw=ImageDraw.Draw(panel);draw.text((8,6),f'{family}, 17px, phase 0 — 6× nearest-neighbor enlargement',font=font,fill='black');y=35
                for label,im in zip(['Previous refined D','Updated refined D','Windows grayscale'],strips):
                    draw.text((8,y+8),label,font=font,fill='black')
                    panel.paste(im.resize((im.width*6,im.height*6),Image.Resampling.NEAREST),(175,y));y+=im.height*6+10
                panels.append(panel)
        make_review(pixels/f'{family}-phase0-before.png',pixels/f'{family}-phase0-after.png',
            f'{family} 17px isolated numerals: previous / updated refined D (C stays default)',HERE/f'{family}-17-digits')
    montage=Image.new('RGB',(max(p.width for p in panels),sum(p.height+10 for p in panels)),'#c8cfd9');y=0
    for panel in panels:montage.paste(panel,(0,y));y+=panel.height+10
    montage.save(HERE/'17px-numerals.png')
    rows=[]
    for family in ['consolas','courier']:
        for digit in '0123456789':
            items=[r for r in digits['comparisons'] if r['font']==family and r['digit']==digit]
            before=sum(r['before_error'] for r in items)/len(items);after=sum(r['after_error'] for r in items)/len(items)
            rows.append(f'<tr><td>{family}</td><td>{digit}</td><td>{before:.3f}</td><td>{after:.3f}</td></tr>')
    comparison_rows=[]
    for before,after,d in zip(data['comparisons']['before-refined-D'],data['comparisons']['refined-D'],data['comparisons']['D']):
        comparison_rows.append('<tr>'+''.join(f'<td>{escape(str(v))}</td>' for v in [after['font'],after['size'],after['theme'],
            f'{before["monitor_error"]:.3f}',f'{after["monitor_error"]:.3f}',f'{d["monitor_error"]:.3f}'])+'</tr>')
    app_rows=''
    for app,themes in [('notepad',['light','dark']),('host',['light','dark']),('padpp',['light'])]:
        for theme in themes:
            app_rows+=f'<tr><td>{app}</td><td>{theme}</td>'+''.join(f'<td><a href="{app}-{theme}-{dpi}/review.html">{dpi} DPI</a></td>' for dpi in [96,144])+'</tr>'
    s=data['summary']['before-refined-D'];cs=colors['summary']['before-refined-D'];ds=digits['summary']['consolas']
    previous_regressions=[]
    old_rows=data['comparisons']['before-refined-D'];old_d=data['comparisons']['D'];new_rows=data['comparisons']['refined-D']
    for before,d,after in zip(old_rows,old_d,new_rows):
        if before['monitor_error']>d['monitor_error']:
            previous_regressions.append(f'<tr><td>{before["font"]}</td><td>{before["size"]}</td><td>{before["theme"]}</td><td>{before["monitor_error"]-d["monitor_error"]:+.4f}</td><td>{after["monitor_error"]-d["monitor_error"]:+.4f}</td></tr>')
    html=f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Aurora: Consolas 17px numerals and Courier regression fix</title><style>
body{{font:16px/1.6 'Segoe UI',sans-serif;margin:35px auto;max-width:1100px;padding:0 22px;background:#f8fafc;color:#172033}}
a{{color:#164bad}}.status{{padding:16px;border-left:4px solid #24834b;background:#e7f3eb}}.scroll,figure{{overflow:auto;margin:12px 0}}
table{{border-collapse:collapse}}td,th{{border:1px solid #ccd3dc;padding:6px 10px;text-align:left}}code{{background:#e8edf3;padding:3px}}
.pixels img{{image-rendering:pixelated;max-width:none}}.phase{{display:flex;gap:22px;flex-wrap:wrap}}.phase img{{image-rendering:pixelated;display:block}}
</style><h1>Consolas 17px numerals: stem-distance fix</h1><p>20 October 2026 · refined D only · Windows grayscale reference</p>
<p class="status"><b>C remains the default.</b> The reported Courier New regressions are removed: no monochrome or RGB case is worse than reviewed D.
Consolas 17px isolated-numeral error falls <b>{100*(1-ds['after_mean']/ds['before_mean']):.1f}%</b>, with no numeral/phase regression.
Courier's isolated numeral shapes remain an open gap. Exact native parity is unfinished.</p>
<p><a href="consolas-17-digits/review.html"><b>Compare Consolas 17px: before / after</b></a> ·
<a href="padpp-live-{ui['live_dpi']}/review.html">Live Pad++: C / updated refined D, {ui['live_dpi']} DPI</a> · <a href="README.md">Implementation and limits</a></p>
<h2>What was wrong</h2><p>Unrounded horizontal MIRP kept a CVT distance even when it differed too far from the outline.
This distorted numeral stems, especially 1, 2, 5 and 8. Refined D now applies the existing horizontal cut-in in that case too.
The fix uses no family-name or size-specific tuning. Vertical behavior, gamma, metrics, layout and C/D pixels are unchanged.</p>
<p><a href="native-probe.json">Generated-font native probes</a> independently confirm the horizontal behavior with symmetric and asymmetric smoothing;
vertical controls remain unchanged. Signed instruction tests cover boundaries and compatibility opt-outs.
<a href="https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype">Microsoft's horizontal hinting compatibility context</a>.</p>
<h2>Actual 17px numerals</h2><p>Each digit uses its own identical origin, at phase 0. Rows are the previous refinement, this fix, then Windows.
The enlargement below uses nearest-neighbor pixels; scroll horizontally if needed. Other phases are available below.</p>
<figure class="pixels"><img src="17px-numerals.png" alt="Before, after and Windows: Consolas and Courier numerals at 17px, enlarged six times"></figure>
<h2>Every numeral, all eight phases and both themes</h2><p>320 comparisons across two fonts. Consolas: 64 improve, 96 equal, none regress;
mean error {ds['before_mean']:.3f} → {ds['after_mean']:.3f}. Courier: all 160 remain equal, with mean error 31.734.
This patch removes Courier's measured whole-line regressions through other affected glyphs; it does not fix Courier's isolated numeral outlines.</p>
<details><summary>Per-digit average errors</summary><table><tr><th>Font</th><th>Digit</th><th>Before</th><th>After</th></tr>{''.join(rows)}</table></details>
<p><a href="digits.json">All 320 numeral/phase measurements</a>. These are 8-bit ink-union pixel errors, not readability scores.</p>
<label>Inspect phase: <select id="phase">{''.join(f'<option value="{i}">{i}/8 pixel</option>' for i in range(8))}</select></label>
<div class="phase">{''.join(f'<div><b>{family}</b>'+''.join(f'<p>{label}<img data-font="{family}" data-mode="{mode}" src="digit-pixels/{family}-phase0-{mode}.png" alt="{family} {label} actual 17px digits"></p>' for label,mode in [('Previous refined D','before'),('Updated refined D','after'),('Windows grayscale','Windows')])+'</div>' for family in ['consolas','courier'])}</div>
<script>document.getElementById('phase').addEventListener('change',e=>{{for(const im of document.querySelectorAll('[data-font]'))im.src=`digit-pixels/${{im.dataset.font}}-phase${{e.target.value}}-${{im.dataset.mode}}.png`;}});</script>
<h2>Courier regressions removed</h2><table><tr><th>Font</th><th>px</th><th>Theme</th><th>Previous delta vs D</th><th>New delta vs D</th></tr>{''.join(previous_regressions)}</table>
<p>The four prior RGB regressions are removed too. In the 288-case RGB corpus, 276 visible cases improve over C and D; 12 white-on-white controls tie.
Against the previous refinement, {cs['improved']} improve, {cs['equal']} tie and none regress.</p>
<h2>Whole corpus</h2><table><tr><th>Comparison</th><th>Improved</th><th>Equal</th><th>Regressed</th></tr>
<tr><td>Updated / previous refined D</td><td>40</td><td>104</td><td>0</td></tr><tr><td>Updated / reviewed D</td><td>144</td><td>0</td><td>0</td></tr>
<tr><td>Updated / C</td><td>144</td><td>0</td><td>0</td></tr></table><p>Mean monochrome native error: C 12.862; D 11.689;
previous refinement 10.427; updated refinement 10.011. Corpora overlap; counts must not be added.</p>
<h2>Application reviews and validation</h2><table><tr><th>Application</th><th>Theme</th><th>100%</th><th>150%</th></tr>{app_rows}</table>
<p>Font/cache, 7,200 Windows glyph/size cases plus reverse replay per profile, 96/120/144/192 DPI, isolated releases and full host/Pad++ workflows pass.
The 0.039 ink guard is unchanged. The actual 120-DPI GPU probe matches software in both changing frames.
All C and reviewed D font pixels, C application pixels and same-scale live C pixels remain unchanged.</p>
<p>Finer curves and post-IUP changes were tested but excluded because they introduced regressions. The existing older Notepad drag/restore smoke failure remains open.
Courier outline fidelity, remaining grayscale differences, native shaping parity and ClearType RGB subpixel rendering remain unfinished.</p>
<p>Opt in before startup: <code>AURORA_TEXT_EXPERIMENT=native-refined</code>. Leave it unset for approved C. No default promotion is proposed.</p>
<p><a href="validation.json">Framework/build log</a> · <a href="ui-validation.json">Host/Pad++ log</a> · <a href="captures.json">App/GPU captures</a> ·
<a href="source-audit.json">Source and protected-evidence audit</a> · <a href="vendor-manifest-audit.json">Vendor audit</a> ·
<a href="../native-text-refined/index.html">Preserved previous refinement</a></p>
<details><summary>All 144 monochrome comparisons</summary><div class="scroll"><table><tr><th>Font</th><th>px</th><th>Theme</th><th>Previous refined D</th><th>Updated refined D</th><th>Reviewed D</th></tr>{''.join(comparison_rows)}</table></div></details>
<p><a href="measurements.json">Source/font hashes and measurements</a> · <a href="colors.json">RGB measurements</a></p></html>'''
    (HERE/'index.html').write_text(html,encoding='utf-8')
    (HERE/'status.json').write_text(json.dumps({'default':'C','status':'refined-D-stem-fix','default_changed':False,
        'promotion_proposed':False,'reported_Courier_regressions_removed':True,
        'Courier_isolated_numeral_outlines_improved':False},indent=2))
    files=[p for p in HERE.rglob('*') if p.is_file() and p.name!='manifest.json' and '__pycache__' not in p.parts]
    (HERE/'manifest.json').write_text(json.dumps({'default':'C','sha256':{str(p.relative_to(ROOT)):sha(p) for p in files}},indent=2))
    print(HERE/'index.html')


if __name__=='__main__':main()
