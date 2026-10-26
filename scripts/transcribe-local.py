"""Offline inspection only: reuse the already installed local sherpa model."""
import sys, json, subprocess, pathlib, os
import numpy as np
import sherpa_onnx
if len(sys.argv) != 3 or not os.environ.get('SHERPA_MODEL_DIR'):
    raise SystemExit('用法：SHERPA_MODEL_DIR=/模型目录 python scripts/transcribe-local.py 输入.wav 输出.json')
model=pathlib.Path(os.environ['SHERPA_MODEL_DIR'])
x=np.frombuffer(subprocess.check_output(['ffmpeg','-v','error','-i',sys.argv[1],'-ac','1','-ar','16000','-f','f32le','-']),dtype='<f4')
r=sherpa_onnx.OnlineRecognizer.from_transducer(tokens=str(model/'tokens.txt'),encoder=str(model/'encoder-epoch-99-avg-1.int8.onnx'),decoder=str(model/'decoder-epoch-99-avg-1.onnx'),joiner=str(model/'joiner-epoch-99-avg-1.int8.onnx'),num_threads=2,sample_rate=16000,feature_dim=80,decoding_method='greedy_search',enable_endpoint_detection=False,provider='cpu')
s=r.create_stream();s.accept_waveform(16000,np.concatenate([x,np.zeros(16000,dtype=np.float32)]));s.input_finished()
while r.is_ready(s):r.decode_stream(s)
result={'text':r.get_result(s),'seconds':len(x)/16000,'engine':'local sherpa streaming bilingual; offline replay, not Voicemore live route'}
pathlib.Path(sys.argv[2]).write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False))
