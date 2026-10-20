"""Package measured refinement while retaining C and the reviewed D evidence."""
import hashlib
from html import escape
import json
from pathlib import Path
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CORE=ROOT/'vendor/aurora-d-0.4.5'
BUILD=ROOT/'build-validation/native-text-refined'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def shader_words(source,name):
    body=re.search(r'\b'+name+r'\s*=\s*\[(.*?)\];',source,re.S).group(1)
    return [int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)u',body)]


def main():
    data=json.loads((HERE/'measurements.json').read_text())
    colors=json.loads((HERE/'colors.json').read_text())
    validation=json.loads((HERE/'validation.json').read_text())
    ui=json.loads((HERE/'ui-validation.json').read_text())
    assert all(not r['exit_code'] for group in [validation,ui] for c in group['checks'] for r in c['records'])
    for name,digest in data['source_sha256'].items():assert sha(ROOT/name)==digest,('Stale measurement source',name)
    current=(CORE/'source/aurora/vulkan/shaders.d').read_text()
    old=subprocess.check_output(['git','show','HEAD:vendor/aurora-d-0.4.5/source/aurora/vulkan/shaders.d'],cwd=ROOT,text=True)
    unchanged={name:shader_words(current,name)==shader_words(old,name)
        for name in ['vertexShaderSpirv','fragmentShaderSpirv','imageFragmentShaderSpirv']}
    assert all(unchanged.values())
    decision=json.loads((HERE.parent/'native-text-next/decision.json').read_text())
    protected=[]
    for folder,images in decision['image_hashes'].items():
        for name,digest in images.items():
            path=ROOT/folder/(name+'.png')
            assert sha(path)==digest,('Reviewed D image changed',str(path))
            protected.append(str(path.relative_to(ROOT)))
    extra=['docs/FONTS.md','tests/native_alpha.d','dub.json','shaders/aurora-quantized.frag.spv']
    hashes=dict(data['source_sha256'])
    hashes.update({str((CORE/p).relative_to(ROOT)):sha(CORE/p) for p in extra})
    audit={'default':'owner-approved C','source_sha256':hashes,'C_D_shader_arrays_unchanged':unchanged,
           'protected_reviewed_D_images_verified':protected,'C_live_pixels_unchanged':ui['C_live_pixels_unchanged'],
           'reviewed_D_authorization':decision['authorization']}
    (HERE/'source-audit.json').write_text(json.dumps(audit,indent=2))
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',13)
    panels=[]
    selection=[('segoe',13,'light'),('segoe',13,'dark'),('consolas',17,'light'),('arial',13,'light'),
               ('inter',13,'light'),('courier',12,'dark'),('courier',17,'dark'),('courier',18,'dark')]
    selected=HERE/'font-pixels';selected.mkdir(exist_ok=True)
    for family,size,theme in selection:
        name=f'{family}-{size}-{theme}'
        ims=[]
        for profile,suffix in [('C','aurora'),('D','aurora'),('refined-D','aurora'),('refined-D','native')]:
            path=BUILD/'corpus'/profile/f'{name}-{suffix}.png'
            image=Image.open(path).convert('RGB');ims.append(image)
            image.save(selected/f'{name}-{profile if suffix=="aurora" else "Windows"}.png')
        panel=Image.new('RGB',(max(im.width for im in ims)+175,35+sum(im.height+7 for im in ims)),'#e3e7ee')
        draw=ImageDraw.Draw(panel);draw.text((8,5),f'{family}, {size}px, {theme} — actual pixels',font=font,fill='black')
        y=35
        for label,im in zip(['Approved C','Reviewed D','Refined D','Windows grayscale'],ims):
            draw.text((8,y+5),label,font=font,fill='black');panel.paste(im,(170,y));y+=im.height+7
        panels.append(panel)
    montage=Image.new('RGB',(max(p.width for p in panels),sum(p.height+8 for p in panels)),'#c8cfd9')
    y=0
    for panel in panels:montage.paste(panel,(0,y));y+=panel.height+8
    montage.save(HERE/'comparison.png')
    rows=[]
    for c,d,r in zip(data['comparisons']['C'],data['comparisons']['D'],data['comparisons']['refined-D']):
        rows.append('<tr>'+''.join(f'<td>{v}</td>' for v in [c['font'],c['size'],c['theme'],
            f'{c["monitor_error"]:.3f}',f'{d["monitor_error"]:.3f}',f'{r["monitor_error"]:.3f}',
            f'{r["monitor_error"]-d["monitor_error"]:+.3f}'])+'</tr>')
    regress=[]
    for d,r in zip(colors['comparisons']['D'],colors['comparisons']['refined-D']):
        if r['rgb_ink_mae']>d['rgb_ink_mae']:
            regress.append('<tr>'+''.join(f'<td>{escape(str(v))}</td>' for v in [r['font'],r['size'],
                r['foreground'],r['background'],f'{r["rgb_ink_mae"]-d["rgb_ink_mae"]:+.4f}'])+'</tr>')
    app_rows=''
    for app,themes in [('notepad',['light','dark']),('host',['light','dark']),('padpp',['light'])]:
        for theme in themes:
            app_rows+=f'<tr><td>{app}</td><td>{theme}</td>'+''.join(
                f'<td><a href="{app}-{theme}-{dpi}/review.html">{dpi} DPI</a></td>' for dpi in [96,144])+'</tr>'
    s=data['summary']['C'];d=data['summary']['D'];cs=colors['summary']['C']
    html=f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Aurora refined native text — C remains default</title><style>
body{{font:16px/1.6 'Segoe UI',sans-serif;margin:35px auto;max-width:1100px;padding:0 22px;background:#f8fafc;color:#172033}}
a{{color:#164bad}}.status{{padding:16px;border-left:4px solid #bd8a0d;background:#fff3cd}}img{{max-width:100%;height:auto}}
table{{border-collapse:collapse}}td,th{{border:1px solid #ccd3dc;padding:6px 10px;text-align:left}}code{{background:#e8edf3;padding:3px}}.scroll{{overflow:auto}}
</style><h1>Aurora text refinement</h1><p>20 October 2026 · Windows grayscale reference · pure-D production rendering</p>
<p class="status"><b>C stays the shared default, as requested.</b> The separate refinement improves all 144 monochrome comparisons against C,
lowering average native pixel error {100*(1-s['refined_mean']/s['baseline_mean']):.1f}%. It still has three small Courier New regressions against D.
No default promotion is proposed. Exact native parity remains unfinished.</p>
<p><a href="padpp-live-{ui['live_dpi']}/review.html"><b>Compare live Pad++: C / refined D at {ui['live_dpi']} DPI</b></a> ·
<a href="README.md">Implementation and limits</a> · <a href="../native-text-next/index.html">Preserved D review</a></p>
<h2>Measured progress</h2><table><tr><th>Corpus</th><th>Against C</th><th>Against D</th><th>Mean error, C → refined</th></tr>
<tr><td>144 monochrome cases, nine fonts</td><td>144 improve; 0 regress</td><td>141 improve; 3 regress</td><td>{s['baseline_mean']:.3f} → {s['refined_mean']:.3f}</td></tr>
<tr><td>288 opaque RGB cases, four fonts</td><td>276 improve; 12 equal; 0 regress</td><td>272 improve; 12 equal; 4 regress</td><td>{cs['baseline_mean']:.3f} → {cs['refined_mean']:.3f}</td></tr></table>
<p>Errors are 8-bit mean absolute differences over the union of ink pixels; they are diagnostic, not readability scores.
The corpora overlap. RGB ties are white-on-white controls. Identical fonts, glyph IDs and physical origins isolate rasterization from shaping.
The native monitor reports gamma 1.8 and grayscale contrast 1.0; other monitor settings are not claimed to match.</p>
<h2>What changed</h2><p>Refined D adds foreground-dependent gamma correction and metadata-based legacy thin-family handling to D's masks.
The bounded cache reuses raw outlines across colors and opacity. An experimental Vulkan shader rounds opacity to A8 before blending,
matching software exactly in both changing live probe frames at 96 DPI. C and D retain their existing correction and shader bytes.</p>
<p>Opt in before startup with <code>AURORA_TEXT_EXPERIMENT=native-refined</code>. Leave it unset for C.
The reviewed D remains available as <code>native-next</code>. No native rasterizer is used in application code.
The model adapts <a href="https://github.com/microsoft/terminal/blob/1283c0f5b99a2961673249fa77c6b986efb5086c/src/renderer/atlas/dwrite.hlsl">Microsoft Terminal's MIT-licensed grayscale model</a>.</p>
<h2>Actual font pixels, including remaining Courier gaps</h2><p>Four rows per sample: C, D, refined D, Windows grayscale.
<a href="thin-isolation.json">Accounting for the native thin-family boost</a> still leaves a large Courier residual.
This suggests further outline/scan-conversion work; it does not identify a specific faulty instruction or dropout rule.</p>
<a href="comparison.png"><img src="comparison.png" alt="C, D, refined D and independent Windows grayscale captures"></a>
<h2>Remaining RGB regressions against D</h2><table><tr><th>Font</th><th>px</th><th>Foreground RGB</th><th>Background RGB</th><th>Error increase</th></tr>{''.join(regress)}</table>
<p>All four are still better than C. Three monochrome regressions are Courier New dark at 12, 17 and 18px.
Neither native ClearType RGB output nor native shaping parity is implemented by this refinement.</p>
<h2>Matched application reviews</h2><table><tr><th>Application</th><th>Theme</th><th>100%</th><th>150%</th></tr>{app_rows}</table>
<p>All ten C app captures and all 144 C/D font images are unchanged. The desktop is now at 100%, compared with 125% during D's review.
The preserved binary run in C mode at today's scale matches the new C live Pad++ capture exactly. No image was resized to compare scales.</p>
<h2>Validation</h2><p>Framework tests, 7,200 Windows glyph/size cases plus reverse replay per profile, font/cache/growth/metadata tests,
96/120/144/192 DPI tests, isolated releases, full host interactions and live Pad++ workflows pass for C and the refinement.
The approved 0.039 ink guard is unchanged. The older Notepad's preexisting drag/restore smoke failure remains open.</p>
<p><a href="validation.json">Framework/build log</a> · <a href="ui-validation.json">Full host/Pad++ log</a> ·
<a href="captures.json">App and live GPU captures</a> · <a href="compatibility.json">Compatibility checks</a> ·
<a href="source-audit.json">Source/protected-review audit</a> · <a href="vendor-manifest-audit.json">Vendor debt audit</a></p>
<details><summary>All 144 monochrome measurements</summary><div class="scroll"><table><tr><th>Font</th><th>px</th><th>Theme</th><th>C</th><th>D</th><th>Refined D</th><th>Delta vs D</th></tr>{''.join(rows)}</table></div></details>
<p><a href="measurements.json">Measurements, native settings and hashes</a> · <a href="colors.json">Full opaque RGB measurements</a></p></html>'''
    (HERE/'index.html').write_text(html,encoding='utf-8')
    (HERE/'status.json').write_text(json.dumps({'default':'C','status':'experimental-refinement',
        'owner_direction':'Keep C; continue improving D','default_changed':False,'promotion_proposed':False,
        'remaining_regressions_against_D':{'monochrome':3,'RGB':4}},indent=2))
    files=[p for p in HERE.rglob('*') if p.is_file() and p.name!='manifest.json' and '__pycache__' not in p.parts]
    (HERE/'manifest.json').write_text(json.dumps({'default':'owner-approved C',
        'sha256':{str(p.relative_to(ROOT)):sha(p) for p in files}},indent=2))
    print(HERE/'index.html')


if __name__=='__main__':main()
