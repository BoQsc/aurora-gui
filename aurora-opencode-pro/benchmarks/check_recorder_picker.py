"""Independent offscreen widget dispatch/layout and picker click-state checks."""
import argparse, json, subprocess, time
from pathlib import Path

PACKAGE=Path(__file__).resolve().parents[1]
PROBE=r'''
import std.stdio : writeln;
import std.utf : toUTF8;
import std.file : mkdirRecurse;
import wp=aurorarecorder.windowpicker;
int main(string[] args)
{
    mkdirRecurse(args[1]);
    auto options=recorderWindowOptions();options.renderer=RendererPreference.software;
    auto window=new GuiWindow(options,Theme.dark());
    RecorderOptions settings;settings.outputFolder=args[1];
    auto controller=new RecorderController(settings,"");
    auto root=new RecorderRoot(window,controller,new GlobalHotkey(null),defaultHotkey,args[1]~"/settings.ini");
    window.setRoot(root);root.refreshTheme();
    auto driver=new UiTestDriver(window);
    root.tickTree(0.02);assert(driver.paint());
    int buttons;
    void check(Widget widget)
    {
        if(!widget.visible())return;
        if(auto button=cast(Button)widget)
        {
            auto p=widget.localToGlobal(Point(0,0));auto b=widget.bounds();
            assert(p.x>=0 && p.y>=0 && p.x+b.width<=options.width && p.y+b.height<=options.height,
                format("A visible control is clipped: %s at %s,%s %sx%s, surface %sx%s",toUTF8(button.text()),p.x,p.y,b.width,b.height,options.width,options.height));
            ++buttons;
        }
        foreach(child;widget.children())check(child);
    }
    check(root);assert(buttons>=10);
    auto p=root._windowButton.localToGlobal(Point(0,0));auto b=root._windowButton.bounds();
    driver.click(Point(p.x+b.width/2,p.y+b.height/2));
    assert(root._pickingWindow,"Actual widget event failed to arm the picker");
    assert(controller.options().windowHandle==0,"Arming selected an unrelated foreground window");
    root.tickTree(0.02);assert(driver.paint());check(root);
    p=root._windowButton.localToGlobal(Point(0,0));b=root._windowButton.bounds();
    driver.click(Point(p.x+b.width/2,p.y+b.height/2));
    assert(!root._pickingWindow,"Actual widget event failed to cancel picking");
    static if(__traits(hasMember,wp,"WindowPickClickGate"))
    {
        wp.WindowPickClickGate gate;gate.arm();
        assert(!gate.accept(true,true));assert(!gate.accept(true,false));
        assert(!gate.accept(false,true));assert(gate.accept(true,true));
        gate.arm();assert(!gate.accept(false,true));assert(gate.accept(false,true));
    }
    else assert(false,"The activating mouse click has no release gate");
    writeln("PASS actual offscreen widget click/cancel, no automatic target, unclipped controls, activation/target click sequences");
    return 0;
}
'''

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('replay',type=Path);ap.add_argument('--before',action='store_true');a=ap.parse_args()
    root=a.replay.resolve();ws=root/'checkout/aurora-video-recorder'
    out=root/('picker-independent-before' if a.before else 'picker-independent-after');out.mkdir(parents=True,exist_ok=True)
    source=ws/'source/aurorarecorder/app.d'
    body=source.read_text()
    includes=['-Isource']
    if a.before:
        body=subprocess.check_output(['git','show','01da5d0:aurora-video-recorder/source/aurorarecorder/app.d'],cwd=PACKAGE.parent,text=True)
        original=out/'source/aurorarecorder';original.mkdir(parents=True,exist_ok=True)
        (original/'windowpicker.d').write_bytes(subprocess.check_output(['git','show','01da5d0:aurora-video-recorder/source/aurorarecorder/windowpicker.d'],cwd=PACKAGE.parent))
        includes.insert(0,'-I'+str(out/'source'))
    probe=out/'probe.d';probe.write_text(body+'\n'+PROBE,encoding='utf-8');exe=out/'probe.exe';started=time.monotonic()
    with (out/'compile.log').open('w') as log:
        build=subprocess.run(['dmd','-i','-O','-version=AuroraHeadless',*includes,'-I../vendor/aurora-d-0.4.5/source',
            '-of'+str(exe),str(probe),'user32.lib','gdi32.lib','shell32.lib','wininet.lib','ole32.lib'],cwd=ws,stdout=log,stderr=subprocess.STDOUT)
    result={'compileExit':build.returncode,'passed':False}
    if build.returncode==0:
        run=subprocess.run([str(exe),str(out/'state')],cwd=ws,capture_output=True,text=True,timeout=30)
        (out/'probe.log').write_text(run.stdout+run.stderr);result.update(passed=run.returncode==0,probeExit=run.returncode)
    result['seconds']=time.monotonic()-started;(out/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
    raise SystemExit(0 if result['passed'] else 1)

if __name__=='__main__':main()
