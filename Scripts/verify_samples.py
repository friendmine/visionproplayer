#!/usr/bin/env python3
from pathlib import Path
import json, subprocess
root=Path(__file__).resolve().parents[1]/'VisionProPlayer/Resources'
for name,audio,width,height in [('Sample2D.mp4','aac',960,540),('SampleMKV.mkv','flac',960,540),('SampleSBS.mp4','aac',1280,360),('SampleSBS.mkv','aac',1280,360)]:
    data=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(root/name)]))
    v=next(s for s in data['streams'] if s['codec_type']=='video')
    a=next(s for s in data['streams'] if s['codec_type']=='audio')
    assert (v['codec_name'],v['width'],v['height'])==('h264',width,height),name
    assert a['codec_name']==audio,name
    assert 11.9<float(data['format']['duration'])<12.2,name
    subprocess.run(['ffmpeg','-v','error','-i',str(root/name),'-f','null','-'],check=True)
    print(f'PASS {name}: H.264 {width}x{height}, {audio}, 12 seconds; full decode clean')
