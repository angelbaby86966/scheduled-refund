#!/usr/bin/env python3
# 紧凑巡检：一行一台，看是否跑过我们的部署脚本
import json, base64, time, sys, concurrent.futures as cf
from aliyunsdkcore.client import AcsClient
from aliyunsdkswas_open.request.v20200601.RunCommandRequest import RunCommandRequest
from aliyunsdkswas_open.request.v20200601.DescribeInvocationResultRequest import DescribeInvocationResultRequest

with open(sys.argv[1]) as f:
    AK = f.readline().strip(); SK = f.readline().strip()
TARGETS = []
with open(sys.argv[2]) as f:
    for line in f:
        p = line.split()
        if len(p) >= 2:
            TARGETS.append((p[0], p[1], p[2] if len(p) > 2 else ""))

CMD = (
    'printf "happ=%s ipes=%s nohup=%s deploy=%s last=%s\\n"'
    ' "$(pgrep -c -f happ 2>/dev/null)"'
    ' "$(docker ps --format {{.Names}} 2>/dev/null | tr "\\n" "/")"'
    ' "$([ -f /var/log/ipes_nohup.log ] && echo Y || echo N)"'
    ' "$([ -f /var/log/ipes_full_deploy.log ] && echo Y || echo N)"'
    ' "$(tail -n 1 /var/log/ipes_full_deploy.log 2>/dev/null | cut -c1-70)"'
)


def run(region, iid, name):
    c = AcsClient(AK, SK, region)
    try:
        req = RunCommandRequest()
        req.set_endpoint(f"swas.{region}.aliyuncs.com"); req.set_accept_format("json")
        req.set_InstanceId(iid); req.set_Name("dg" + str(int(time.time())))
        req.set_Type("RunShellScript"); req.set_CommandContent(CMD); req.set_Timeout(40)
        inv = json.loads(c.do_action_with_exception(req)).get("InvokeId")
    except Exception as e:
        return f"{name:20s} {iid}  ERR {str(getattr(e,'get_error_msg',lambda:repr(e))())[:60]}"
    for _ in range(15):
        time.sleep(2)
        r2 = DescribeInvocationResultRequest()
        r2.set_endpoint(f"swas.{region}.aliyuncs.com"); r2.set_accept_format("json")
        r2.set_InstanceId(iid); r2.set_InvokeId(inv)
        try:
            st = json.loads(c.do_action_with_exception(r2)).get("InvocationResult", {})
        except Exception:
            continue
        if st.get("InvocationStatus") in ("Success", "Failed"):
            out = base64.b64decode(st.get("Output", "")).decode(errors="replace").strip()
            return f"{name:20s} {iid}  {out}"
    return f"{name:20s} {iid}  TIMEOUT"


with cf.ThreadPoolExecutor(max_workers=16) as ex:
    for res in ex.map(lambda t: run(*t), TARGETS):
        print(res)
