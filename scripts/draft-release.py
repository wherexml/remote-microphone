#!/usr/bin/env python3
"""上传已验收的附件到 GitHub Release 草稿，并下载核对；绝不自动发布。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def run(*args, check=True):
    return subprocess.run([str(x) for x in args], check=check, capture_output=True, text=True)


def digest(path):
    with path.open('rb') as f:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            hasher.update(chunk)
        return hasher.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('--repo', required=True)
    args = parser.parse_args()
    work = args.workspace.resolve()
    record = json.loads((work / 'verified.json').read_text())
    assets = work / 'assets'
    manifest = json.loads((assets / 'release-manifest.json').read_text())
    if manifest['commit'] != record['commit'] or manifest['version'] != record['version']:
        raise SystemExit('版本或源码记录不一致。')
    for platform in ('app', 'dmg'):
        if json.loads((work / f'{platform}-notary.json').read_text())['status'] != 'Accepted':
            raise SystemExit('缺少公证 Accepted 回执。')
    for name, sha in record['files'].items():
        if Path(name).name != name or digest(assets / name) != sha:
            raise SystemExit('本机附件已改变；停止上传。')
    if set(record['files']) != {p.name for p in assets.iterdir()}:
        raise SystemExit('附件目录含未验收文件。')
    tag = 'v' + record['version']
    existing = run('gh', 'release', 'view', tag, '--repo', args.repo,
                   '--json', 'isDraft,url,targetCommitish', check=False)
    if existing.returncode == 0:
        release = json.loads(existing.stdout)
        if not release['isDraft'] or release['targetCommitish'] != record['commit']:
            raise SystemExit('同版本已发布或属于另一源码；不覆盖。')
    else:
        # Distinguish a missing release from authentication/network failure.
        releases = json.loads(run('gh', 'api', f'repos/{args.repo}/releases?per_page=100').stdout)
        if any(r['tag_name'] == tag for r in releases):
            raise SystemExit('无法读取既有 Release；停止。')
        notes = work / 'release-notes.md'
        notes.write_text(f'''Remote Microphone {record['version']} 首个分发候选。

把 iPhone 麦克风的声音通过 Tailscale 传到 Mac，配合 UU 远程和 BlackHole 使用。

## 下载与安装

- **Mac**：下载 `macOS-universal.dmg`，拖入 Applications。支持 Apple Silicon / Intel，最低 macOS 14；已完成 Developer ID 签名、Apple 公证、App 与 DMG 票据及 Gatekeeper 校验。Intel 真机尚未验收。
- **iPhone**：下载 `iOS-unsigned.ipa` 后使用自己的 Apple 签名安装，或从源码用 Xcode 安装。最低 iOS 17。IPA **不能直接点击安装**，不包含开发者设备授权，不是 TestFlight 包；第三方自行签名工具尚未逐一验收。
- 两端开启 Tailscale；Mac 另行安装 BlackHole 2ch。配合 UU 使用时关闭“电脑声音 / 远程声音”，避免回音和啸叫。

正式包与早期自用开发版使用不同标识，需要重新配对；只运行一个 Mac 接收服务。

## 附件校验

`SHA256SUMS` 提供 SHA-256；`release-manifest.json` 记录版本、源码与打包结果。

```sh
shasum -a 256 -c SHA256SUMS
```

源码：`{record['commit']}`。

本草稿尚未作为正式版发布；首次分发的浏览器下载、拖拽安装、原生交互与实际音频验收另行记录。TestFlight 后续接入。
''')
        run('gh', 'release', 'create', tag, '--repo', args.repo, '--target', record['commit'],
            '--draft', '--title', f"Remote Microphone {record['version']}", '--notes-file', notes,
            *[assets / name for name in record['files']])
    with tempfile.TemporaryDirectory(prefix='remote-microphone-release-') as folder:
        run('gh', 'release', 'download', tag, '--repo', args.repo, '--dir', folder)
        files = {p.name: digest(p) for p in Path(folder).iterdir() if p.is_file()}
        if files != record['files']:
            raise SystemExit('GitHub 下载附件与本机不一致；保留草稿，不发布。')
    release = json.loads(run('gh', 'release', 'view', tag, '--repo', args.repo,
                            '--json', 'url,isDraft,targetCommitish').stdout)
    if not release['isDraft']:
        raise SystemExit('Release 状态意外改变，请检查。')
    (work / 'github-draft-verified.json').write_text(json.dumps(
        {**release, 'download_hashes_verified': True, 'files': record['files']}, indent=2) + '\n')
    print('草稿已创建，所有附件下载哈希一致：' + release['url'])


if __name__ == '__main__':
    main()
