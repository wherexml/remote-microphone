#!/usr/bin/env python3
"""从已提交源码准备公证 DMG 和需自行签名的 IPA；不发布、不安装。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, cwd=None, log=None, check=True):
    command = [str(x) for x in args]
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if log:
        Path(log).write_text(result.stdout)
    if check and result.returncode:
        raise RuntimeError(f'{command[0]} 失败；日志：{log or result.stdout[-2000:]}')
    return result


def digest(path):
    with Path(path).open('rb') as f:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            hasher.update(chunk)
        return hasher.hexdigest()


def save(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def notarize(path, name, work, profile):
    receipt = work / f'{name}-submission.json'
    sha = digest(path)
    if receipt.exists():
        data = json.loads(receipt.read_text())
        if data['sha256'] != sha:
            raise RuntimeError('公证输入已改变，请使用新的输出目录。')
    else:
        result = run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile,
                     '--output-format', 'json', log=work / f'{name}-submit.log')
        data = {'id': json.loads(result.stdout)['id'], 'sha256': sha}
        save(receipt, data)
    result = run('xcrun', 'notarytool', 'info', data['id'], '--keychain-profile', profile,
                 '--output-format', 'json')
    status = json.loads(result.stdout)
    if status['status'] == 'In Progress':
        run('xcrun', 'notarytool', 'wait', data['id'], '--keychain-profile', profile,
            '--timeout', '50s', '--output-format', 'json',
            log=work / f'{name}-wait.log', check=False)
        status = json.loads(run('xcrun', 'notarytool', 'info', data['id'],
                                '--keychain-profile', profile, '--output-format', 'json').stdout)
    save(work / f'{name}-notary.json', status)
    if status['status'] != 'Accepted':
        if status['status'] != 'In Progress':
            run('xcrun', 'notarytool', 'log', data['id'], '--keychain-profile', profile,
                log=work / f'{name}-rejection.json', check=False)
        raise RuntimeError(f"{name} 公证状态：{status['status']}。处理中可用同一命令恢复。")


def verify_app(app, config, work):
    run('codesign', '--verify', '--deep', '--strict', app, log=work / 'codesign-verify.log')
    details = run('codesign', '-dv', '--verbose=4', app).stdout
    (work / 'codesign-details.log').write_text(details)
    if (f"TeamIdentifier={config['team']}" not in details or
            f"Authority={config['identity']}" not in details or
            'runtime' not in details or 'Timestamp=' not in details):
        raise RuntimeError('分发签名、团队、时间戳或 Hardened Runtime 不符合预期。')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != config['mac_bundle_id'] or info.get('RemoteMicStorageNamespace') != config['mac_bundle_id']:
        raise RuntimeError('Mac Bundle ID 或存储隔离不匹配。')
    archs = run('lipo', '-archs', app / 'Contents/MacOS' / info['CFBundleExecutable']).stdout.split()
    if set(archs) != {'arm64', 'x86_64'}:
        raise RuntimeError('Mac 安装包必须包含 arm64 和 x86_64。')
    entitlements = run('codesign', '-d', '--entitlements', ':-', app).stdout
    if 'com.apple.security.get-task-allow' in entitlements:
        raise RuntimeError('分发 App 不应包含调试权限。')
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--mac-bundle-id', required=True)
    parser.add_argument('--phone-bundle-id', required=True)
    parser.add_argument('--keychain-profile', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.identity.startswith('Developer ID Application: '):
        parser.error('必须使用 Developer ID Application；不接受签名降级。')
    for identifier in (args.mac_bundle_id, args.phone_bundle_id):
        if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', identifier) or identifier.endswith('.dev'):
            parser.error('正式 Bundle ID 必须是独立的有效标识，不使用 .dev。')
    if run('git', 'status', '--porcelain', cwd=ROOT).stdout.strip():
        parser.error('先提交预期发布的源码，工作区必须干净。')
    commit = run('git', 'rev-parse', 'HEAD', cwd=ROOT).stdout.strip()
    work = (args.output or ROOT / 'build/releases' / commit[:12]).resolve()
    work.mkdir(parents=True, exist_ok=True)
    config = dict(commit=commit, identity=args.identity, team=args.team,
                  mac_bundle_id=args.mac_bundle_id, phone_bundle_id=args.phone_bundle_id,
                  xcode=run('xcodebuild', '-version').stdout.strip(), policy=1)
    config_path = work / 'config.json'
    if config_path.exists() and json.loads(config_path.read_text()) != config:
        raise RuntimeError('输出目录属于另一套源码或配置；请指定新目录。')
    save(config_path, config)
    source = work / 'source'
    state_path = work / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    assets = work / 'assets'
    assets.mkdir(exist_ok=True)
    app = work / 'Remote Microphone.app'
    if not state.get('built'):
        print('构建干净源码快照……', flush=True)
        if source.exists():
            shutil.rmtree(source)
        source.mkdir()
        run('git', 'archive', '--format=tar', '-o', work / 'source.tar', commit, cwd=ROOT)
        run('tar', '-xf', work / 'source.tar', '-C', source)
        overrides = {'include': 'project.yml', 'targets': {}}
        for target, bundle in [('RemoteMicMac', args.mac_bundle_id), ('RemoteMicPhone', args.phone_bundle_id)]:
            overrides['targets'][target] = {'info': {'properties': {'RemoteMicStorageNamespace': bundle}}}
        save(source / 'release.yml', overrides)
        run(os.environ.get('XCODEGEN', 'xcodegen'), 'generate', '--spec', 'release.yml', cwd=source,
            log=work / 'xcodegen.log')
        common = ['xcodebuild', '-project', source / 'RemoteMic.xcodeproj', '-configuration', 'Release',
                  'PRODUCT_NAME=Remote Microphone', 'ONLY_ACTIVE_ARCH=NO']
        run(*common, '-scheme', 'RemoteMicMac', '-destination', 'generic/platform=macOS',
            '-derivedDataPath', work / 'MacBuild', 'ARCHS=arm64 x86_64',
            'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={args.identity}', f'DEVELOPMENT_TEAM={args.team}',
            f'PRODUCT_BUNDLE_IDENTIFIER={args.mac_bundle_id}', 'ENABLE_HARDENED_RUNTIME=YES',
            'OTHER_CODE_SIGN_FLAGS=--timestamp', 'build', cwd=source, log=work / 'mac-build.log')
        if app.exists():
            shutil.rmtree(app)
        run('ditto', work / 'MacBuild/Build/Products/Release/Remote Microphone.app', app)
        info = verify_app(app, config, work)
        version = info['CFBundleShortVersionString']
        run(*common, '-scheme', 'RemoteMicPhone', '-destination', 'generic/platform=iOS',
            '-derivedDataPath', work / 'PhoneBuild', 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO',
            f'PRODUCT_BUNDLE_IDENTIFIER={args.phone_bundle_id}', 'build', cwd=source, log=work / 'phone-build.log')
        phone = work / 'PhoneBuild/Build/Products/Release-iphoneos/Remote Microphone.app'
        phone_info = plistlib.loads((phone / 'Info.plist').read_bytes())
        if (phone_info['CFBundleIdentifier'] != args.phone_bundle_id or
                phone_info['CFBundleShortVersionString'] != version or
                phone_info['CFBundleVersion'] != info['CFBundleVersion'] or
                phone_info.get('RemoteMicStorageNamespace') != args.phone_bundle_id or
                (phone / 'embedded.mobileprovision').exists() or (phone / '_CodeSignature').exists()):
            raise RuntimeError('IPA 身份、版本或未签名状态不符合预期。')
        if run('codesign', '-dv', phone, check=False).returncode == 0:
            raise RuntimeError('IPA 不应携带开发者签名。')
        payload = work / 'ios-package/Payload'
        payload.mkdir(parents=True, exist_ok=True)
        run('ditto', phone, payload / phone.name)
        ipa = assets / f'RemoteMicrophone-{version}-iOS-unsigned.ipa'
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', payload, ipa)
        with zipfile.ZipFile(ipa) as archive:
            if archive.testzip() is not None:
                raise RuntimeError('IPA 压缩校验失败。')
        run('ditto', '-c', '-k', '--keepParent', app, work / 'app-notary.zip')
        state.update(built=True, version=version, build=info['CFBundleVersion'], ipa_sha256=digest(ipa))
        save(state_path, state)
    version = state['version']
    ipa = assets / f'RemoteMicrophone-{version}-iOS-unsigned.ipa'
    dmg = assets / f'RemoteMicrophone-{version}-macOS-universal.dmg'
    if digest(ipa) != state['ipa_sha256']:
        raise RuntimeError('IPA 在构建后被修改。')
    if not state.get('app_stapled'):
        print('检查 App 公证……', flush=True)
        notarize(work / 'app-notary.zip', 'app', work, args.keychain_profile)
        run('xcrun', 'stapler', 'staple', app, log=work / 'app-staple.log')
        state['app_stapled'] = True
        save(state_path, state)
    if not state.get('dmg_built'):
        stage = work / 'dmg-stage'
        stage.mkdir(exist_ok=True)
        run('ditto', app, stage / app.name)
        if not (stage / 'Applications').is_symlink():
            (stage / 'Applications').symlink_to('/Applications')
        shutil.copyfile(ROOT / 'LICENSE', stage / 'LICENSE.txt')
        (stage / '安装说明.txt').write_text('将 Remote Microphone 拖入 Applications。\n另行安装 BlackHole 2ch，并在两端开启 Tailscale。\niPhone 安装及配对说明：https://github.com/wherexml/remote-microphone\n')
        run('hdiutil', 'create', '-volname', 'Remote Microphone', '-srcfolder', stage,
            '-format', 'UDZO', '-ov', dmg, log=work / 'dmg-build.log')
        run('codesign', '--force', '--timestamp', '--sign', args.identity, dmg)
        state['dmg_built'] = True
        save(state_path, state)
    if not state.get('dmg_stapled'):
        print('检查 DMG 公证……', flush=True)
        notarize(dmg, 'dmg', work, args.keychain_profile)
        run('xcrun', 'stapler', 'staple', dmg, log=work / 'dmg-staple.log')
        state['dmg_stapled'] = True
        save(state_path, state)
    verify_app(app, config, work)
    for name, target in [('app', app), ('dmg', dmg)]:
        run('xcrun', 'stapler', 'validate', target, log=work / f'{name}-ticket.log')
        if json.loads((work / f'{name}-notary.json').read_text())['status'] != 'Accepted':
            raise RuntimeError('缺少 Accepted 公证回执。')
    run('codesign', '--verify', '--strict', dmg, log=work / 'dmg-signature.log')
    run('spctl', '--assess', '--type', 'execute', '--verbose=4', app, log=work / 'app-gatekeeper.log')
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', dmg,
        log=work / 'dmg-gatekeeper.log')
    mount = work / 'verify-mount'
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg, log=work / 'mount.log')
    try:
        run('diff', '-qr', app, mount / app.name, log=work / 'container-consistency.log')
        run('codesign', '--verify', '--deep', '--strict', mount / app.name)
        run('xcrun', 'stapler', 'validate', mount / app.name)
    finally:
        run('hdiutil', 'detach', mount)
    manifest = {'product': 'Remote Microphone', 'version': version, 'build': state['build'],
                'commit': commit, 'macOS': {'architectures': ['arm64', 'x86_64'], 'minimum': '14.0',
                    'bundle_id': args.mac_bundle_id, 'developer_id_signed': True, 'notarized': True,
                    'app_and_dmg_tickets_valid': True, 'gatekeeper_passed': True},
                'iOS': {'architectures': ['arm64'], 'minimum': '17.0', 'bundle_id': args.phone_bundle_id,
                    'signed': False, 'requires_user_signing': True},
                'limitations': ['Intel 真机未验收', 'IPA 自行签名安装需按账号和设备验证',
                                 '打包校验不等于完整音频端到端验收']}
    save(assets / 'release-manifest.json', manifest)
    files = [dmg, ipa, assets / 'release-manifest.json']
    (assets / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in files))
    save(work / 'verified.json', {'commit': commit, 'version': version,
                                 'files': {p.name: digest(p) for p in [*files, assets / 'SHA256SUMS']}})
    print(f'签名、公证、票据、Gatekeeper、容器一致性检查通过：{assets}', flush=True)


if __name__ == '__main__':
    main()
