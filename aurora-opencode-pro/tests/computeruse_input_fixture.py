"""Dedicated disposable windows for computer input integration tests."""
import json
import sys
import time
import tkinter as tk
from pathlib import Path

directory = Path(sys.argv[1])
root = tk.Tk()
# Cover unrelated desktop animations during visual-progress assertions.
root.overrideredirect(True)
root.geometry(f'{root.winfo_screenwidth()}x{root.winfo_screenheight()}+0+0')
root.configure(background='#202020')
root.attributes('-topmost', True)
root.update()
windows = {}
for index, name in enumerate(('A', 'B')):
    window = tk.Toplevel(root)
    window.title('Aurora Input Fixture ' + name)
    window.geometry(f'300x150+{40 + index * 350}+160')
    window.attributes('-topmost', True)
    entry = tk.Entry(window)
    entry.pack(padx=20, pady=20, fill='x')
    state = {'window': window, 'entry': entry, 'clicks': 0}
    def clicked(state=state):
        state['clicks'] += 1
    button = tk.Button(window, text='Fixture-only button', command=clicked)
    button.pack()
    state['button'] = button
    windows[name] = state

started = time.monotonic()
def update():
    if (directory / 'stop').exists() or time.monotonic() - started > 60:
        root.destroy()
        return
    data = {}
    for name, state in windows.items():
        entry = state['entry']
        button = state['button']
        data[name] = {'title': state['window'].title(), 'text': entry.get(),
            'clicks': state['clicks'],
            'entry': [entry.winfo_rootx() + 30, entry.winfo_rooty() + 10],
            'button': [button.winfo_rootx() + 30, button.winfo_rooty() + 10]}
    pending = directory / 'state.tmp'
    pending.write_text(json.dumps(data), encoding='utf-8')
    pending.replace(directory / 'state.json')
    root.after(40, update)
root.update()
for state in windows.values():
    state['window'].lift()
root.after(100, update)
root.mainloop()
