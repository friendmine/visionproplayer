#!/usr/bin/env python3
"""Locally generate original clips; requires ffmpeg and Pillow for the stereo scene."""
from pathlib import Path
import struct, zlib, subprocess, tempfile, sys
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'VisionProPlayer/Resources'
FONT = {
 'L':['10000','10000','10000','10000','10000','10000','11111'],
 'E':['11111','10000','10000','11110','10000','10000','11111'],
 'F':['11111','10000','10000','11110','10000','10000','10000'],
 'T':['11111','00100','00100','00100','00100','00100','00100'],
 'R':['11110','10001','10001','11110','10100','10010','10001'],
 'I':['11111','00100','00100','00100','00100','00100','11111'],
 'G':['01111','10000','10000','10111','10001','10001','01111'],
 'H':['10001','10001','10001','11111','10001','10001','10001'],
 '2':['11110','00001','00001','01110','10000','10000','11111'],
 'D':['11110','10001','10001','10001','10001','10001','11110'],
 'N':['10001','11001','11001','10101','10011','10011','10001'],
 'A':['01110','10001','10001','11111','10001','10001','10001'],
 'V':['10001','10001','10001','10001','10001','01010','00100'],
 'S':['01111','10000','10000','01110','00001','00001','11110'],
 ' ':['00000']*7,
}
def label(text,path):
 scale=4; w=(len(text)*6+4)*scale; h=11*scale
 pixels=bytearray(w*h*3)
 for i,c in enumerate(text):
  for y,row in enumerate(FONT[c]):
   for x,v in enumerate(row):
    if v=='1':
     for dy in range(scale):
      for dx in range(scale):
       p=(((y+2)*scale+dy)*w+(i*6+x+2)*scale+dx)*3
       pixels[p:p+3]=b'\xff'*3
 def chunk(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
 raw=b''.join(b'\0'+pixels[y*w*3:(y+1)*w*3] for y in range(h))
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
def ff(*args):subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y',*map(str,args)],check=True)
with tempfile.TemporaryDirectory(prefix='vision-player-samples-') as d:
 d=Path(d)
 label('2D NATIVE TEST',d/'2d.png')
 ff('-f','lavfi','-i','testsrc2=size=960x540:rate=30:duration=12',
    '-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=12',
    '-i',d/'2d.png','-filter_complex','[0:v][2:v]overlay=30:30[v]',
    '-map','[v]','-map','1:a','-c:v','libx264','-preset','fast','-crf','25','-pix_fmt','yuv420p',
    '-c:a','aac','-b:a','96k','-movflags','+faststart',OUT/'Sample2D.mp4')
 ff('-i',OUT/'Sample2D.mp4','-c:v','copy','-c:a','flac',OUT/'SampleMKV.mkv')
 subprocess.run([sys.executable, str(ROOT/'Scripts/generate_stereo_sample.py')], check=True)
print('Generated four 12-second test clips.')
