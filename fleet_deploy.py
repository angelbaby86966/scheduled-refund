#!/usr/bin/env python3
# 批量下发 IPES 完整部署命令到多台 SWAS 实例（云助手，后台异步）
#
# 用法:
#   python3 fleet_deploy.py <凭证文件> <实例清单> [--ak ] [--sk ] [--isp 电信] [--num-dirs 12]
#                           [--jwt <JWT>] [--dry-run] [--workers 10]
#
# 凭证文件: 第1行 AK，第2行 SK
# 实例清单: 每行  "<region> <instanceId> [name]"
#
# 会顺序对每台下发：下载 r9 脚本 -> 后台 nohup 跑完整流程 -> 打印 PID
import json, sys, time, argparse, concurrent.futures as cf
from aliyunsdkcore.client import AcsClient
from aliyunsdkswas_open.request.v20200601.RunCommandRequest import RunCommandRequest
from aliyunsdkswas_open.request.v20200601.DescribeInvocationResultRequest import DescribeInvocationResultRequest

SCRIPT_URL = "https://ghproxy.net/https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/ipes_deploy_full.sh"


def build_cmd(ak, sk, isp, num_dirs, jwt, extra):
    parts = [
        f'curl -fsSL {SCRIPT_URL} -o /root/ipes_full.sh',
        "sed -i 's|^mirrorlist=|#mirrorlist=|g;s|^#\\?baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null",
    ]
    if jwt:
        parts.append(f"export NODE_ACTIVATE_TOKEN='{jwt}'")
    parts.append(
        f"nohup setsid bash /root/ipes_full.sh --ak {ak} --sk {sk} --isp {isp} "
        f"--num-dirs {num_dirs} {extra} >/var/log/ipes_nohup.log 2>&1 </dev/null & echo \"已后台启动 PID=$!\""
    )
    return "; ".join(parts)


def dispatch(client, region, iid, cmd):
    try:
        req = RunCommandRequest()
        req.set_endpoint(f"swas.{region}.aliyuncs.com"); req.set_accept_format("json")
        req.set_InstanceId(iid); req.set_Name("dep" + str(int(time.time())))
        req.set_Type("RunShellScript"); req.set_CommandContent(cmd); req.set_Timeout(60)
        inv = json.loads(client.do_action_with_exception(req)).get("InvokeId")
    except Exception as e:
        return "ERR " + str(getattr(e, "get_error_msg", lambda: repr(e))())[:90]
    for _ in range(20):
        time.sleep(2)
        r2 = DescribeInvocationResultRequest()
        r2.set_endpoint(f"swas.{region}.aliyuncs.com"); r2.set_accept_format("json")
        r2.set_InstanceId(iid); r2.set_InvokeId(inv)
        try:
            import base64
            st = json.loads(client.do_action_with_exception(r2)).get("InvocationResult", {})
        except Exception:
            continue
        if st.get("InvocationStatus") in ("Success", "Failed"):
            return base64.b64decode(st.get("Output", "")).decode(errors="replace").strip()
    return "TIMEOUT"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cred"); ap.add_argument("list")
    ap.add_argument("--ak", default="06d78b19bd0d9fc0aa300c6d")
    ap.add_argument("--sk", default="16d6c46443308e62bb51f22c074a90ed")
    ap.add_argument("--isp", default="电信")
    ap.add_argument("--num-dirs", default="12")
    ap.add_argument("--jwt", default="")
    ap.add_argument("--extra", default="--skip-olmt")
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    with open(a.cred) as f:
        AK = f.readline().strip(); SK = f.readline().strip()

    targets = []
    with open(a.list) as f:
        for line in f:
            p = line.split()
            if len(p) >= 2 and not p[0].startswith("#"):
                targets.append((p[0], p[1], p[2] if len(p) > 2 else p[1][:12]))

    cmd = build_cmd(a.ak, a.sk, a.isp, a.num_dirs, a.jwt, a.extra)
    if a.dry_run:
        print("命令预览:\n" + cmd)
        print(f"\n目标 {len(targets)} 台")
        return

    print(f"下发 {len(targets)} 台（并发 {a.workers}）...\n")
    clients = {}

    def job(t):
        region, iid, name = t
        c = clients.setdefault(region, AcsClient(AK, SK, region))
        return name, iid, dispatch(c, region, iid, cmd)

    ok = 0
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for name, iid, out in ex.map(job, targets):
            good = "PID=" in out
            ok += 1 if good else 0
            print(f"[{'OK ' if good else 'FAIL'}] {name:20s} {iid}  {out[:80]}")
    print(f"\n完成：成功下发 {ok}/{len(targets)} 台。看进度：tail -f /var/log/ipes_nohup.log（各机器上）")


if __name__ == "__main__":
    main()
