"""Account for DirectWrite's baked thin boost in its 'neutral' output."""
import json
from pathlib import Path
import sys

from PIL import Image

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE.parent/'native-text-next'))
import diagnose


def main():
    out=ROOT/'build-validation/native-text-refined/corpus/D'
    records=[]
    for size in diagnose.SIZES:
        raw=Image.open(out/f'courier-{size}-light-raw.png').convert('L')
        # Black-on-white raw capture is an exact recovery of Aurora A8. Native
        # gamma=1/contrast=0 still contains the legacy font's internal 0.5 boost.
        alpha=[255-v for v in raw.getdata()]
        boosted=[int((1.5*a/(255+0.5*a))*255+0.5) for a in alpha]
        for theme in ['light','dark']:
            bg=255 if theme=='light' else 24
            target=Image.open(out/f'courier-{size}-{theme}-neutral.png').convert('RGB')
            actual=Image.open(out/f'courier-{size}-{theme}-raw.png').convert('RGB')
            image=Image.new('L',raw.size)
            image.putdata([255-a if theme=='light' else (240*a+24*(255-a)+127)//255 for a in boosted])
            records.append({'font':'courier','size':size,'theme':theme,
                'raw_error':diagnose.ref.grayscale_error(actual,target,bg)['mean_absolute_error'],
                'thin_boosted_error':diagnose.ref.grayscale_error(image,target,bg)['mean_absolute_error']})
    (HERE/'thin-isolation.json').write_text(json.dumps({'note':
        'Neutral DirectWrite output retains internal thin-family contrast. Applying that 0.5 boost to Aurora masks isolates the remaining difference more fairly; not proof of a particular instruction/dropout cause.',
        'comparisons':records},indent=2))
    print(json.dumps(records,indent=2))


if __name__=='__main__':main()
