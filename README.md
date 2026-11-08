# AutoHosts

给固定几个网站挑一条**当前最快的直连路径**，写进 Windows 的 hosts，然后定时自愈。
不挂代理、不装 VPN、不改系统 DNS，也不碰别的网站。

适用场景：某个站的域名能解析，但解析出来的 IP 恰好绕远路或被掐，导致**卡加载、中途断线**。

## 它解决什么

同一个站点在不同地区、不同时段会被分到不同的边缘节点。运营商 DNS 给出的那个 IP，
未必是此刻对你这台机器最快的；有时干脆是个半死节点——握手能成功，正文拉不下来。

AutoHosts 做三件事：

1. **量**：对候选 IP 逐个做真实的 TLS 握手 + HTTP 请求，记录耗时和状态码
2. **筛**：只认「返回本域名内容」的 IP，排除能握手但服务别的站点的机器
3. **钉**：把最优的几个 IP 写进 hosts，域名不变，只改它指向谁

浏览器访问时仍然按域名校验证书，所以换 IP 不会有任何安全告警。

## 快速开始

需要 Windows 10/11 + PowerShell 5.1（系统自带），**不需要管理员权限**。

```powershell
# 1. 先看一眼会挑出哪些 IP，不写任何东西
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\AutoHosts.ps1 -DryRun

# 2. 满意了就正式写入
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\AutoHosts.ps1

# 3. 注册两个计划任务，让它自己保持最新（30 分钟全量重选，5 分钟巡检）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Tasks.ps1
```

跑完就可以关掉终端，之后不用管了。

## 目录

```
host/
├─ profiles.json          # 想加速哪些站点、候选 IP 池、各项阈值
└─ scripts/
   ├─ common.ps1          # 探测、评分、hosts 读写（被下面两个 dot-source）
   ├─ AutoHosts.ps1       # 全量优选：扫描 -> 复测 -> 排名 -> 写入
   ├─ HostsGuard.ps1      # 轻量巡检：只测已写入的 IP，坏的剔除
   ├─ Install-Tasks.ps1   # 注册计划任务
   └─ Uninstall-Tasks.ps1 # 注销计划任务 / 清空 hosts 区块
```

运行时产生的日志、hosts 备份、时间戳都写在 `%LOCALAPPDATA%\AutoHosts\`，不会落进仓库。

## 配置

`profiles.json` 里 `groups` 每一项是一个加速组：

| 字段 | 说明 |
| --- | --- |
| `name` | 组名，只用于日志 |
| `probe` | 用它来测速的域名（也一定会被写入 hosts） |
| `pool` | 候选 IP。组内所有域名共用这一池 |
| `hosts` | 额外要一起钉的域名。每个候选 IP 会再单独验证一次是否服务该域名 |

`settings` 是各项阈值，一般不用动：

| 字段 | 默认 | 含义 |
| --- | --- | --- |
| `rounds` | 5 | 每个候选复测轮数 |
| `probeTimeoutMs` | 4000 | 单次探测超时 |
| `screenTimeoutMs` | 2500 | 初筛单次超时（要扫几十个 IP，不宜太长） |
| `maxIpPerHost` | 3 | 每个域名最多写几个 IP，第一个连不上时浏览器会试下一个 |
| `finalists` | 6 | 初筛后进入复测的候选数 |
| `minOkPercent` | 80 | 复测成功率低于这个值直接淘汰 |
| `guardBudgetMs` | 2500 | 巡检单次超时 |
| `guardRetryMs` | 300 | 巡检失败后隔多久重试一次 |
| `reselectCooldownMin` | 15 | 两次全量重选的最小间隔 |
| `backupKeep` | 20 | 保留多少份 hosts 备份 |
| `allowedStatus` | 见文件 | 哪些 HTTP 状态码算「这个 IP 确实在服务该域名」 |

### 加自己的站点

在 `groups` 里加一项，把你知道的候选 IP 填进 `pool` 即可。比如某 CDN 的 anycast 网段：

```json
{
  "name": "my-site",
  "probe": "example.com",
  "pool": ["203.0.113.10", "203.0.113.11"],
  "hosts": []
}
```

如果不知道池里放什么，先 `nslookup` 几家公共 DNS 看该域名返回哪些 IP，或者直接放该域名当前解析出的地址。

## 怎么排名

单次握手耗时受拥塞影响极大——同一个 IP 会在 0.1s 和 2.5s 之间来回跳，按单次排名等于抽签。
所以每个候选测 `rounds` 轮，取两个统计量：

```
score = best * 0.5 + median * 0.5
```

- **best** 反映这条路径最好能有多快（拥塞是公用的，好路径的谷值最稳）
- **median** 反映它通常的表现，防止一次侥幸的低值把烂 IP 顶上来

复测成功率低于 `minOkPercent` 的候选直接淘汰：能偶发连上但经常超时的 IP，
钉上去只会把「卡加载」变成「彻底打不开」。

还有一个容易踩的坑：**能握手不等于服务这个域名**。GitHub 的一些 IP 对
`Host: github.com` 会返回 `HTTP 400`（那是 API 的机器），如果按「握手成功就算通」排名，
会把 github.com 钉到它上面，结果反而打不开。所以状态码要过 `allowedStatus` 白名单。

## 验证效果

```powershell
# 看日志
Get-Content "$env:LOCALAPPDATA\AutoHosts\optimize.log" -Tail 30

# 看当前钉了什么
Select-String -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Pattern "AUTOHOSTS" -Context 0,20
```

一次真实对照（同一台机器、同一时段、改造前后各测 3 轮）：

| 站点 | 改造前 | 改造后 |
| --- | --- | --- |
| poedb.tw/tw/Items | 首字节 1.42–1.91s | 0.32–0.69s |
| poe2db.tw/tw/Items | 首字节 0.68–1.71s | 0.35–1.48s |
| github.com | 部分时段 0 字节 / 20s 超时 | 可用时段 3/3 完整加载 |

## 回滚

三种方式，任选其一：

1. 删掉 hosts 中 `# >>> AUTOHOSTS BEGIN` 到 `# <<< AUTOHOSTS END <<<` 之间的内容
2. `powershell -File .\scripts\Uninstall-Tasks.ps1 -RemovePins`（同时注销计划任务）
3. 从 `%LOCALAPPDATA%\AutoHosts\backups\` 取最近的 `hosts-*.bak` 覆盖 hosts

## 已知限制

- **它治不了流量层的阻断。** 如果某个站点是在传输过程中被掐断（握手成功、正文 0 字节），
  换 IP 无效，换 SNI 也无效，只能等窗口过去或走代理。hosts 能做的是保证你每次连的是
  *此刻*最健康的入口。
- **换网络后建议手动跑一次。** hosts 记的是 IP，不是路由；换 Wi-Fi、换热点、换城市之后，
  之前的排名大概率已经不准，重跑一次 `AutoHosts.ps1` 即可。
- **只影响本机。** 不改 DNS、不改路由器，同一局域网的其它设备不生效。
- **IP 池会过时。** 池里是公开的边缘节点地址，服务方调整后会失效；脚本会自动跳过失效项，
  但长期使用建议偶尔复查 `profiles.json`。
- **对 403 的容忍是故意的。** Cloudflare 防护页、GitHub 的部分路径都会返回 403/404，
  这些说明「IP 确实在服务这个域名」，所以计入白名单；真正的错配（400）才排除。

## 常见问题

**会不会被判定为作弊或违反站点条款？**
不改请求内容、不伪造来源、不绕付费墙，只是选择连接哪个边缘节点，等同于换一条网络路径。

**为什么不用 hosts 直接写死一个测好的 IP？**
链路质量随时段变化，昨天最快的 IP 今天可能最慢。定时重选就是为了跟住这个变化。

**安全吗？**
探测时跳过了证书校验（只测连通性和耗时，不传输任何数据）；真正的浏览器访问仍然走完整的
TLS 校验。脚本只读写 hosts 的受管区块，其它行原样保留。
