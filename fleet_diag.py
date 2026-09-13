#!/usr/bin/env python3
# 批量巡检 SWAS 实例：docker / ipes 容器 / happ / 绑定与流转日志
# 用法: fleet_diag.py <cred_file> "<region:iid,...>" ...
import json, base64, time, sys, concurrent.futures as cf
from aliyunsdkcore.client import AcsClient
from aliyunsdkswas_open.request.v20200601.RunCommandRequest import RunCommandRequest
from aliyunsdkswas_open.request.v20200601.DescribeInvocationResultRequest import DescribeInvocationResultRequest

CRED = sys.argv[1]
TARGETS = []
with open(sys.argv[2]) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        region, iid = line.split()[0], line.split()[1]
        name = line.split()[2] if len(line.split()) > 2 else ""
        TARGETS.append((region, iid, name))

with open(CRED) as f:
    AK = f.readline().strip(); SK = f.readline().strip()

CMD = (
    'echo "SN=$(cat /etc/.mac 2>/dev/null)"'
    ';echo "HOSTNAME=$(hostname)"'
    ';echo "DOCKER=$(systemctl is-active docker 2>/dev/null)"'
    ';echo "IPES=$(docker ps --format {{.Names}} 2>/dev/null | tr "\\n" ",")"'
    ';echo "HAPP=$(pgrep -c -f happ 2>/dev/null)"'
    ';echo "--nohup--";tail -n 6 /var/log/ipes_nohup.log 2>/dev/null'
    ';echo "--deploy--";grep -aE "步骤|成功|错误|失败|执行完毕" /var/log/ipes_full_deploy.log 2>/dev/null | tail -n 8'
)


def run(region, iid):
    client = AcsClient(AK, SK, region)
    try:
        req = RunCommandRequest()
        req.set_endpoint(f"swas.{region}.aliyuncs.com")
        req.set_accept_format("json")
        req.set_InstanceId(iid)
        req.set_Name("dg-" + str(int(time.time())))
        req.set_Type("RunShellScript")
        req.set_CommandContent(CMD)
        req.set_Timeout(60)
        inv = json.loads(client.do_action_with_exception(req)).get("InvokeId")
    except Exception as e:
        return iid, "RUNCMD_ERROR " + str(getattr(e, "get_error_msg", lambda: repr(e))())
    for _ in range(20):
        time.sleep(2)
        r2 = DescribeInvocationResultRequest()
        r2.set_endpoint(f"swas.{region}.aliyuncs.com")
        r2.set_accept_format("json")
        r2.set_InstanceId(iid)
        r2.set_InvokeId(inv)
        try:
            st = json.loads(client.do_action_with_exception(r2)).get("InvocationResult", {})
        except Exception:
            continue
        if st.get("InvocationStatus") in ("Success", "Failed"):
            return iid, base64.b64decode(st.get("Output", "")).decode(errors="replace")
    return iid, "TIMEOUT"


with cf.ThreadPoolExecutor(max_workers=12) as ex:
    futs = {ex.submit(run, r, i): (r, i, n) for r, i, n in TARGETS}
    for fu in cf.as_completed(futs):
        r, i, n = futs[fu]
        try:
            _, out = fu.result()
        except Exception as e:
            out = "EXC " + repr(e)
        print("=" * 26, n, i, "=" * 26)
        print(out.strip())
        print()
