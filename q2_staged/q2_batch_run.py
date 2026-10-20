#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""q2_batch_run.py — 舟翼云 q2（业务41）批量分阶段编排器（控制端）。

把 200 台轻量应用服务器（SWAS）按波次扇出执行 q2_stage.sh 的三个阶段：

    Stage A bind    下发 Q2_STAGE=bind   → 轮询等真正跑完（首次 5-10 分钟）
    Stage B flow    下发 Q2_STAGE=flow   → 轮询等完成（<30s）
    Stage C deploy  下发 Q2_STAGE=deploy → 下发完即可返回（deploy 内部后台化）

Stage C 不等部署真正跑完：远端 q2_stage.sh 的 deploy 阶段是 setsid 后台化 +
立即返回，真进度在 /var/log/ipes_nohup.log，由运维按需再轮询状态。

⚠️ 提交节流是硬需求，不是优化项：
   阿里云 SWAS 有【账号级】频控。短时间内连续 5-8 次 API 调用就会被封锁约 17 分钟，
   且被封锁时 RunCommand 直接报错、无法靠重试解决。因此所有提交之间强制 sleep，
   并发度默认压到 2。宁可慢，不要触发封禁。

取结果姿势（踩过的坑）：
   用 DescribeInvocationResultRequest，递归找 "Output" 字段（_find(d,"Output")）再 base64 解码。
   DescribeCommandInvocationsRequest 挖不到输出，不要用。

用法：
    # 全量三阶段（默认读 instances.json）
    python3 q2_batch_run.py --instances instances.json

    # 只跑某几个阶段
    python3 q2_batch_run.py --instances instances.json --stages bind,flow

    # 调紧/调松节流
    python3 q2_batch_run.py -i instances.json --concurrency 2 --submit-gap 8

    # 只看会下发什么，不真调 API（默认行为，必须显式 --execute 才真跑）
    python3 q2_batch_run.py -i instances.json --execute

安全：默认 dry-run。必须显式 --execute 才会真正调用阿里云 API。
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import json
import os
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

# ── 远端脚本落点与分发源 ──
REMOTE_SCRIPT = "/root/q2_stage.sh"
# 发布时由 publish_q2_staged.py 把 SCRIPT_PINNED_URL 回填为「本次 commit 的
# jsDelivr 钉版本 URL」。主源走钉版本 URL：jsDelivr @main 实测 404，raw@main
# 虽可取但随 main 漂移；钉 commit 后 下发/自举/兜底 三者共用同一 URL，可复现。
SCRIPT_SOURCE_RAW = (
    "https://raw.githubusercontent.com/angelbaby86966/scheduled-refund/main/q2_staged/q2_stage.sh"
)
SCRIPT_PINNED_URL = ""  # 发布回填：https://cdn.jsdelivr.net/gh/<repo>@<sha>/q2_staged/q2_stage.sh
SCRIPT_SOURCE = SCRIPT_PINNED_URL or SCRIPT_SOURCE_RAW
SCRIPT_FALLBACKS = tuple(
    dict.fromkeys(u for u in (SCRIPT_SOURCE_RAW, SCRIPT_PINNED_URL) if u)
)

# 云助手命令进入终态的取值
TERMINAL_STATUS = {
    "Success", "Finished", "Failed", "PartialFailed",
    "Stopped", "Error", "RunFailed", "Timeout",
}

# 远端 marker（用于结果判定，与 q2_stage.sh 保持一致）
MARK_DIR = "/etc/q2"


@dataclass
class Instance:
    """一台目标轻量服务器。"""

    iid: str
    region: str
    name: str = ""

    @property
    def endpoint(self) -> str:
        """SWAS 区域 endpoint。"""
        return f"swas.{self.region}.aliyuncs.com"

    def label(self) -> str:
        """人类可读标识。"""
        return f"{self.name or self.iid[:12]}[{self.iid[:8]}/{self.region}]"


@dataclass
class StageResult:
    """单台单阶段结果。"""

    inst: Instance
    stage: str
    ok: bool = False
    status: str = ""
    output: str = ""
    elapsed: float = 0.0
    error: str = ""

    def brief(self) -> str:
        """单行摘要。"""
        if self.error:
            return f"  ✗ {self.inst.label()} {self.stage} error={self.error}"
        return f"  {'✓' if self.ok else '✗'} {self.inst.label()} {self.stage} status={self.status}"


@dataclass
class Throttle:
    """账号级提交节流器。

    线程安全。同时约束：
      * 同一时刻在飞行的请求数（semaphore）
      * 两次提交之间的最小间隔（gap）
    SWAS 频控是账号级的，因此 gap 用一把全局锁串行化，不按线程各自计算。
    """

    gap: float = 5.0
    concurrency: int = 2
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _sem: threading.Semaphore = field(init=False, repr=False)
    _last: float = field(default=0.0, repr=False)
    _calls: int = field(default=0, repr=False)

    def __post_init__(self) -> None:
        """按并发度初始化信号量。"""
        self._sem = threading.Semaphore(max(1, self.concurrency))

    def wait(self, sleeper: Callable[[float], None] = time.sleep) -> None:
        """获取一个提交令牌，并在必要时补足间隔。"""
        self._sem.acquire()
        with self._lock:
            now = time.monotonic()
            elapsed = now - self._last if self._last else self.gap
            if elapsed < self.gap:
                sleeper(self.gap - elapsed)
            self._last = time.monotonic()
            self._calls += 1

    def release(self) -> None:
        """归还令牌。"""
        self._sem.release()

    @property
    def calls(self) -> int:
        """累计节流过的提交次数。"""
        return self._calls


def _find(obj: Any, key: str) -> Any:
    """递归查找第一个命中 key 的值（swas_helper 里验证过的写法）。

    RunCommand / DescribeInvocationResult 的返回结构层级不稳定，字段位置会变，
    所以必须递归找，不能假设固定路径。
    """
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            r = _find(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find(v, key)
            if r is not None:
                return r
    return None


class DispatchError(RuntimeError):
    """下发失败，携带分类后的可执行建议。"""

    def __init__(self, kind: str, detail: str) -> None:
        """kind: permission | param | throttling | unknown"""
        super().__init__(detail)
        self.kind = kind
        self.detail = detail


def classify_error(exc: BaseException) -> DispatchError:
    """把 SDK 异常分类成三类并给出可执行建议。

    实测（2026-10）：网关【先查权限再查参数】，所以
      · 403 + 空body + 无 RequestId = 该 RAM 身份没有 RunCommand 权限
      · 400 + InvalidCommandType   = 参数名写错（应CommandType 而非 Type）
      · 429 / Throttling          = 账号级频控，退避重试
    不区分的话，用户只会看到笼统的「失败」。
    """
    msg = str(exc)
    low = msg.lower()
    code = ""
    for attr in ("status_code", "code", "http_status"):
        v = getattr(exc, attr, None)
        if v:
            code = str(v)
            break
    rid = getattr(exc, "request_id", "") or getattr(exc, "RequestId", "") or ""
    has_rid = bool(rid) or ("RequestId" in msg)

    if "throttl" in low or "429" in code or "frequency" in low or "too many" in low:
        return DispatchError(
            "throttling",
            f"账号级频控（Throttling/429）→ 退避重试；调低 --concurrency、调高 --interval。详情：{msg[:200]}",
        )
    if "invalidcommandtype" in low:
        return DispatchError(
            "param",
            "参数名错误（InvalidCommandType）→ RunCommand 必须用 "
            f"add_query_param('CommandType','RunShell')，不是 set_Type()。详情：{msg[:200]}",
        )
    if "403" in msg or "forbidden" in low or "not authorized" in low or "no permission" in low:
        if not has_rid:
            return DispatchError(
                "permission",
                "403 且响应体为空/无 RequestId → 该 RAM 身份【没有 RunCommand 权限】"
                "（网关先查权限再查参数，连参数错都报不出来）。"
                "解决：给该 RAM 身份加 RunCommand 权限，或换有权限的账号；"
                "只想核对不想下发请用 --check-only。",
            )
        return DispatchError("permission", f"403 Forbidden（有 RequestId）→ 权限不足。详情：{msg[:200]}")
    if "400" in msg or "invalid" in low:
        return DispatchError("param", f"请求参数被拒（400）→ 检查参数名/取值。详情：{msg[:200]}")
    return DispatchError("unknown", f"{type(exc).__name__}: {msg[:200]}")


class SwasClient:
    """SWAS 云助手最小封装：RunCommand + 轮询 + 取结果。"""

    def __init__(self, ak: str, sk: str, region: str) -> None:
        """按 region 构造 client（endpoint 随 region 变）。"""
        from aliyunsdkcore.client import AcsClient  # 延迟导入：dry-run 不需要 SDK

        self.region = region
        self._cl = AcsClient(ak, sk, region)
        try:
            self._cl.set_endpoint(f"swas.{region}.aliyuncs.com")
        except Exception:
            pass

    def _action(self, req: Any) -> Dict[str, Any]:
        """执行请求并返回 dict。"""
        from aliyunsdkcore.acs_exception.exceptions import ClientException, ServerException

        req.set_endpoint(f"swas.{self.region}.aliyuncs.com")
        try:
            raw = self._cl.do_action_with_exception(req)
        except (ServerException, ClientException) as e:
            raise classify_error(e) from e
        return json.loads(raw) if isinstance(raw, (str, bytes)) else dict(raw)

    def run_command(self, iid: str, content: str, name: str, timeout: int) -> str:
        """下发命令，返回 InvokeId。"""
        from aliyunsdkswas_open.request.v20200601 import RunCommandRequest

        req = RunCommandRequest.RunCommandRequest()
        req.set_CommandContent(content)
        req.set_InstanceId(iid)
        req.set_Name(name)
        req.set_Timeout(timeout)
        # ⚠️ 参数名必须是 CommandType（不是 Type）：
        #    实测 set_Type() 发的是 query 参数 Type，服务端返回 400 InvalidCommandType。
        req.add_query_param("CommandType", "RunShell")
        req.add_query_param("Type", "RunShellScript")  # 兼容仍读 Type 的旧服务端
        req.set_accept_format("json")
        d = self._action(req)
        inv = d.get("InvokeId") or _find(d, "InvokeId")
        if not inv:
            raise DispatchError("param", f"NO_INVOKE_ID: {str(d)[:200]}")
        return str(inv)

    def permission_probe(self, iid: str) -> Tuple[bool, str]:
        """下发前权限探针：发一条极小的 echo。

        目的：在扇出到 200 台【之前】确认账号有 RunCommand 权限，
        否则会拿到 200 条空 body 的 403，排查成本极高。
        """
        try:
            self.run_command(iid, "echo Q2_PERM_PROBE", "q2-perm-probe", 30)
            return True, "OK：账号具备 RunCommand 权限"
        except DispatchError as e:
            return False, f"[{e.kind}] {e.detail}"
        except Exception as e:  # noqa: BLE001
            return False, f"[unknown] {str(e)[:200]}"

    def wait_done(self, iid: str, inv: str, deadline: float, poll: float) -> str:
        """轮询到终态，返回 InvocationStatus。"""
        from aliyunsdkswas_open.request.v20200601 import DescribeCommandInvocationsRequest

        st = "Unknown"
        while time.monotonic() < deadline:
            time.sleep(poll)
            req = DescribeCommandInvocationsRequest.DescribeCommandInvocationsRequest()
            req.set_InvokeId(inv)
            req.set_InstanceId(iid)
            try:
                d = self._action(req)
            except RuntimeError:
                continue  # 轮询期偶发失败可重试，不判死
            st = _find(d, "InvocationStatus") or st
            if st in TERMINAL_STATUS:
                return str(st)
        return f"{st}(poll_timeout)"

    def result(self, iid: str, inv: str) -> Dict[str, Any]:
        """取执行结果：递归找 Output 再 base64 解码。"""
        from aliyunsdkswas_open.request.v20200601 import DescribeInvocationResultRequest

        req = DescribeInvocationResultRequest.DescribeInvocationResultRequest()
        req.set_InvokeId(inv)
        req.set_InstanceId(iid)
        d = self._action(req)
        raw = _find(d, "Output") or ""
        try:
            out = base64.b64decode(raw).decode("utf-8", "replace")
        except Exception:
            out = str(raw)
        exit_code = _find(d, "ExitCode")
        return {
            "output": out,
            "exit_code": exit_code,
            "invoke_status": _find(d, "InvocationStatus") or "",
        }


def build_command(stage: str, script_url: str, remote: str) -> str:
    """拼一条幂等、可重复下发的远端命令。

    远端做三件事：多源补脚本（含指纹校验）→ 幂等执行 → 打印 marker 便于控制端判定。
    绝不内联 JWT（token 外置，见 q2_stage.sh 头部说明）。
    """
    urls = " ".join(f'"{u}"' for u in dict.fromkeys((script_url, *SCRIPT_FALLBACKS)))
    lines = [
        "set -u; export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        f'S="{remote}"',
        # 多源依次尝试；每个候选都要过「非 HTML/非空/够长 + 指纹 + 语法」四道校验
        f'if [ ! -s "$S" ]; then for u in {urls}; do '
        f'curl -fsSL --connect-timeout 5 -m 60 "$u" -o "$S" 2>/dev/null || continue; '
        # 指纹：必须是 q2_stage.sh 本体（含其独有标记），且不能是 HTML 错误页
        f'grep -q "Q2_STAGE" "$S" || continue; '
        f'head -c 2000 "$S" | grep -qiE "<!DOCTYPE html|<html|404: Not Found" && continue; '
        f'bash -n "$S" 2>/dev/null || continue; '
        f'echo "SRC_OK=$u"; break; done; fi',
        f'[ -s "$S" ] || {{ echo "DOWNLOAD_FAILED"; exit 1; }}',
        f'grep -q "Q2_STAGE" "$S" || {{ echo "FINGERPRINT_FAILED"; exit 1; }}',
        f'chmod +x "$S" 2>/dev/null; bash -n "$S" || {{ echo "SYNTAX_FAILED"; exit 1; }}',
        f'Q2_STAGE={stage} bash "$S" 2>&1; rc=$?',
        f'echo "RC=$rc"',
        # 控制端据此判定成功，避免只凭 InvocationStatus=Success（脚本内部可能已标失败）
        f'echo "MARK deploy.status=$(cat {MARK_DIR}/deploy.status 2>/dev/null || echo none)"',
        f'echo "MARK bind=$(test -f {MARK_DIR}/stage_bind.done && echo yes || echo no)"',
        f'echo "MARK flow=$(test -f {MARK_DIR}/stage_flow.done && echo yes || echo no)"',
        "exit $rc",
    ]
    return " ; ".join(lines)


def verify_script_url(urls: Sequence[str], timeout: int = 20) -> Tuple[bool, str]:
    """下发前在控制端先校验 q2_stage.sh 真的能取到且内容正确。

    这是防「把下载失败的命令推给 200 台机器」的最后一道闸：
    远端下载失败要等200 台各自失败才发现，代价太大。
    校验项与远端一致：可取到 + 指纹命中 + 非 HTML + 语法正确。
    """
    import urllib.error
    import urllib.request

    detail = ""
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "q2-batch-run/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except (urllib.error.URLError, OSError, ValueError) as e:
            detail = f"{type(e).__name__}: {str(e)[:80]}"
            print(f"  ✗ 取不到：{u}  ({detail})")
            continue
        text = raw.decode("utf-8", "replace")
        if "<!DOCTYPE html" in text[:2000] or "<html" in text[:2000].lower():
            detail = "返回 HTML 错误页"
            print(f"  ✗ 内容是 HTML：{u}")
            continue
        if "Q2_STAGE" not in text:
            detail = "指纹不匹配（缺 Q2_STAGE 标记）"
            print(f"  ✗ 指纹不匹配：{u}  ({detail})")
            continue
        if len(raw) < 512:
            detail = f"内容过短（{len(raw)} 字节），疑似截断"
            print(f"  ✗ 过短：{u}  ({detail})")
            continue
        print(f"  ✅ 源可用且通过校验：{u}  ({len(raw)} 字节)")
        return True, u
    return False, detail or "全部源均不可用"


def expected_ok(stage: str, output: str) -> bool:
    """按远端输出判定该阶段是否真成功（反「假成功」）。

    只看 InvocationStatus=Success 是不够的：脚本内部可能已标 BIND_FAILED 却仍以 0 退出，
    因此必须同时校验 RC=0 和该阶段的成功标记。
    """
    if "RC=0" not in output:
        return False
    if stage == "bind":
        return ("BIND_OK" in output) or ("ALREADY_BOUND" in output)
    if stage == "flow":
        return ("FLOW_OK" in output) or ("ALREADY_FLOWED" in output)
    if stage == "deploy":
        # deploy 只要求「已成功下发」，后台真跑完不算本次成败
        return any(k in output for k in ("DEPLOY_DISPATCHED", "ALREADY_DEPLOYED", "DEPLOY_ALREADY_RUNNING"))
    return False


def run_one(
    inst: Instance,
    stage: str,
    cmd: str,
    throttle: Throttle,
    poll: float,
    stage_timeout: int,
    client_factory: Callable[[str, str, str], Any],
    ak: str,
    sk: str,
    interval: float = 0.0,
) -> StageResult:
    """在单台实例上跑一个阶段（含节流、错峰、轮询、取结果）。"""
    res = StageResult(inst=inst, stage=stage)
    t0 = time.monotonic()
    # 每台之间额外错峰：200 台一次性打过去必然触发账号级频控
    if interval > 0:
        time.sleep(interval)
    try:
        throttle.wait()
        try:
            cli = client_factory(ak, sk, inst.region)
            inv = cli.run_command(inst.iid, cmd, f"q2-{stage}-{int(t0)}", min(stage_timeout, 3600))
            st = cli.wait_done(inst.iid, inv, t0 + stage_timeout, poll)
            res.status = st
            info = cli.result(inst.iid, inv)
            res.output = info["output"]
            res.ok = st in ("Success", "Finished") and expected_ok(stage, res.output)
            if st not in ("Success", "Finished"):
                res.error = f"status={st}"
            elif not res.ok:
                res.error = "output_mismatch"
        finally:
            throttle.release()
    except Exception as e:  # noqa: BLE001 — 单台失败不能拖垮整批
        res.error = f"{type(e).__name__}: {str(e)[:120]}"
    res.elapsed = time.monotonic() - t0
    return res


def run_stage(
    stage: str,
    instances: Sequence[Instance],
    throttle: Throttle,
    poll: float,
    stage_timeout: int,
    client_factory: Callable[[str, str, str], Any],
    ak: str,
    sk: str,
    execute: bool,
    script_url: str,
    remote: str,
    interval: float = 0.0,
) -> List[StageResult]:
    """跑一个阶段：扇出下发 + 等全部收敛。"""
    cmd = build_command(stage, script_url, remote)
    print(f"\n===== Stage {stage} · {len(instances)} 台 =====")
    if not execute:
        print("DRY-RUN（未加 --execute，不调用阿里云 API）。示例命令：")
        print("  " + cmd[:200] + ("..." if len(cmd) > 200 else ""))
        print(f"预计最慢耗时 ≈ {stage_timeout}s/台，提交间隔 {throttle.gap}s，并发 {throttle.concurrency}")
        return [StageResult(inst=i, stage=stage, ok=True, status="DRYRUN") for i in instances]

    print(f"下发中（并发={throttle.concurrency}，提交间隔={throttle.gap}s，"
          f"每台错峰={interval}s，超时={stage_timeout}s）… 提示：SWAS 账号级频控，请勿调高并发")
    results: List[StageResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, throttle.concurrency)) as pool:
        futs = {
            pool.submit(run_one, inst, stage, cmd, throttle, poll, stage_timeout,
                        client_factory, ak, sk, interval): inst
            for inst in instances
        }
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            results.append(r)
            print(r.brief())
    results.sort(key=lambda r: r.inst.iid)
    ok = sum(1 for r in results if r.ok)
    print(f"Stage {stage} 小结: {ok}/{len(results)} 成功")
    return results


def load_instances(path: str) -> List[Instance]:
    """读实例清单 JSON。

    支持两种格式：
      [{"iid": "...", "region": "cn-hangzhou", "name": "opt-1"}, ...]
      {"cn-hangzhou": ["iid1", "iid2"], ...}
    """
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    out: List[Instance] = []
    if isinstance(data, dict):
        for region, iids in data.items():
            for i in iids:
                out.append(Instance(iid=str(i), region=region))
    elif isinstance(data, list):
        for it in data:
            if isinstance(it, str):
                out.append(Instance(iid=it, region="cn-hangzhou"))
            else:
                out.append(Instance(
                    iid=str(it["iid"]),
                    region=str(it.get("region") or "cn-hangzhou"),
                    name=str(it.get("name") or ""),
                ))
    else:
        raise ValueError("instances.json 格式不支持：需为 list 或 dict")
    seen = set()
    uniq = []
    for i in out:
        if i.iid in seen:
            continue
        seen.add(i.iid)
        uniq.append(i)
    return uniq


def run_check_only(instances: Sequence[Instance]) -> int:
    """只读核对：不调用 RunCommand，因此【不需要 RunCommand 权限】。

    适用场景：账号的 RAM 身份没有 RunCommand 权限（实测 403 空 body），
    但仍需要核对平台侧状态。此时只走平台 API + JWT（无账号级频控）。

    输出每台在平台上的 nodeID / stage / 业务ID，便于人工判断是否需要补部署。
    """
    admin = os.environ.get("Q2_ADMIN_API", "https://admin.zhouyi.top").rstrip("/")
    tok = os.environ.get("Q2_JWT", "")
    if not tok:
        jf = os.environ.get("Q2_JWT_FILE", "/etc/q2/jwt")
        if os.path.isfile(jf):
            tok = open(jf, encoding="utf-8").read().strip()
    print("\n===== 只读核对（不调用 RunCommand）=====")
    if not tok:
        print("[WARN] 未提供 JWT（Q2_JWT 或 Q2_JWT_FILE），无法查询平台侧；"
              "仍会输出本地可达性检查结果。")
    print(f"{'实例':<46} {'nodeID':<34} 结论")
    print("-" * 100)
    bad = 0
    for inst in instances:
        node = f"{inst.name or ''}{inst.iid[:12]}[{inst.region}]"
        if not tok:
            print(f"{node:<46} {'-':<34} SKIP_NO_JWT")
            continue
        try:
            import urllib.request
            req = urllib.request.Request(
                f"{admin}/api/edgeNode/list?pageSize=200",
                headers={"X-Token": tok, "Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8", "replace"))
            rows = _find(data, "rows") or _find(data, "list") or []
            hit = next((r for r in rows if isinstance(r, dict)
                        and str(r.get("hostname", "")).startswith(inst.iid[:8])), None)
            if hit:
                print(f"{node:<46} {str(hit.get('hostname'))[:34]:<34} "
                      f"stage={hit.get('stage')} status={hit.get('status')} "
                      f"biz={hit.get('businessId') or 'None'} usage={hit.get('resourceUsage')}")
                if hit.get("businessId") in (None, "", "None"):
                    bad += 1
            else:
                print(f"{node:<46} {'-':<34} NOT_FOUND_IN_PLATFORM")
                bad += 1
        except Exception as e:  # noqa: BLE001
            print(f"{node:<46} {'-':<34} ERROR {type(e).__name__}: {str(e)[:60]}")
            bad += 1
    print("-" * 100)
    print(f"需要关注: {bad} 台（biz=None 或未找到）")
    print("提示：这些机器很可能没做真SN 回填 → 用有 RunCommand 权限的账号跑 --stages deploy 补齐。")
    return 1 if bad else 0


def summarize(all_results: Dict[str, List[StageResult]]) -> int:
    """打印总汇总，返回失败台数。"""
    print("\n" + "=" * 64)
    print("总汇总")
    print("=" * 64)
    bad = 0
    for stage, rs in all_results.items():
        ok = sum(1 for r in rs if r.ok)
        print(f"{stage:8s}: {ok}/{len(rs)} 成功")
        for r in rs:
            if not r.ok:
                bad += 1
                print(f"   ✗ {r.inst.iid[:12]} {r.inst.region} {r.error} ({r.elapsed:.0f}s)")
                for line in r.output.strip().splitlines()[-6:]:
                    print(f"       | {line}")
    print("-" * 64)
    print(f"失败记录数: {bad}")
    print("提示：deploy 阶段只验「下发成功」；真部署进度看远端 /var/log/ipes_nohup.log")
    return bad


def selftest_throttle() -> int:
    """节流自检（不碰网络）：断言提交之间确实 sleep 了。

    用假 sleeper 记录 sleep 时长，验证 N 次提交至少产生 N-1 次补间隔调用，
    且每次补间隔时长 ≥ gap - 容差。
    """
    print("== selftest: Throttle 提交节流 ==")
    for gap, conc, n in ((5.0, 3, 8), (8.0, 2, 6), (0.5, 4, 10)):
        slept: List[float] = []
        th = Throttle(gap=gap, concurrency=conc)
        for _ in range(n):
            th.wait(sleeper=slept.append)
            th.release()
        expect_calls = n - 1
        got = len(slept)
        ok_cnt = got >= expect_calls
        ok_gap = all(s > 0 for s in slept)
        # 首次调用不 sleep（last=0），之后每次都应补足
        print(f"  gap={gap} conc={conc} n={n}: sleep 次数={got} (期望≥{expect_calls}) "
              f"最小补间隔={min(slept) if slept else 0:.3f}s -> "
              f"{'PASS' if ok_cnt and ok_gap else 'FAIL'}")
        if not (ok_cnt and ok_gap):
            return 1
    print("PASS: throttle 确实在提交之间 sleep\n")
    return 0


def selftest_output_judge() -> int:
    """输出判据自检：确保假成功会被判失败。"""
    print("== selftest: 阶段成功判据（反假成功）==")
    cases = [
        ("bind", "[..] BIND_OK nodeID=abc\nRC=0", True),
        ("bind", "[..] ALREADY_BOUND nodeID=abc\nRC=0", True),
        ("bind", "[..] BIND_FAILED\nRC=1", False),
        ("flow", "FLOW_OK nodeID=abc\nRC=0", True),
        ("flow", "ALREADY_FLOWED\nRC=0", True),
        ("flow", "FLOW_REQUIRES_BIND ...\nRC=1", False),
        ("deploy", "DEPLOY_DISPATCHED pid=123\nRC=0", True),
        ("deploy", "ALREADY_DEPLOYED\nRC=0", True),
        ("deploy", "DEPLOY_FAILED status=failed:self_path\nRC=1", False),
        ("bind", "RC=0", False),  # 无任何标记 → 判失败
    ]
    bad = 0
    for stage, out, want in cases:
        got = expected_ok(stage, out)
        flag = "PASS" if got == want else "FAIL"
        if got != want:
            bad += 1
        print(f"  [{flag}] stage={stage:6s} want={want} got={got}  «{out.splitlines()[-1][:46]}»")
    print("PASS: 判据符合预期\n" if not bad else "FAIL\n")
    return 1 if bad else 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    """CLI 入口。"""
    ap = argparse.ArgumentParser(
        description="q2 批量分阶段编排（默认 dry-run，加 --execute 才真调 API）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("-i", "--instances", required=True, help="实例清单 JSON")
    ap.add_argument("--stages", default="bind,flow,deploy",
                    help="要跑的阶段，逗号分隔（默认 bind,flow,deploy）")
    ap.add_argument("--concurrency", type=int, default=int(os.environ.get("Q2_CONCURRENCY", "2")),
                    help="单阶段内并发提交数（默认 2；SWAS 账号级频控：5-8 次调用即触发 "
                         "~17 分钟封锁，不建议调高）")
    ap.add_argument("--submit-gap", type=float, default=float(os.environ.get("Q2_SUBMIT_GAP", "5")),
                    help="两次提交之间最小秒数（默认 5）")
    ap.add_argument("--poll", type=float, default=5.0, help="轮询间隔秒（默认 5）")
    ap.add_argument("--timeout", type=int, default=0,
                    help="单阶段每台超时秒；0=按阶段自动（bind 1200 / flow 180 / deploy 180）")
    ap.add_argument("--remote", default=REMOTE_SCRIPT, help=f"远端脚本路径（默认 {REMOTE_SCRIPT}）")
    ap.add_argument("--script-url", default=SCRIPT_SOURCE, help="脚本下载源（第一个尝试）")
    ap.add_argument("--execute", action="store_true", help="真正调用阿里云 API（默认只 dry-run）")
    ap.add_argument("--skip-url-check", action="store_true",
                    help="跳过下发前的 q2_stage.sh URL 可用性自检（仅离线演练用）")
    ap.add_argument("--selftest", action="store_true", help="只跑本地自检（节流 + 判据），不联网")
    ap.add_argument("--interval", type=float, default=float(os.environ.get("Q2_INTERVAL", "60")),
                    help="同阶段每台之间的错峰间隔秒（默认 60；200 台一次性打过去必触发账号级频控）")
    ap.add_argument("--check-only", action="store_true",
                    help="只读模式：只做平台侧核对，不下发任何命令"
                         "（账号没有 RunCommand 权限时也能用；平台 API + JWT 无频控）")
    ap.add_argument("--skip-perm-probe", action="store_true", help="跳过 RunCommand 权限探针")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest_throttle() or selftest_output_judge()

    ak = os.environ.get("SWAS_AK", "")
    sk = os.environ.get("SWAS_SK", "")
    if args.execute and not (ak and sk):
        print("缺凭据：请 export SWAS_AK=... SWAS_SK=...（或写 ~/.ali_creds 后 source）", file=sys.stderr)
        return 2

    # 下发前先确认脚本真的能取到 —— 不要把下载失败的命令推给 200 台
    if args.execute and not args.skip_url_check:
        print("\n===== 下发前自检：q2_stage.sh 源可用性 =====")
        urls = list(dict.fromkeys((args.script_url, *SCRIPT_FALLBACKS)))
        ok, detail = verify_script_url(urls)
        if not ok:
            print(f"\n[FATAL] 所有源都无法取到合格的 q2_stage.sh：{detail}", file=sys.stderr)
            print("       已尝试：", file=sys.stderr)
            for u in urls:
                print(f"         - {u}", file=sys.stderr)
            print("       请先 push 脚本到仓库，或用 --script-url 指定可用源。", file=sys.stderr)
            print("       （确实只想离线演练请加 --skip-url-check）", file=sys.stderr)
            return 3

    # 权限探针：必须在扇出前做。实测无权限账号返回 403 空 body，
    # 若不探针就扇出，会得到 200 条难以归因的失败。
    if args.execute and not args.check_only and not args.skip_perm_probe:
        first = load_instances(args.instances)[0]
        print(f"\n===== RunCommand 权限探针（{first.label()}）=====")
        try:
            cli = SwasClient(ak, sk, first.region)
            ok, detail = cli.permission_probe(first.iid)
        except Exception as e:  # noqa: BLE001
            ok, detail = False, f"[unknown] {str(e)[:200]}"
        print(f"  {detail}")
        if not ok:
            print("\n[FATAL] 该账号无法下发 RunCommand，已中止（未扇出到任何实例）。", file=sys.stderr)
            print(f"       {detail}", file=sys.stderr)
            print("       解决：给该 RAM 身份加 RunCommand 权限 / 换账号 / 用 --check-only 只读核对。",
                  file=sys.stderr)
            return 4

    if args.check_only:
        # 只读模式：不碰 RunCommand，只做平台侧核对（平台 API + JWT，无频控）
        return run_check_only(load_instances(args.instances))

    insts = load_instances(args.instances)
    stages = [s.strip() for s in args.stages.split(",") if s.strip()]
    bad_stage = [s for s in stages if s not in ("bind", "flow", "deploy")]
    if bad_stage:
        print(f"非法阶段: {bad_stage}（可选 bind/flow/deploy）", file=sys.stderr)
        return 2

    print(f"实例 {len(insts)} 台 | 阶段 {stages} | "
          f"{'EXECUTE（会真调 API）' if args.execute else 'DRY-RUN'}")
    print(f"节流：并发={args.concurrency} 提交间隔={args.submit_gap}s")

    throttle = Throttle(gap=args.submit_gap, concurrency=args.concurrency)
    all_res: Dict[str, List[StageResult]] = {}
    for stage in stages:
        tmo = args.timeout or {"bind": 1200, "flow": 180, "deploy": 180}.get(stage, 300)
        all_res[stage] = run_stage(
            stage, insts, throttle, args.poll, tmo, SwasClient, ak, sk,
            args.execute, args.script_url, args.remote, args.interval,
        )
        # 阶段之间额外冷却，给账号级频控留恢复时间
        if args.execute and stage != stages[-1]:
            print(f"阶段间冷却 {args.submit_gap * 2:.0f}s …")
            time.sleep(args.submit_gap * 2)

    bad = summarize(all_res)
    print(f"\n累计提交次数（受节流控制）: {throttle.calls}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())