#!/usr/bin/env python3
"""Drive the app on an Android emulator/phone via adb (for manual-style UI checks).

usage: ui_drive.py [-s SERIAL] step [step ...]
steps:
  shot:NAME          screenshot to /tmp/claude-1000/shots/NAME.png (or $SHOTS)
  tap:TEXT           tap the first element whose text/content-desc contains TEXT
  tapxy:X,Y          tap coordinates
  type:TEXT          type text into the focused field
  back               system back
  wait:SECONDS       sleep
  dump               print visible texts
  scroll             swipe up (scroll down)
Flutter exposes widget labels to the accessibility tree, which uiautomator dumps.
"""
import argparse
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

SHOTS = os.environ.get('SHOTS', '/tmp/claude-1000/shots')


def adb(serial, *args, out=False):
    cmd = ['adb', '-s', serial, *args]
    if out:
        return subprocess.run(cmd, capture_output=True, timeout=30).stdout
    subprocess.run(cmd, check=False, timeout=30, stdout=subprocess.DEVNULL)


def nodes(serial):
    adb(serial, 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml')
    xml = adb(serial, 'exec-out', 'cat', '/sdcard/ui.xml', out=True)
    root = ET.fromstring(xml)
    for n in root.iter('node'):
        label = (n.get('text') or '') + ' ' + (n.get('content-desc') or '')
        b = [int(v) for v in re.findall(r'\d+', n.get('bounds', '[0,0][0,0]'))]
        yield label.strip(), ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-s', '--serial', default='emulator-5554')
    ap.add_argument('steps', nargs='+')
    a = ap.parse_args()
    os.makedirs(SHOTS, exist_ok=True)
    for st in a.steps:
        op, _, arg = st.partition(':')
        if op == 'shot':
            png = adb(a.serial, 'exec-out', 'screencap', '-p', out=True)
            with open(os.path.join(SHOTS, arg + '.png'), 'wb') as f:
                f.write(png)
        elif op == 'tap':
            hit = next(((t, c) for t, c in nodes(a.serial) if arg.lower() in t.lower()), None)
            if not hit:
                sys.exit(f'not found: {arg}')
            adb(a.serial, 'shell', 'input', 'tap', str(hit[1][0]), str(hit[1][1]))
            time.sleep(0.8)
        elif op == 'tapxy':
            x, y = arg.split(',')
            adb(a.serial, 'shell', 'input', 'tap', x, y)
            time.sleep(0.8)
        elif op == 'type':
            adb(a.serial, 'shell', 'input', 'text', arg.replace(' ', '%s'))
            time.sleep(0.4)
        elif op == 'back':
            adb(a.serial, 'shell', 'input', 'keyevent', '4')
            time.sleep(0.8)
        elif op == 'wait':
            time.sleep(float(arg))
        elif op == 'scroll':
            adb(a.serial, 'shell', 'input', 'swipe', '540', '1800', '540', '700', '300')
            time.sleep(0.8)
        elif op == 'dump':
            for t, c in nodes(a.serial):
                if t:
                    print(c, t.replace('\n', ' | ')[:120])
        else:
            sys.exit(f'bad step {st}')


if __name__ == '__main__':
    main()
