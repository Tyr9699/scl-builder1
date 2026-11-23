#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SCLAlertView 云端构建 worker（在 macOS 上运行；GitHub Actions macos runner 或常驻 Mac）
流程：拉取任务 -> 下载 SDK 源码包 -> 固化客户配置 -> 编译 dylib -> 回传产物。
你（网页操作者）不需要 Mac，这个 worker 跑在云端。

环境变量：
  SCL_BASE_URL     宝塔站点根地址，如 https://your.domain
  SCL_WORKER_TOKEN 后台生成的构建节点 token
可选：
  SCL_ONCE=1       只处理一个任务后退出（适合 GitHub Actions 定时触发）
"""
import os, sys, json, time, base64, urllib.request, urllib.parse, urllib.error, tempfile, shutil, subprocess

BASE = os.environ.get('SCL_BASE_URL', '').rstrip('/')
TOKEN = os.environ.get('SCL_WORKER_TOKEN', '')
ONCE = os.environ.get('SCL_ONCE', '0') == '1'
HERE = os.path.dirname(os.path.abspath(__file__))

if not BASE or not TOKEN:
    sys.exit('需要设置 SCL_BASE_URL 与 SCL_WORKER_TOKEN')


def api(params, post=None, headers=None):
    """调用宝塔 API，返回 dict。token 同时放在 query / header / Authorization，
    兼容 nginx 过滤自定义 header 的情况。"""
    # token 放进 query（最稳，后端 env 允许 GET/REQUEST）
    all_params = dict(params)
    all_params.setdefault('token', TOKEN)
    url = BASE + '/api/job.php?' + urllib.parse.urlencode(all_params)
    h = {
        'X-SCL-Token': TOKEN,
        'Authorization': 'Bearer ' + TOKEN,
        'User-Agent': 'SCLBuildWorker/1.0',
    }
    if headers:
        h.update(headers)
    data = None
    if post is not None:
        post = dict(post)
        post.setdefault('token', TOKEN)   # POST 体里也带一份
        data = urllib.parse.urlencode(post).encode()
        h['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = ''
        try:
            body = e.read().decode('utf-8', 'ignore')[:200]
        except Exception:
            pass
        return {'error': 'HTTP %s %s' % (e.code, body)}
    except Exception as e:
        return {'error': str(e)}


def report_log(job_id, line):
    api({'action': 'log', 'id': job_id, 'line': line})
    print('  ', line)


def find_sdk_src():
    """SDK 源码位置：worker 同级 sdk_src/ 或从站点下载。"""
    p = os.path.join(HERE, 'sdk_src')
    if os.path.isdir(p):
        return p
    return None


def build_dylib(job, sdk_src):
    """在 macOS 上编译成品 dylib，返回 zip 字节。"""
    app_id = job['app_id']
    cfg_url = BASE + '/api/config.php?app_id=' + app_id
    act_url = BASE + '/api/activate.php'
    secret = job['secret']
    customer = job['customer']

    work = tempfile.mkdtemp(prefix='sclbuild_')
    try:
        dst = os.path.join(work, 'sdk_src')
        shutil.copytree(sdk_src, dst)

        report_log(job['id'], '固化客户配置...')
        cfg_file = os.path.join(dst, 'SCLAlertView', 'BackendControl', 'SCLCustomerConfig.swift')
        s = open(cfg_file, encoding='utf-8').read()
        for k, v in {
            '__SCL_CONFIG_URL__': cfg_url,
            '__SCL_ACTIVATE_URL__': act_url,
            '__SCL_APP_ID__': app_id,
            '__SCL_SECRET__': secret,
            '__SCL_POLL__': '300',
        }.items():
            s = s.replace(k, v)
        open(cfg_file, 'w', encoding='utf-8').write(s)

        report_log(job['id'], '切换到 dylib 构建清单...')
        shutil.copy(os.path.join(dst, 'Package-dylib.swift'), os.path.join(dst, 'Package.swift'))

        report_log(job['id'], '编译真机 arm64 dylib...')
        subprocess.check_call(['chmod', '+x', os.path.join(dst, 'build_dylib.sh')])
        # 直接调用构建脚本；脚本内部产出 zip
        env = os.environ.copy()
        proc = subprocess.run(
            [os.path.join(dst, 'build_dylib.sh'), customer, cfg_url, act_url, app_id, secret, '300'],
            cwd=dst, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800
        )
        for line in (proc.stdout or '').splitlines():
            report_log(job['id'], line[:300])
        if proc.returncode != 0:
            raise RuntimeError('build_dylib.sh 退出码 %d' % proc.returncode)

        # 找产物 zip
        zips = [f for f in os.listdir(dst) if f.endswith('_dylib.zip')]
        if not zips:
            # 也可能在 output 里
            for root, _, fs in os.walk(dst):
                zips += [os.path.join(root, f) for f in fs if f.endswith('_dylib.zip')]
            zips = [z for z in zips if os.path.isfile(z)]
        if not zips:
            raise RuntimeError('未找到产物 zip')

        zip_path = zips[0] if os.path.isabs(zips[0]) else os.path.join(dst, zips[0])
        with open(zip_path, 'rb') as f:
            return f.read()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def process_one(job):
    jid = job['id']
    print('领取任务', jid, job['customer'])
    api({'action': 'claim', 'id': jid})
    report_log(jid, '开始构建 ' + job['customer'])

    # 补齐 secret：create 时未带，从 pull 返回的 job 里取（后台 create 已含该客户信息时需带上）
    if not job.get('secret'):
        report_log(jid, '任务缺少 secret，尝试从构建包读取')
        api({'action': 'fail', 'id': jid, 'error': '任务缺少 secret（请在 create 时写入客户密钥）'})
        return

    sdk = find_sdk_src()
    if not sdk:
        api({'action': 'fail', 'id': jid, 'error': 'worker 旁未找到 sdk_src 目录'})
        return

    try:
        report_log(jid, '编译 dylib（macOS）...')
        zip_bytes = build_dylib(job, sdk)
        report_log(jid, '回传产物 ' + str(len(zip_bytes) // 1024) + 'KB')
        b64 = base64.b64encode(zip_bytes).decode()
        # 用 POST 回传
        ok = api({'action': 'finish', 'id': jid}, post={'file': b64})
        if ok.get('error'):
            raise RuntimeError('回传失败: ' + str(ok))
        print('完成', jid)
    except Exception as e:
        api({'action': 'fail', 'id': jid, 'error': str(e)[:300]})
        print('失败', jid, e)


def main():
    print('SCL 构建 worker 启动', BASE)
    hb_count = 0
    while True:
        # 每轮先上报心跳（让网页能看到节点是否在线）
        hb = api({'action': 'heartbeat', 'v': '1.1'})
        if hb.get('error'):
            print('心跳失败:', hb['error'])
        r = api({'action': 'pull'})
        if r.get('error'):
            print('API 错误:', r['error'])
            time.sleep(10)
            continue
        job = r.get('job')

        # 若 dispatch 指定了 job_id，直接拉取该任务（不依赖队列顺序）
        forced = os.environ.get('SCL_JOB_ID', '').strip()
        if forced:
            one = api({'action': 'getjob', 'id': forced})
            if one.get('job') and one['job'].get('status') == 'queued':
                job = one['job']
            elif one.get('job') and one['job'].get('status') == 'building':
                print('任务已在构建中，跳过:', forced)
                job = None
            else:
                print('指定任务不可用:', one)
                job = None

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
