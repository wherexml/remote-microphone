import json, statistics, shutil, pathlib, hashlib
root = pathlib.Path(__file__).resolve().parents[1] / 'artifacts'
data = json.loads((root / 'virtual-input.json').read_text())
rows = data.get('blocks', [])
active = [r for r in rows if r['rms'] > .02]
runs = []
for row in rows:
    on = row['rms'] > .02
    if not runs or runs[-1]['active'] != on:
        runs.append(dict(active=on, start=row['t'], end=row['t']))
    else:
        runs[-1]['end'] = row['t']
tones = [r for r in runs if r['active'] and r['end'] - r['start'] > .5]
frequency = statistics.median(r['hz'] for r in active) if active else 0
checks = dict(two_tone_segments=len(tones) == 2, frequency_440hz=abs(frequency-440) < 15)
if len(tones) == 2:
    checks.update(stale_audio_silenced=tones[1]['start']-tones[0]['end'] > 1.5,
                  stop_silenced=rows[-1]['t']-tones[-1]['end'] > 3)
report = dict(passed=all(checks.values()), checks=checks, segments=runs,
              scope='Synthetic Float32 -> production AAC codec over real localhost DTLS -> installed receiver -> BlackHole 2ch -> independent capture',
              phone_acceptance=False, median_active_frequency_hz=frequency,
              captured_at=data.get('captured_at'), peak_block_rms=data.get('peak_block_rms'))
for name in ['virtual-input.wav', 'virtual-input.json']:
    shutil.copyfile(root/name, root/('synthetic-'+name))
report['wav_sha256'] = hashlib.sha256((root/'synthetic-virtual-input.wav').read_bytes()).hexdigest()
(root/'loopback-e2e.json').write_text(json.dumps(report, indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='segments'}, indent=2))
raise SystemExit(0 if report['passed'] else 1)
