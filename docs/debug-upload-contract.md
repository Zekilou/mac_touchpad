# Debug 上传通道契约

> 这份文档只约定「客户端发什么、发到哪」以及「服务端至少怎么接住」。
> 存储、索引、通知、面板怎么做，全部由后端自行决定，本文不约束。

- 通道用途：Touchpad Gestures（macOS 菜单栏 App）的错误/崩溃/用户主动反馈
- 通道域名：`debug.zeki.casa`（同一域名后续还会接其它项目，靠 scope 区分）
- 本文版本：契约 v1（客户端字段只增不改，见文末兼容规则）

---

## 1. 端点

```
POST https://debug.zeki.casa/touchpad-gestures/v1/report
Content-Type: application/json; charset=utf-8
```

**项目名在路径里**，因为同一个 `debug.zeki.casa` 还会接其它软件的上报。
路径第一段就是 scope，后端按第一段直接路由/分目录，不用解析 body。

其它项目各自占一个前缀，互不影响：

```
https://debug.zeki.casa/touchpad-gestures/v1/report
https://debug.zeki.casa/<其它项目>/v1/report
```

一次上报 = 一个请求 = 一个自包含的 JSON 文档。**没有 multipart，没有附件流**——
日志、崩溃堆栈、配置快照都以字符串形式放在这个 JSON 里（见第 4 节）。

为什么这么设计：这份数据的最终读者是人（你自己翻报告），不是需要强类型解析的系统。
单文件 JSON 可以直接 `jq` 看、直接扔给对象存储、直接丢进任何面板，成本最低。

---

## 2. 请求头

| 头 | 必需 | 值 |
|---|---|---|
| `Content-Type` | 是 | `application/json; charset=utf-8` |
| `X-Debug-Scope` | 是 | `touchpad-gestures`（与路径第一段相同，冗余但便于日志/网关过滤） |
| `X-Debug-Schema` | 是 | `1` |
| `Idempotency-Key` | 是 | 等于 body 里的 `report.id`，重试时保持不变 |
| `X-Client-Token` | 是 | 内置 token，当前值见 `Sources/TouchpadGestures/Diagnostics/ReportScope.swift`（服务端自行登记/轮换） |
| `User-Agent` | 否 | `TouchpadGestures/2.1.2 (release)` |

---

## 3. 作用域（多项目共用域名）

scope 有三份副本，内容都是 `touchpad-gestures`，彼此必须一致：

1. 路径第一段 —— `POST /touchpad-gestures/v1/report`（**主路由依据**）
2. 请求头 `X-Debug-Scope`
3. body 内 `scope.project`

后端只要做到两件事：

1. **路径第一段不认识就直接 404/403**，不要落到任何默认桶里。
2. 存储按 scope 分目录（见第 6 节），这样清理、导出、授权都可以按项目做。

scope 字符串目前只有 `touchpad-gestures`，后续新项目各自追加一个新前缀，互不影响。

---

## 4. 请求体（一个 JSON 文档）

字段说明见下。**所有时间都是 ISO 8601 带时区**；可选字段缺失即视为没有，
后端不要因为缺字段而拒绝（除了第 5 节标记为必需的那些）。

```jsonc
{
  "schema_version": 1,
  "report": {
    "id": "8f14e45fceea167a5a36dedd4bea2543",   // 必填，32 位小写 hex，幂等键同值
    "created_at": "2026-10-19T20:23:03+08:00",
    "trigger": "crash",                          // crash | error | manual
    "severity": "error",                         // fatal | error | warning | info
    "fingerprint": "sha256:9c1f…",               // 同一问题稳定不变，用于聚合
    "occurred_at": "2026-10-19T20:21:55+08:00",
    "app_uptime_seconds": 812.4,
    "previous_session_crashed": true
  },

  "scope": {
    "project": "touchpad-gestures",
    "channel": "release",                        // release | dev
    "bundle_id": "com.zekiwithcat.TouchpadGestures",
    "app_version": "2.1.2",
    "app_build": "1",
    "schema_version": 1
  },

  "errors": [
    {
      "fingerprint": "sha256:9c1f…",
      "domain": "com.touchpad.graph",            // 稳定命名空间，见 4.1
      "code": "invalid_graph",
      "message": "手势「左侧Force」的图非法，已回退空执行器",
      "count": 3,
      "first_seen": "2026-10-19T12:03:11+08:00",
      "last_seen": "2026-10-19T12:07:42+08:00",
      "stack": ["GraphEvaluator.init(timeline:)", "GestureEngine.runtime(for:)"],
      "context": { "gesture": "左侧Force", "nodes": 17, "edges": 19 }
    }
  ],

  "environment": {
    "os_version": "macOS 15.1 (24B83)",
    "arch": "arm64",
    "model": "Mac14,2",
    "locale": "zh-Hans-CN",
    "language": "zh",
    "permissions": { "accessibility": "granted", "input_monitoring": "unknown" },
    "trackpad": { "device_id": 1234567890, "device_count": 1, "ready": true },
    "engine": { "running": true, "holding": false, "idle_slowed": true },
    "config": { "gestures": 6, "events": 5, "regions": 6, "version": 3 }
  },

  "user": {
    "description": "左侧 Force 按压后音量不变化",   // 用户填写，可空
    "steps": "重按左边缘保持 1 秒后上下滑动",        // 用户填写，可空
    "contact": "zeki@example.com"                   // 用户填写，可空
  },

  "consent": {
    "granted": true,
    "collected": ["environment", "errors", "logs", "crash"],
    "excluded": ["config"]
  },

  "logs": "…整段文本，客户端已脱敏…",              // 可选，最多 256 KB
  "crash": "…整段崩溃日志文本…",                   // 可选，最多 128 KB
  "config_snapshot": { }                            // 可选，用户勾选才带
}
```

### 4.1 `domain` 取值

客户端只用这几个，后端按需自行归类即可：

| domain | 含义 |
|---|---|
| `com.touchpad.crash` | 崩溃（signal / NSException） |
| `com.touchpad.config` | 配置加载/保存/迁移失败 |
| `com.touchpad.graph` | 手势图非法、执行器构建失败 |
| `com.touchpad.trackpad` | 触控板初始化、设备枚举、触觉失败 |
| `com.touchpad.permission` | 权限不一致 |
| `com.touchpad.system` | 音量/亮度/进度读写失败 |
| `com.touchpad.upload` | 上传自身失败（**客户端不会上报这类**，仅本地记录） |
| `com.touchpad.user` | 用户主动反馈（无具体错误时） |

### 4.2 内容大小与脱敏

- 整个请求体上限 **5 MB**；`logs` ≤ 256 KB、`crash` ≤ 128 KB、`errors` 最多 50 条。
- 客户端已做脱敏：`/Users/<用户名>/` → `~/`；不含主机名、序列号、IP、截图。
- `config_snapshot` 默认不带（里面有用户自定义手势名），用户勾选才带。

---

## 5. 服务端最小行为

只需要做到这些，其余自由发挥：

| 情况 | 响应 |
|---|---|
| 接收成功 | `201`，body `{"ok": true, "id": "<report.id>", "url": "<可选，面板链接>"}` |
| 同一个 `Idempotency-Key` 重复提交 | `200`，返回首次的 `id`（不要新建） |
| scope 未知或不匹配 | `403` |
| `X-Client-Token` 不对 | `401` |
| JSON 解析失败 / 缺必需字段 | `400` |
| 超过 5 MB | `413` |
| 频率限制 | `429`，可带 `Retry-After` |

客户端对状态码的处理（已实现，供后端参考）：

- `2xx` → 删除本地草稿
- `400/401/403/413/422` → 不重试，保留本地副本并在设置页提示
- `429/5xx` / 网络错误 → 指数退避重试 3 次，再失败就留在 outbox（下次启动/联网重试）

**必需字段**（缺了没法定位问题）：`schema_version`、`report.id`、`report.created_at`、
`report.trigger`、`scope.project`、`scope.app_version`。
其余全部可选，缺了也请正常 201。

---

## 6. 存储建议

没有硬性要求，但按这个布局最省事（路径第一段即项目名，天然分桶）：

```
debug-uploads/
  touchpad-gestures/                 # 与 URL 第一段一致
    2026/10/19/<report.id>.json      # 原样落盘，别再拆字段，人读为主
    index.jsonl                      # 每行一条摘要：id / created_at / trigger / severity /
                                     # title / fingerprint / app_version / 可选 url
  其它项目/
    …
```

- 原文件**原样保留**（以后加字段不用改存储 schema）。
- `index.jsonl` 只是为了列表页/搜索，丢了能重建。
- 保留期建议 90 天，到期删原文件；崩溃类可以留久一点。
- 用户要求删除时，按 `report.id` 删原文件并从 index 移除即可。

---

## 7. 客户端上报时机

给后端一个「大概会收到什么」的预期：

- **crash**：进程崩溃后，下次启动自动生成报告并弹窗询问；
- **error**：运行中出现可恢复错误（配置损坏、图非法、触控板初始化失败等），
  同一指纹每会话最多弹一次窗；
- **manual**：用户在「设置 → 反馈与诊断」或菜单栏「报告问题…」里主动提交。

**任何情况下都不会静默上传**——每条报告都要用户在弹窗里点「发送」。

---

## 8. 兼容规则

- `schema_version` 只做加法：新字段随时加，删字段/改语义才升大版本。
- 服务端**忽略未知字段**，不要因此拒绝请求。
- 客户端不依赖响应体内容，只看状态码 + 可选 `id`。
- 若将来数据涨到需要 multipart，会新开 `…/v2/report`，`/v1` 保持可用一段时间。

---

## 9. 验收用 curl

```bash
curl -X POST https://debug.zeki.casa/touchpad-gestures/v1/report \
  -H 'Content-Type: application/json' \
  -H 'X-Debug-Scope: touchpad-gestures' \
  -H 'X-Debug-Schema: 1' \
  -H 'X-Client-Token: 8bd77558e9348eb9b45b9b41312fd71a' \
  -H 'Idempotency-Key: 8f14e45fceea167a5a36dedd4bea2543' \
  --data-binary @sample-report.json
```

期望：`201`，且磁盘上出现
`touchpad-gestures/2026/10/19/8f14e45fceea167a5a36dedd4bea2543.json`。
同一个 curl 再跑一次应返回 `200` 且不产生第二个文件。
