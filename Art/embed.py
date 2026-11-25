#!/usr/bin/env python3
"""Writes Sources/HRArtwork.m, which carries the artwork at the top of the
tweak's settings inside the tweak itself: settings-icon.png (the icon, 88 points
at 3x, with its rounded corners see-through) and settings-scene.jpg (the night
sky behind it). Run it after changing either picture:

    python3 Art/embed.py
"""
import base64
import os

ART = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ART, '..', 'Sources', 'HRArtwork.m')


def literal(name):
    with open(os.path.join(ART, name), 'rb') as f:
        data = base64.b64encode(f.read()).decode('ascii')
    return '\n'.join('      @"%s"' % data[i:i + 96] for i in range(0, len(data), 96))


with open(OUT, 'w') as f:
    f.write('''// Written by Art/embed.py from Art/settings-icon.png and Art/settings-scene.jpg.
// Change those pictures and run it again rather than editing this file.
#import "HRArtwork.h"

static UIImage *HRImageFromBase64(NSString *base64) {
  NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
  return data ? [UIImage imageWithData:data scale:3] : nil;
}

UIImage *HRArtworkIcon(void) {
  return HRImageFromBase64(
%s);
}

UIImage *HRArtworkScene(void) {
  return HRImageFromBase64(
%s);
}
''' % (literal('settings-icon.png'), literal('settings-scene.jpg')))
print('Wrote', os.path.normpath(OUT))
