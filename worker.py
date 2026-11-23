#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SCLAlertView 云端构建 worker（自包含版 v2.0）

本文件内含完整编译逻辑，不依赖 build_dylib.sh / Package.swift / SwiftPM：
  1. 固化客户配置到 SCLCustomerConfig.swift
  2. clang 编译 SCLDylibEntry.m（constructor 入口）
  3. swiftc 把全部 .swift + 上面的 .o 链接成 Mach-O dylib
  4. ad-hoc 签名、打包 zip、回传

为什么不用 SwiftPM：SwiftPM 不支持同一 target 混用 Swift 与 Objective-C，
会报 "contains mixed language source files; feature not supported"。

环境变量：
  SCL_BASE_URL     站点根地址，如 https://your.domain
  SCL_WORKER_TOKEN 后台「构建节点设置」里的 Token
可选：
  SCL_ONCE=1       处理一个任务后退出（GitHub Actions 用）
  SCL_JOB_ID       指定要处理的任务 ID（dispatch 触发时传入）
"""
import os
import sys
import json
import time
import base64
import shutil
import tempfile
import zipfile
import subprocess
import urllib.request
import urllib.parse
import urllib.error

WORKER_VERSION = '2.1-server-sdk'

BASE = os.environ.get('SCL_BASE_URL', '').strip().rstrip('/')
TOKEN = os.environ.get('SCL_WORKER_TOKEN', '').strip()
ONCE = os.environ.get('SCL_ONCE', '0') == '1'
FORCED_JOB = os.environ.get('SCL_JOB_ID', '').strip()
HERE = os.path.dirname(os.path.abspath(__file__))

# 容错：去掉误填的 /admin、/api 后缀
for suffix in ('/admin', '/api'):
    if BASE.endswith(suffix):
        BASE = BASE[:-len(suffix)]

if not BASE or not TOKEN:
    sys.exit('缺少环境变量：SCL_BASE_URL=%r SCL_WORKER_TOKEN长度=%d\n'
             '请在 GitHub 仓库 Settings > Secrets and variables > Actions 配置这两个 Secret。'
             % (BASE, len(TOKEN)))

if not BASE.startswith('http'):
    sys.exit('SCL_BASE_URL 必须以 http:// 或 https:// 开头，当前: ' + BASE)


# ============ API ============

def api(params, post=None):
    """调用站点 API；token 同时放 query / header / POST 体，兼容 nginx 过滤 header。"""
    p = dict(params)
    p.setdefault('token', TOKEN)
    url = BASE + '/api/job.php?' + urllib.parse.urlencode(p)
    headers = {
        'X-SCL-Token': TOKEN,
        'Authorization': 'Bearer ' + TOKEN,
        'User-Agent': 'SCLBuildWorker/' + WORKER_VERSION,
    }
    data = None
    if post is not None:
        body = dict(post)
        body.setdefault('token', TOKEN)
        data = urllib.parse.urlencode(body).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        detail = ''
        try:
            detail = e.read().decode('utf-8', 'ignore')[:300]
        except Exception:
            pass
        return {'error': 'HTTP %s %s' % (e.code, detail)}
    except Exception as e:
        return {'error': str(e)}


def report_log(job_id, line):
    line = str(line).replace(BASE, '<站点>')
    api({'action': 'log', 'id': job_id, 'line': line[:400]})
    print(line)


def run(cmd, cwd=None):
    """执行命令，返回 (returncode, 合并输出)。"""
    proc = subprocess.run(
        cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=1800
    )
    return proc.returncode, (proc.stdout or '')


# ============ 编译 ============

def find_sdk_src():
    p = os.path.join(HERE, 'sdk_src')
    return p if os.path.isdir(p) else None


def download_sdk(dest_dir):
    """从站点拉取最新 SDK 源码 zip 并解压，返回解压后的 sdk_src 目录。
    这样仓库里只需要 worker.py，源码永远以后台服务器上的为准。"""
    url = BASE + '/api/sdkzip.php?' + urllib.parse.urlencode({'token': TOKEN})
    req = urllib.request.Request(url, headers={
        'X-SCL-Token': TOKEN,
        'Authorization': 'Bearer ' + TOKEN,
        'User-Agent': 'SCLBuildWorker/' + WORKER_VERSION,
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    if len(data) < 200:
        raise RuntimeError('SDK 包过小(%d 字节)' % len(data))

    zip_path = os.path.join(dest_dir, 'sdk.zip')
    with open(zip_path, 'wb') as f:
        f.write(data)

    target = os.path.join(dest_dir, 'sdk_src')
    os.makedirs(target, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        # 防目录穿越
        for name in z.namelist():
            if '..' in name or name.startswith('/'):
                raise RuntimeError('SDK 包内含非法路径: ' + name)
        z.extractall(target)
    return target


def sdk_path(name):
    code, out = run(['xcrun', '--sdk', name, '--show-sdk-path'])
    if code != 0:
        raise RuntimeError('xcrun 获取 SDK 失败(%s): %s' % (name, out.strip()[:300]))
    return out.strip()


def build_platform(src_dir, job_id, sdk_name, triple, arch, out_file, tag):
    """编译单个平台的 dylib。分 clang 编 ObjC、swiftc 链接两步，绕开 SwiftPM 混合语言限制。"""
    root = os.path.join(src_dir, 'SCLAlertView')
    objc_file = os.path.join(root, 'BackendControl', 'SCLDylibEntry.m')
    swift_files = []
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            if f.endswith('.swift'):
                swift_files.append(os.path.join(dirpath, f))
    swift_files.sort()

    if not swift_files:
        raise RuntimeError('未找到任何 .swift 源文件')
    if not os.path.isfile(objc_file):
        raise RuntimeError('缺少 BackendControl/SCLDylibEntry.m')

    report_log(job_id, '[%s] Swift 文件 %d 个，开始编译' % (tag, len(swift_files)))
    sdk = sdk_path(sdk_name)
    obj_dir = os.path.join(HERE, '.obj-%s' % tag)
    if os.path.isdir(obj_dir):
        shutil.rmtree(obj_dir, ignore_errors=True)
    os.makedirs(obj_dir, exist_ok=True)
    objc_obj = os.path.join(obj_dir, 'SCLDylibEntry.o')

    # 步骤 1：clang 编 Objective-C（constructor 入口）
    cmd = ['xcrun', '--sdk', sdk_name, 'clang',
           '-arch', arch, '-isysroot', sdk, '-fobjc-arc', '-O2',
           '-c', objc_file, '-o', objc_obj]
    code, out = run(cmd)
    if out.strip():
        for line in out.strip().splitlines()[-20:]:
            report_log(job_id, '[%s] ' % tag + line)
    if code != 0:
        raise RuntimeError('clang 编译 ObjC 失败(退出码 %d)' % code)

    # 步骤 2：swiftc 把 Swift + ObjC 对象链接成 dylib
    cmd = ['swiftc', '-emit-library', '-O', '-parse-as-library',
           '-module-name', 'SCLAlertView',
           '-target', triple, '-sdk', sdk,
           '-framework', 'UIKit', '-framework', 'Foundation',
           '-Xlinker', '-install_name', '-Xlinker', '@rpath/SCLAlertView.dylib',
           '-Xlinker', '-rpath', '-Xlinker', '/usr/lib/swift',
           '-o', out_file] + swift_files + [objc_obj]
    code, out = run(cmd)
    if out.strip():
        for line in out.strip().splitlines()[-40:]:
            report_log(job_id, '[%s] ' % tag + line)
    if code != 0:
        raise RuntimeError('swiftc 链接失败(退出码 %d)' % code)

    if not os.path.isfile(out_file) or os.path.getsize(out_file) < 1024:
        raise RuntimeError('产物 dylib 未生成或过小')

    report_log(job_id, '[%s] 产出 %s (%d KB)' % (tag, os.path.basename(out_file), os.path.getsize(out_file) // 1024))
    return out_file


def build_dylib(job):
    """完整流程：固化配置 -> 编译两个平台 -> 签名 -> 打包，返回 zip 字节。"""
    jid = job['id']
    app_id = job['app_id']
    customer = job['customer']
    secret = job['secret']
    cfg_url = BASE + '/api/config.php?app_id=' + app_id
    act_url = BASE + '/api/activate.php'

    work = tempfile.mkdtemp(prefix='sclbuild_')
    try:
        # 优先从站点拉取最新源码（保证与后台一致）；失败则回退仓库内 sdk_src
        try:
            src = download_sdk(work)
            report_log(jid, '已从服务器拉取最新 SDK 源码')
        except Exception as e:
            local = find_sdk_src()
            if not local:
                raise RuntimeError('无法获取 SDK 源码（服务器拉取失败: %s，且仓库内无 sdk_src）' % e)
            src = os.path.join(work, 'sdk_src')
            shutil.copytree(local, src)
            report_log(jid, '服务器拉取失败(%s)，改用仓库内 sdk_src' % e)

        # 固化客户配置
        cfg_file = os.path.join(src, 'SCLAlertView', 'BackendControl', 'SCLCustomerConfig.swift')
        if not os.path.isfile(cfg_file):
            raise RuntimeError('缺少 SCLCustomerConfig.swift')
        content = open(cfg_file, encoding='utf-8').read()
        for k, v in {
            '__SCL_CONFIG_URL__': cfg_url,
            '__SCL_ACTIVATE_URL__': act_url,
            '__SCL_APP_ID__': app_id,
            '__SCL_SECRET__': secret,
            '__SCL_POLL__': '300',
        }.items():
            content = content.replace(k, v)
        open(cfg_file, 'w', encoding='utf-8').write(content)
        report_log(jid, '客户配置已固化（域名/appID/密钥）')

        outdir = os.path.join(work, 'output')
        os.makedirs(os.path.join(outdir, 'iphoneos'), exist_ok=True)
        os.makedirs(os.path.join(outdir, 'simulator'), exist_ok=True)

        dev = build_platform(src, jid, 'iphoneos', 'arm64-apple-ios13.0', 'arm64',
                             os.path.join(outdir, 'iphoneos', 'SCLAlertView.dylib'), 'ios')
        sim = build_platform(src, jid, 'iphonesimulator', 'arm64-apple-ios13.0-simulator', 'arm64',
                             os.path.join(outdir, 'simulator', 'SCLAlertView.dylib'), 'sim')

        # ad-hoc 签名
        for f in (dev, sim):
            run(['codesign', '-f', '-s', '-', f])
        report_log(jid, 'ad-hoc 签名完成')

        # 校验 Mach-O
        code, out = run(['file', dev, sim])
        report_log(jid, '校验: ' + out.strip())

        # 说明文件
        with open(os.path.join(outdir, 'README.txt'), 'w', encoding='utf-8') as f:
            f.write(
                'SCLAlertView 成品动态库 (dylib)\n'
                '================================\n'
                '客户: %s\nApp ID: %s\n生成时间: %s\n\n'
                '文件：\n'
                '  iphoneos/SCLAlertView.dylib    真机 arm64\n'
                '  simulator/SCLAlertView.dylib   模拟器 arm64\n\n'
                '域名/AppID/密钥已固化进二进制。dylib 被加载时 constructor 自动连接后台并弹窗。\n\n'
                '使用方式：\n'
                '  真机：放入 App 的 Frameworks 目录，用 insert_dylib 注入 LC_LOAD_DYLIB，\n'
                '        然后 codesign --force --sign <证书> 重签整个 App。\n'
                '  模拟器：DYLD_INSERT_LIBRARIES=/path/SCLAlertView.dylib 启动。\n'
                '  Frida：Module.load("/path/SCLAlertView.dylib")\n\n'
                '配置接口: %s\n激活接口: %s\n'
                % (customer, app_id, time.strftime('%Y-%m-%d %H:%M:%S'), cfg_url, act_url)
            )
        with open(os.path.join(outdir, 'config.json'), 'w', encoding='utf-8') as f:
            json.dump({'customer': customer, 'app_id': app_id,
                       'config_url': cfg_url, 'activate_url': act_url},
                      f, ensure_ascii=False, indent=2)

        # 打包 zip
        zip_path = os.path.join(work, 'dylib.zip')
        with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
            for dirpath, _, files in os.walk(outdir):
                for fn in files:
                    full = os.path.join(dirpath, fn)
                    arc = os.path.relpath(full, outdir).replace('\\', '/')
                    z.write(full, arc)

        with open(zip_path, 'rb') as f:
            return f.read()
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ============ 任务处理 ============

def process_one(job):
    jid = job['id']
    print('领取任务', jid, job.get('customer'))

    claim = api({'action': 'claim', 'id': jid})
    if claim.get('error'):
        print('claim 失败:', claim['error'])
        return

    report_log(jid, 'worker %s 开始构建 %s' % (WORKER_VERSION, job.get('customer')))

    if not job.get('secret'):
        api({'action': 'fail', 'id': jid, 'error': '任务缺少 secret'})
        return

    try:
        data = build_dylib(job)
        report_log(jid, '构建完成，回传 %d KB' % (len(data) // 1024))
        r = api({'action': 'finish', 'id': jid},
                post={'file': base64.b64encode(data).decode()})
        if r.get('error'):
            raise RuntimeError('回传失败: ' + str(r['error']))
        print('完成', jid)
    except Exception as e:
        msg = str(e)[:300]
        api({'action': 'fail', 'id': jid, 'error': msg})
        print('失败', jid, msg)


def main():
    print('SCL 构建 worker 启动，版本', WORKER_VERSION)
    print('  BASE  =', BASE)
    print('  TOKEN = 长度', len(TOKEN))
    print('  SDK   =', find_sdk_src() or '(未找到 sdk_src)')

    probe = api({'action': 'heartbeat', 'v': WORKER_VERSION})
    if probe.get('error'):
        print('!! 连接站点失败:', probe['error'])
        print('!! 请确认 SCL_BASE_URL 是公网可访问的 https 地址，且未被防火墙拦截')
        if ONCE:
            sys.exit(1)
    else:
        print('== 站点连接正常 ==')

    while True:
        r = api({'action': 'pull'})
        if r.get('error'):
            print('拉取任务失败:', r['error'])
            if ONCE:
                sys.exit(1)
            time.sleep(10)
            continue

        job = r.get('job')

        if FORCED_JOB:
            one = api({'action': 'getjob', 'id': FORCED_JOB})
            j = one.get('job')
            if j and j.get('status') == 'queued':
                job = j
            else:
                print('指定任务不可用，改为队列顺序')
                if not job:
                    print('无待处理任务，退出')
                    break

        if not job:
            if ONCE:
                print('无待处理任务，退出')
                break
            time.sleep(5)
            continue

        process_one(job)
        if ONCE:
            break


if __name__ == '__main__':
    main()
