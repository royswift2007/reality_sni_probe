# REALITY SNI Probe v2.2

用于**批量评估域名是否适合作为 REALITY SNI 候选站点**的 Bash 检测脚本。

- 当前维护脚本：[`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh)

v2.2 是当前统一维护版本，集中包含 ASN 查询与分类、随机抖动、HTTP/2 探测退化修复、macOS/BSD 证书日期解析、多行 SAN 解析、导出哨兵值友好显示、OCSP 降权、证书剩余天数去评分化、数值项软 / 硬阈值、默认低并发和终端列按权重排序等能力。

---

## ⚠️ 使用前必读：必须在 REALITY 服务器上运行

**这是本脚本最容易被忽略、但最关键的一条使用前提。**

脚本测出来的 **TCP 建连、TLS 握手、TTFB、抖动、稳定性** 全部是 **“从当前这台服务器出口到目标 SNI 的真实链路质量”**。这些数值和你的工位、手机、其他服务器上看到的**完全不一样**。

### 为什么必须在 REALITY 服务器上跑

REALITY 的伪装前提是：**当 GFW 主动探测你的节点时，服务端会向真实 SNI 目标转发握手**。GFW 观察到的握手特征（延迟、证书、ALPN 等）来自 **“REALITY 服务器到真实目标”** 这条路径，而不是你本地的路径。

所以：

- **同一个域名在不同服务器上分数可能差 10 倍**：这是正常的，反映的是“对这台服务器而言合不合适”。
- **在 A 服务器测出的“推荐”候选，在 B 服务器上可能只是“勉强”或直接“不建议”**。
- **从你笔记本 / 开发机上跑出来的结果，绝对不能搬到生产 REALITY 服务器上用**。

### 正确用法

```bash
# 1. SSH 登录到你实际部署 REALITY 的那台服务器
ssh your-reality-server

# 2. 在服务器上直接运行脚本
./reality_sni_probe_v2.2.sh -f domains.txt -o result.csv

# 3. 按照脚本给出的分数和结论选 SNI
```

### 实测案例

作者实测中遇到过：同样两台日本 VPS，访问同一批 `.ac.jp` 域名：

| 服务器 | TTFB 典型值 | 最优站点分数 |
| --- | --- | --- |
| 服务器 B（日本 IP） | 700–1100ms | 98 分（“可用”） |
| 服务器 C（日本 IP） | 50–100ms | 192 分（“推荐”） |

**两台都是日本 IP，但上游 transit 路径不同，脚本评分正确反映了这个差异**。如果在服务器 B 上跑完结果拿去服务器 C 用，会选错 SNI；反过来也一样。

> **记住：脚本给出的分数只对“这台服务器当下的出口”负责。换服务器要重新跑。**

---

## 目录

- [⚠️ 使用前必读](#️-使用前必读必须在-reality-服务器上运行)
- [项目简介](#项目简介)
- [v2.2 更新说明](#v22-更新说明)
- [核心能力概览](#核心能力概览)
- [依赖环境与前置要求](#依赖环境与前置要求)
- [安装与获取方式](#安装与获取方式)
- [如何使用脚本](#如何使用脚本)
- [命令行参数说明](#命令行参数说明)
- [UTF-8 / locale 兼容处理](#utf-8--locale-兼容处理)
- [检测流程总览](#检测流程总览)
- [脚本实际执行的检测项](#脚本实际执行的检测项)
- [默认终端显示项与导出字段的区别](#默认终端显示项与导出字段的区别)
- [输出结果中每一项参数的详细解释](#输出结果中每一项参数的详细解释)
- [每项参数的重要性](#每项参数的重要性)
- [结论判定逻辑](#结论判定逻辑)
- [评分机制与权重细节](#评分机制与权重细节)
- [ASN 类型与“大树底下好乘凉”伪装原则](#asn-类型与大树底下好乘凉伪装原则)
- [排序与筛选说明](#排序与筛选说明)
- [示例输出与阅读方式](#示例输出与阅读方式)
- [CSV / JSONL 导出字段说明](#csv--jsonl-导出字段说明)
- [局限性](#局限性)
- [FAQ](#faq)

---

## 项目简介

[`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh) 的目标，是把“一个域名能不能拿来当 REALITY 的 SNI 候选”拆成多个可量化维度，再统一汇总成结论与分数。

脚本关注的不是“能否打开网页”这么简单，而是更偏向以下问题：

1. 该域名是否具备正常、可解析的 HTTPS/TLS 行为；
2. 证书是否存在，是否能正常抓到，SAN 是否覆盖目标域名；
3. 是否体现 TLS 1.3、是否出现 X25519；
4. 是否支持 HTTP/2，实际 ALPN 是否自然；
5. 页面形态是否更像正常站点，还是明显错误页 / 挑战页 / 可疑拦截；
6. 跳转是否自然，是否出现跨站跳转；
7. 多次采样下的 TCP / TLS / TTFB 是否稳定；
8. ASN 背景是否像“大树”，多 IP 是否一致；
9. 最终是否达到“推荐”、至少“可用”，还是仅“勉强 / 不建议”。

脚本内部几个关键函数为：

- [`probe_one()`](reality_sni_probe_v2.2.sh:1248)：单域名完整检测主流程；
- [`judge_sni()`](reality_sni_probe_v2.2.sh:922)：根据硬门槛和分支规则给出结论；
- [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010)：按当前三层权重累计分数；
- [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881)：统一处理数值项软 / 硬阈值；
- [`check_h2()`](reality_sni_probe_v2.2.sh:494)：独立检测 HTTP/2；
- [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384)：抓取 `openssl s_client` 输出与证书 PEM；
- [`check_san_level()`](reality_sni_probe_v2.2.sh:716)：判断证书 SAN 是否精确匹配、通配匹配或不匹配；
- [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.2.sh:418)：提取实际 ALPN 协商结果；
- [`check_cert_chain_status()`](reality_sni_probe_v2.2.sh:443)：判断证书链完整性；
- [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.2.sh:468)：判断 OCSP Stapling 状态；
- [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632)：抽样检查多 IP 一致性；
- [`check_header_naturalness()`](reality_sni_probe_v2.2.sh:587)：评估 HTTP 响应头自然度。

---

## v2.2 更新说明

v2.2 是当前统一维护版本，核心脚本位于 [`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh)。本文不再区分未发布的中间版本，所有能力和修复都统一归入 v2.2。

### 当前 v2.2 包含的主要变化

1. **版本标识一致性**：终端标题与脚本注释统一显示 v2.2。
2. **HTTP/2 探测退化更保守**：当系统 `curl` 未编译 HTTP/2 支持时，脚本不再静默把 H2 判成“不支持”，而是返回“未知”，并优先使用 `openssl s_client` 的 ALPN=`h2` 结果兜底。
3. **macOS / BSD 日期兼容**：证书剩余天数解析不再只依赖 GNU `date -d`，会依次尝试 GNU `date -d`、BSD `date -j -f`，以及可选的 `python3` 解析。
4. **SAN 多行解析修复**：`check_san_level()` 不再只读取 `X509v3 Subject Alternative Name` 后一行，避免证书 SAN 换行时误判为“不匹配”或“无SAN”。
5. **导出哨兵值更友好**：CSV / JSONL 中的 `tcp_jitter`、`tls_jitter`、`ttfb_jitter` 对不可得值输出 `-`，不再暴露内部哨兵 `999999ms`。
6. **依赖退化提示**：启动主流程后会提示缺失 `curl`、`openssl`、`whois`、`timeout/gtimeout`、`getent/dig/nslookup` 对结果的影响。
7. **UTF-8 locale 选择更稳**：候选 locale 改用固定字符串匹配，避免正则替换导致异常匹配。
8. **curl 临时文件读取更安静**：当 `curl` 超时、DNS/TLS 失败或远端提前断开导致响应体 / 响应头临时文件未生成时，脚本不再向终端打印 `No such file or directory`，而是按失败样本继续统计。
9. **OCSP 权重降为轻量信号**：`OCSP=支持` 只小幅加分，`未提供` 不再扣分，避免正常站点因未 Staple 被过度惩罚。
10. **证书剩余天数不再参与评分**：证书剩余天数只保留 `< 14` 天直接“不建议”的临期硬保护，不再用剩余天数长短拉开大站排序。
11. **TTFB 异常区间扣分加重**：`avg_ttfb > 900ms` 已经不只是“慢”，而是当前出口到目标站点的路径 / 站点自然性风险信号；v2.2 加重 `900ms+` 档位扣分，避免数百毫秒级延迟差被 CDN、多 IP 一致性这类背景加分覆盖。
12. **数值项门槛进入结论判定**：`avg_tcp / avg_tls / avg_ttfb / tcp_var / tls_var / ttfb_var` 不再只参与评分；超过软阈值直接降为“勉强”，超过硬阈值直接判为“不建议”并输出 `-9999`。
13. **默认并发降为 1**：默认优先保证低配 REALITY 服务器上的检测质量，避免 CPU 满载污染 TLS / TTFB / 抖动；需要快速初筛时仍可手动使用 `-j NUM`。
14. **默认终端关键列按权重重排**：`码 / TCP / TLS / TTFB / 抖动 / TLS13 / X25519 / H2 / ALPN` 的顺序保持不变；仅把后半段站点判断列按权重重排为 `SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`，方便小白在分数接近时从左到右筛选。
15. **ASN 查询与分类**：通过 `whois.cymru.com` 查询远端 IP 的 ASN，并按 `CDN / Hosting / ISP / Edu / 未知` 归类，把“大树 / 孤树”背景纳入评分。
16. **批量扫描辅助参数**：支持 `--jitter NUM` 为 worker 启动增加随机延迟，支持 `--no-asn` 跳过 ASN 查询。
17. **CSV / JSONL 导出扩展**：导出字段包含 `asn` 与 `asn_type`，便于后续复核 ASN 背景。
18. **旧版评分 bug 与运行时问题修复**：修复早期 `&& ||` 链式评分误累加、worker 环境变量覆盖、`|` 分隔符冲突等问题。

这些变更不会破坏 CSV / JSONL 已有字段，只改变兼容性、退化语义、评分校准、默认并发、终端展示顺序和文档一致性。

### 为什么 v2.2 要加入 ASN 与安全优先校准

早期评分体系已经覆盖了 REALITY 伪装最核心的几层指标（证书、SAN、TLS1.3/X25519/H2、页面形态、稳定性），但有一个明显缺口：

> **“这个域名背后的 IP 所在那条网络管道，到底是不是一棵大树？”**

这就是 ASN（Autonomous System Number，自治系统编号）要回答的问题。一个小众 ASN 上的孤立域名和一个 Cloudflare 边缘节点上的域名，哪怕 TLS 握手、证书、页面看起来都一样，被 GFW 主动封禁的边际代价完全不同：前者没邻居陪你挡枪，后者背后是半个互联网。

v2.2 把这层“背景噪声”量化后纳入评分，同时修掉旧版实现里的隐性问题，并加入大批量扫描时方便的辅助参数。

### 刻意没做的几件事

评估 PRD 里提到的几个方向后，以下都**确认不做**：

- **ECH（加密 ClientHello）探测**：REALITY 协议本身要求 SNI 明文，和 ECH 功能互斥。探测目标是否支持 ECH 对 REALITY 伪装效果无加成，纯属噪声；
- **HTTP/3 / QUIC 真实握手**：REALITY 跑在 TCP 上，目标域名是否支持 H3 与伪装效果无关。Debian 12 默认 `curl` 也不带 `--http3`；
- **PQC（X25519MLKEM768 等）协商检测**：方向错位，PQC 是客户端 utls 的事，不是 SNI 探测的职责；
- **TFO / MSS 等 L4 指纹**：需要 raw socket 或 root 权限，破坏脚本“普通用户单文件 Bash”的运行姿态，投入产出比差；
- **切换到 BoringSSL / quictls**：上面这些都不做，底层换栈就没有意义。

### 旧版问题修复与权重重新校准

早期第三层性能 / 抖动分档曾使用类似下面的链式结构：

```bash
[ "$tls_num" -le 20 ] && score=$((score + 8)) || \
[ "$tls_num" -le 30 ] && score=$((score + 7)) || ...
```

表面上像 `if/elif`，但 Bash 里 `&&` 和 `||` 是等优先级、左结合。当某个桶命中并执行赋值后，后续所有 `|| [ ... ] && ...` 的测试条件仍会继续求值，只要条件为真就继续累加。

例如 `tls_num = 30` 时，文档规定加 `+7`，早期实际可能累加出远高于预期的分数。v2.2 已把 `avg_tcp / avg_tls / avg_ttfb / tcp_var / tls_var / ttfb_var` 这 6 个分档块全部改写为标准 `if/elif/else` 结构。

在修复基础上，v2.2 进一步重新校准了第二层和第三层分值。核心原则：

> **SNI 选择的最高目标是安全性。任何偏离“正常大厂健康站点”典型值的指标本身就是风险信号，因此偏离越大，扣分越陡，不能线性降低。**

具体改动：

1. **第三层性能档位**：正常范围内加分保留，但异常范围扣分从线性改为陡降。例如 `avg_ttfb > 1600ms` 进入 `-50` 档。
2. **第三层抖动项**：加分大幅压缩，因为抖动“很小”不一定代表站点稳定；减分则明显加重。
3. **第二层异常扣分加重**：`waf=疑似挑战`、`redirect=跨站跳转`、`page=错误页`、`asn_type=Edu` 等异常项会明显拉低分数。
4. **数值项先走门槛**：超过软阈值直接“勉强”，超过硬阈值直接“不建议 / -9999”。

---

## 核心能力概览

本脚本当前真实具备以下能力：

- 支持直接传入多个域名；
- 支持通过文件批量读入域名；
- 自动清洗输入域名，去掉协议头、路径、端口，并转为小写，见 [`normalize_domain()`](reality_sni_probe_v2.2.sh:147)；
- 启动时会尝试选择 UTF-8 locale，并在需要时重新 `exec` 自己，减少中文表头 / 内容在不同 shell 中的乱码问题，见 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.2.sh:28)；
- 每个域名默认进行 3 次 `curl` 采样，计算平均值与抖动；
- 检测 TCP 建连时间、TLS 握手时间、TTFB；
- 提取 HTTP 版本、状态码、内容类型、响应大小、最终 URL、HTML 标题、响应头摘要、远端 IP；
- 对 `curl` 响应体与响应头、以及 `openssl s_client` 输出都做 NUL 过滤，避免 `ignored null byte in input` 干扰；
- 通过 `openssl` 解析证书、到期时间、颁发者、SAN、证书链状态、OCSP Stapling、证书指纹；
- 判断 TLS 1.3、X25519、HTTP/2 与实际 ALPN 协商结果；
- 区分 SAN `精确匹配` 与 `通配匹配`，并把前者视为更优；
- 抽样检测同域名多个 IP 的一致性；
- 评估 HTTP 响应头自然度；
- 判断页面是否更像“正常网页 / 弱网页 / 非 HTML 响应 / 错误页”；
- 判断是否疑似 WAF 挑战或拦截；
- 判断跳转是否自然；
- 查询 ASN 并归类为 `CDN / Hosting / ISP / Edu / 未知`；
- 综合形成稳定性、结论和评分；
- 支持结果表格输出，并针对中英文混排做列宽对齐修复，见 [`table_display_width()`](reality_sni_probe_v2.2.sh:1447) 与 [`table_fit_text()`](reality_sni_probe_v2.2.sh:1466)；
- 支持 CSV / JSONL 导出；
- 支持仅保留“推荐 / 可用”，以及按最小分数过滤；
- 会对输入域名去重，避免重复检测，见 [`dedup_domains()`](reality_sni_probe_v2.2.sh:1629)。

本脚本没有实现的能力包括但不限于：

- 不主动探测完整 ALPN 候选列表，只记录本次 `openssl s_client` 实际协商结果；
- 不检测 QUIC / HTTP/3；
- 已新增 ASN 查询与分类，但不做地理位置 / 运营商层面的深度分析；
- 不直接验证“真实 REALITY 握手是否可用”；
- 不做深度页面渲染，只做启发式文本级判断；
- 不提供交互式 UI。

---

## 依赖环境与前置要求

### 1. 运行环境

脚本头部使用 `#!/usr/bin/env bash`，因此需要 Bash 环境。

适合环境示例：

- Linux
- macOS
- WSL
- Git Bash / MSYS2 / Cygwin（需自行确认 `locale`、`mktemp`、`jobs`、`mapfile` 等兼容性）

### 2. 必需依赖

#### `curl`

用于 HTTP/HTTPS 采样，见 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319) 与 [`check_h2()`](reality_sni_probe_v2.2.sh:494)。

缺失时：

- HTTP 采样、页面判断、WAF 判断、跳转判断都会明显退化；
- TCP / TLS / TTFB 均值和抖动不可用；
- 结论会更保守。

#### `openssl`

用于 TLS 握手信息与证书解析，见 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384)、[`cert_text_from_pem()`](reality_sni_probe_v2.2.sh:408)、[`days_to_expiry_from_pem()`](reality_sni_probe_v2.2.sh:696)。

缺失时：

- 证书状态、SAN、到期时间、Issuer、TLS1.3、X25519、ALPN、证书链、OCSP 都会退化；
- [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 会把 `cert_ok != 正常` 直接降为“不建议”。

### 3. 可选依赖

#### `timeout` / `gtimeout`

脚本通过 [`safe_timeout()`](reality_sni_probe_v2.2.sh:107) 包装 `openssl s_client` 和 whois 调用。若系统存在 `timeout` 或 `gtimeout`，相关阶段会被超时保护；若不存在，就直接执行命令。

#### `date -d` / `date -j` / `python3`

到期剩余天数计算由 [`days_to_expiry_from_pem()`](reality_sni_probe_v2.2.sh:696) 完成。v2.2 会优先尝试 GNU `date -d`，再尝试 BSD/macOS `date -j -f`，最后在存在 `python3` 时用 Python 兜底解析。

#### `whois`

用于 ASN 查询。缺失时：

- `asn` 导出为 `-`；
- `ASN类型` 显示为“未知”；
- ASN 相关评分为 0；
- 主流程不会中断。

#### `getent` / `dig` / `nslookup`

用于解析 A 记录并做多 IP 一致性抽样。缺失时 `多IP` 会退化为“单IP/未知”。

### 4. 网络前提

脚本需要从当前服务器直接访问目标域名的 443 端口。若当前服务器有透明代理、企业 MITM、防火墙干预、DNS 污染或线路绕路，结果会反映这些真实路径问题。

---

## 安装与获取方式

### 方式一：直接下载单文件

将 [`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh) 放到服务器上，然后：

```bash
chmod +x reality_sni_probe_v2.2.sh
```

### 方式二：保持为单文件脚本使用

脚本没有项目级安装过程，不需要 `npm install`、`pip install` 或编译步骤。

---

## 如何使用脚本

### 1. 直接检测若干域名

```bash
./reality_sni_probe_v2.2.sh www.microsoft.com www.cloudflare.com www.apple.com
```

### 2. 从文件批量检测

```bash
./reality_sni_probe_v2.2.sh -f domains.txt
```

`domains.txt` 示例：

```txt
www.microsoft.com
https://www.cloudflare.com/
www.apple.com:443
# 注释行会被忽略
```

这些输入会被 [`normalize_domain()`](reality_sni_probe_v2.2.sh:147) 统一规整为纯域名。

### 3. 指定并发、超时、采样次数

默认并发为 `1`，优先保证低配 REALITY 服务器上的 TLS / TTFB / 抖动测量质量，避免 CPU 满载污染结果。只有在确认机器资源充足、且只是做初筛时，才建议手动提高并发。

```bash
./reality_sni_probe_v2.2.sh -f domains.txt -j 2 --timeout 12 --samples 5
```

### 4. 仅保留较好结果

```bash
./reality_sni_probe_v2.2.sh -f domains.txt --only-good
```

`--only-good` 对应 [`filter_results()`](reality_sni_probe_v2.2.sh:1614)，只保留“推荐”和“可用”。

### 5. 按最小分数过滤

```bash
./reality_sni_probe_v2.2.sh -f domains.txt --min-score 90
```

### 6. 导出 CSV / JSONL

```bash
./reality_sni_probe_v2.2.sh -f domains.txt -o result.csv --json result.jsonl
```

### 7. ASN 与随机抖动

```bash
# 资源充足的大批量初筛可以手动提高并发并加随机抖动
./reality_sni_probe_v2.2.sh -f domains.txt -j 2 --jitter 300

# 没装 whois 或不想查 ASN 时跳过
./reality_sni_probe_v2.2.sh -f domains.txt --no-asn
```

---

## 命令行参数说明

脚本参数定义见 [`usage()`](reality_sni_probe_v2.2.sh:124) 与 [`main()`](reality_sni_probe_v2.2.sh:1633)。

| 参数 | 含义 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `-f FILE` | 域名文件 | 无 | 从文件逐行读取域名，忽略空行与 `#` 注释行 |
| `-o FILE` | 导出 CSV | 空 | 调用 [`export_csv()`](reality_sni_probe_v2.2.sh:1578) |
| `--json FILE` | 导出 JSONL | 空 | 调用 [`export_jsonl()`](reality_sni_probe_v2.2.sh:1597) |
| `-j NUM` | 并发数 | `1` | 写入 `JOBS`，通过 [`run_with_limit()`](reality_sni_probe_v2.2.sh:1417) 控制后台任务数；默认低并发优先保证检测质量 |
| `--timeout NUM` | 单次请求超时 | `10` | 影响 `curl` 与 `openssl s_client` 超时 |
| `--samples NUM` | 采样次数 | `3` | 每个域名执行多少次 `curl` 采样 |
| `--only-good` | 仅输出好结果 | `0` | 仅保留“推荐 / 可用” |
| `--min-score N` | 最低分数筛选 | 空 | 只输出评分不低于该值的记录 |
| `--jitter NUM` | worker 启动随机延迟上限毫秒 | `0` | 启用后每个 worker 启动前随机 sleep `0–NUM` 毫秒 |
| `--no-asn` | 禁用 ASN 查询 | 默认启用 ASN | 批量扫描时 whois 可能限流，或系统未装 `whois` 时使用 |
| `-h`, `--help` | 帮助 | 无 | 显示帮助并退出 |

### 参数校验规则

脚本会在 [`main()`](reality_sni_probe_v2.2.sh:1633) 中做基础校验：

- `-j` 必须是正整数；
- `--timeout` 必须是正整数；
- `--samples` 必须是正整数；
- `--min-score` 必须是数值；
- `--jitter` 必须是非负整数（毫秒）；
- 未提供任何有效域名会直接报错退出；
- 读取完成后还会做一次去重与空值过滤。

---

## UTF-8 / locale 兼容处理

脚本在正式执行前，会先调用 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.2.sh:28)：

1. 通过 [`select_utf8_locale()`](reality_sni_probe_v2.2.sh:4) 优先从当前 `LC_CTYPE`、`LANG` 中挑选 UTF-8 locale；
2. 若当前环境不合适，再按 `C.UTF-8`、`en_US.UTF-8`、`UTF-8` 依次尝试；
3. 如果发现 `LC_ALL` 已设置，或 `LANG` / `LC_CTYPE` 不符合目标 locale，并且尚未完成 bootstrap，则重新 `exec` 脚本；
4. 重新启动时会显式 `unset LC_ALL`，并导出新的 `LANG`、`LC_CTYPE`；
5. 并发 worker 进程也会继承同样的 UTF-8 相关环境。

这一处理的目标不是改变检测逻辑，而是尽量让中文表头和中文结果值更稳定地显示，并降低表格列错位概率。

---

## 检测流程总览

单域名主流程由 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 驱动，可概括为：

1. 重复调用 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319) 进行 `SAMPLES` 次 HTTPS 请求；
2. 提取 TCP 建连、TLS 握手、TTFB、HTTP 版本、状态码、内容类型、响应体大小、最终 URL、页面标题、响应头摘要、远端 IP；
3. 计算平均值与三项抖动；
4. 选择首个有效 HTTP 样本作为页面 / WAF / 跳转 / 头部分析基准；
5. 通过 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384) 运行带 `-status` 与 `-alpn 'h2,http/1.1'` 的 `openssl s_client`；
6. 解析证书、TLS1.3、X25519、ALPN、证书链、SAN、OCSP、证书指纹、到期时间、颁发者；
7. 判断 HTTP/2 支持情况；
8. 进行页面自然度、响应头自然度、WAF、跳转自然度判断；
9. 调用 [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632) 对最多 3 个 A 记录做一致性复核；
10. 查询 ASN 并分类；
11. 调用 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 产生“推荐 / 可用 / 勉强 / 不建议”；
12. 调用 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 叠加权重分；
13. 过滤、排序、展示 / 导出。

---

## 脚本实际执行的检测项

### 1. `curl` 常规 HTTPS 采样

见 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319)。脚本读取：

- `time_connect`：TCP 建连耗时；
- `time_appconnect`：TLS 完成时间；
- `time_starttransfer`：首字节时间 TTFB；
- `http_version`：HTTP 版本；
- `response_code`：HTTP 状态码；
- `content_type`、`size_download`、`url_effective`、`remote_ip`；
- 响应体中的 `<title>`；
- 响应头摘要。

TLS 握手耗时按 `time_appconnect - time_connect` 计算。

### 2. `curl --http2` HTTP/2 检测

见 [`check_h2()`](reality_sni_probe_v2.2.sh:494)。如果 `curl` 不支持 HTTP/2，则返回“未知”；主流程里若 OpenSSL ALPN 已确认 `h2`，会用 ALPN 兜底记为“支持”。

### 3. `openssl s_client` TLS 抓取

见 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384)。命令形态为：

```bash
openssl s_client -connect "domain:443" -servername "domain" -showcerts -status -alpn 'h2,http/1.1'
```

主要用于后续解析：

- TLS1.3；
- X25519；
- ALPN；
- 证书 PEM；
- 证书链状态；
- OCSP Stapling；
- 证书指纹。

### 4. 证书解析

- [`cert_text_from_pem()`](reality_sni_probe_v2.2.sh:408)：解析完整证书文本；
- [`check_cert_ok()`](reality_sni_probe_v2.2.sh:413)：判断是否拿到 PEM；
- [`get_expiry_from_pem()`](reality_sni_probe_v2.2.sh:689)：读取到期时间；
- [`days_to_expiry_from_pem()`](reality_sni_probe_v2.2.sh:696)：计算剩余天数；
- [`get_issuer_short_from_pem()`](reality_sni_probe_v2.2.sh:709)：读取颁发者；
- [`check_san_level()`](reality_sni_probe_v2.2.sh:716)：判断 SAN 覆盖级别。

### 5. 页面、WAF、跳转、头部、多 IP

- [`page_naturalness()`](reality_sni_probe_v2.2.sh:817)：页面形态；
- [`detect_waf_challenge()`](reality_sni_probe_v2.2.sh:799)：疑似挑战 / 拦截；
- [`redirect_naturalness()`](reality_sni_probe_v2.2.sh:771)：跳转自然度；
- [`check_header_naturalness()`](reality_sni_probe_v2.2.sh:587)：响应头自然度；
- [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632)：多 IP 一致性。

---

## 默认终端显示项与导出字段的区别

### 1. 默认终端表格显示项

终端表格列定义见 [`TABLE_HEADERS`](reality_sni_probe_v2.2.sh:1438)。当前 v2.2 默认显示 24 列：

1. 域名
2. 码
3. TCP建连
4. TLS握手
5. TTFB
6. 平均延迟
7. 抖动T/TLS/F
8. TLS13
9. X25519
10. H2
11. ALPN
12. SAN
13. 证书
14. 跳转
15. WAF
16. 页面
17. 稳定性
18. ASN类型
19. 多IP
20. 链
21. 头部
22. OCSP
23. 评分
24. 结论

其中 `码 / TCP建连 / TLS握手 / TTFB / 平均延迟 / 抖动T/TLS/F / TLS13 / X25519 / H2 / ALPN` 的顺序保持原样；后面的站点判断列按当前权重与 REALITY 安全优先级从高到低排列。

### 2. 默认终端后半段列权重阅读规则

当两个候选的 `结论` 和 `评分` 接近时，可以从 `SAN` 开始按列从左到右筛选：

`SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`

| 终端列 | 阅读优先级 | 当前规则 / 权重含义 |
| --- | --- | --- |
| `SAN` | 最高 | REALITY 身份匹配主项；`不匹配 / 无SAN / 失败` 直接“不建议”，评分中 `精确匹配 +32`、`通配匹配 +12`、`不匹配 -42`、`无SAN -18`、`失败 -32`。 |
| `证书` | 最高 | 证书获取失败直接“不建议”；评分中 `正常 +20`，其他 `-24`。 |
| `跳转` | 最高 | `跨站跳转` 直接“不建议”；评分中 `无跳转/同域 +7`、`主子域自然跳转 +4`、`跨站跳转 -20`。 |
| `WAF` | 高 | `疑似挑战` 直接降为“勉强”；评分中 `正常 +5`、`疑似拦截 -12`、`疑似挑战 -28`。 |
| `页面` | 高 | 正常网页形态更自然；评分中 `像正常网站 +12`、`HTML但特征弱 +6`、`非HTML响应 -6`、`错误页 -18`。 |
| `稳定性` | 高 | 影响“推荐”门槛和评分；评分中 `稳定 +7`、`一般 +1`、`波动大 -10`。 |
| `ASN类型` | 中高 | 反映“大树 / 孤树”背景；评分中 `CDN +8`、`Hosting +1`、`ISP 0`、`Edu -8`、`未知 0`。 |
| `多IP` | 中 | 多 IP 一致更像正常大站；评分中 `一致 +5`、`部分不一致 -8`、`单IP/未知 0`。 |
| `链` | 中 | 证书链完整是健康信号；评分中 `完整 +5`、`不完整 -6`、`未知/失败 -2`。 |
| `头部` | 低 | 响应头自然度属于辅助站点卫生信号；评分中 `自然 +4`、`一般 +1`、`异常 -8`。 |
| `OCSP` | 最低 | v2.2 已降为轻量信号；评分中 `支持 +2`、`未提供 0`、`异常 -3`、`未知 0`。 |

实用理解：

- 分数接近时，优先选择左侧关键列更好的候选，而不是只看 `OCSP` 这种轻量信号。
- `ASN类型=CDN`、`多IP=一致` 这类背景项通常比 `OCSP=支持` 更重要，因为 REALITY 更看重“大树底下好乘凉”的伪装背景。
- 如果某个候选在前面的 `SAN / 证书 / 跳转 / WAF` 已经明显更差，即使后面的 `头部 / OCSP` 更好，也不应优先。
- 这套列顺序只是默认终端阅读顺序；CSV / JSONL 导出字段顺序不随终端表格重排而改变。

### 3. 脚本实际还计算了但默认终端不会单独成列、或仅在导出中更完整可见的字段

在 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 输出的完整 TSV 中，脚本实际还包含：

- `tcp_var`
- `tls_var`
- `ttfb_var`
- `page` 原始分类值
- `alpn_result`
- `cert_chain_status`
- `ocsp_stapling`
- `header_naturalness`
- `ip_consistency`
- `issuer`
- `final_url`
- `title`
- `content_type`
- `size`
- `remote_ip`
- `asn`
- `asn_type`

其中：

- 分项抖动会压缩进 `抖动T/TLS/F`；
- 终端 `页面` 列会把原始页面分类映射为 `网页站 / 弱网页 / 接口/下载 / 错误页 / -`；
- `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip` 仅在导出中可见；
- CSV / JSONL 导出字段仍保留稳定顺序，不受终端列重排影响。

### 4. `平均延迟` 的实际含义

在当前实现中，`平均延迟` 实际上直接等于 `avg_ttfb`，见 [`probe_one()`](reality_sni_probe_v2.2.sh:1314)。

也就是说：

- 它并不是 `TCP + TLS + TTFB` 的总和；
- 也不是独立新指标；
- 当前只是把 `avg_ttfb` 再以 `avg_latency` 名义输出一份。

因此阅读结果时，应把“平均延迟”理解为**平均首包时间**。

---

## 输出结果中每一项参数的详细解释

以下既包括默认表格列，也包括实际导出字段。

| 字段 | 含义 |
| --- | --- |
| `domain` | 输入域名，经 [`normalize_domain()`](reality_sni_probe_v2.2.sh:147) 规整后的最终检测目标。 |
| `code` | 首个有效样本的 HTTP 状态码。页面 / WAF / 跳转 / 头部判断主要基于这个样本。 |
| `avg_tcp` | 多次采样中 TCP 建连平均值，来源于 `curl time_connect`。 |
| `avg_tls` | 多次采样中 TLS 握手平均值，按 `time_appconnect - time_connect` 计算。 |
| `avg_ttfb` | 多次采样中 TTFB 平均值，来源于 `time_starttransfer`。 |
| `avg_latency` | 当前等同于 `avg_ttfb`。 |
| `jitter` | 完整抖动描述串，终端压缩显示为 `TCP/TLS/TTFBms`。 |
| `tcp_jitter` / `tcp_var` | TCP 建连抖动，即 `max_tcp - min_tcp`。 |
| `tls_jitter` / `tls_var` | TLS 握手抖动，即 `max_tls - min_tls`。 |
| `ttfb_jitter` / `ttfb_var` | TTFB 抖动，即 `max_ttfb - min_ttfb`。 |
| `tls13` | 由 [`check_tls13_from_sclient()`](reality_sni_probe_v2.2.sh:484) 判断。 |
| `x25519` | 由 [`check_x25519_from_sclient()`](reality_sni_probe_v2.2.sh:489) 判断。 |
| `h2` | HTTP/2 支持状态，可能来自 `curl` 样本、OpenSSL ALPN 兜底或 [`check_h2()`](reality_sni_probe_v2.2.sh:494)。 |
| `alpn_result` | 实际 ALPN 协商结果，来自 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.2.sh:418)。 |
| `cert_ok` | 是否成功获取证书 PEM，来自 [`check_cert_ok()`](reality_sni_probe_v2.2.sh:413)。 |
| `cert_chain_status` | 证书链状态，来自 [`check_cert_chain_status()`](reality_sni_probe_v2.2.sh:443)。 |
| `san_level` | SAN 覆盖级别，来自 [`check_san_level()`](reality_sni_probe_v2.2.sh:716)。 |
| `ocsp_stapling` | OCSP Stapling 状态，来自 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.2.sh:468)。 |
| `page` | 页面自然度，来自 [`page_naturalness()`](reality_sni_probe_v2.2.sh:817)。 |
| `header_naturalness` | HTTP 响应头自然度，来自 [`check_header_naturalness()`](reality_sni_probe_v2.2.sh:587)。 |
| `waf` | WAF / 挑战页判断，来自 [`detect_waf_challenge()`](reality_sni_probe_v2.2.sh:799)。 |
| `redirect` | 跳转自然度，来自 [`redirect_naturalness()`](reality_sni_probe_v2.2.sh:771)。 |
| `ip_consistency` | 多 IP 一致性状态，来自 [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632)。 |
| `stability` | 稳定性等级，来自 [`stability_level()`](reality_sni_probe_v2.2.sh:846)。 |
| `score` | 综合评分，来自 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010)。 |
| `result` | 最终结论，来自 [`judge_sni()`](reality_sni_probe_v2.2.sh:922)。 |
| `issuer` | 证书颁发者摘要。 |
| `final_url` | 最终 URL，用于判断跳转自然度。 |
| `title` | HTML 标题摘要。 |
| `content_type` | 响应 Content-Type。 |
| `size` | 响应体大小。 |
| `remote_ip` | 首个有效样本里的远端 IP。 |
| `asn` | `remote_ip` 对应的 AS 编号，查询失败为 `-`。 |
| `asn_type` | ASN 归类，`CDN / Hosting / ISP / Edu / 未知`。 |
| `expiry_days` | 证书剩余天数；当前不导出、不显示，只参与 `<14` 天硬保护。 |

---

## 每项参数的重要性

### 第一层：安全性 / 身份匹配主层

这些字段最关键，很多会直接触发“不建议”：

- `cert_ok`
- `san_level`
- `tls13`
- `x25519`
- `h2`
- `redirect`
- `expiry_days < 14`
- 数值项硬阈值

### 第二层：站点自然性与背景层

这些字段决定候选是否像真实大站、是否处在“大树”背景里：

- `asn_type`
- `ip_consistency`
- `cert_chain_status`
- `alpn_result`
- `page`
- `waf`
- `stability`
- `header_naturalness`
- `ocsp_stapling`

### 第三层：性能与稳定性补充层

这些字段先走门槛，再参与评分：

- `avg_tcp`
- `avg_tls`
- `avg_ttfb`
- `tcp_var`
- `tls_var`
- `ttfb_var`

超过软阈值直接“勉强”，超过硬阈值直接“不建议 / -9999”。通过门槛后，这些数值继续用于细分排序。

### 第四层：人工复核辅助层

这些字段不直接单独决定结论，但有助于人工解释：

- `issuer`
- `final_url`
- `title`
- `content_type`
- `size`
- `remote_ip`
- `asn`

---

## 结论判定逻辑

最终结论由 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 给出。

### 1. 硬门槛：直接判为“不建议”

满足任一条件，立即返回“不建议”：

```bash
cert_ok != 正常
或 san_level == 不匹配
或 san_level == 无SAN
或 san_level == 失败
或 redirect == 跨站跳转
或 tls13 != 支持
或 x25519 != 支持
或 h2 != 支持
或 expiry_days < 14
```

其中 `redirect / TLS13 / X25519 / H2 / SAN` 这组 Reality 核心硬条件由 [`is_reality_hard_fail()`](reality_sni_probe_v2.2.sh:861) 统一判断。

### 2. 数值项硬阈值：直接“不建议 / -9999”

由 [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881) 统一判断：

| 字段 | 硬阈值 | 触发后结论 |
| --- | --- | --- |
| `avg_tcp` / `TCP建连` | `> 280ms` | `不建议` |
| `avg_tls` / `TLS握手` | `> 650ms` | `不建议` |
| `avg_ttfb` / `TTFB` / `平均延迟` | `> 1200ms` | `不建议` |
| `tcp_var` / TCP 抖动 | `> 120ms` | `不建议` |
| `tls_var` / TLS 抖动 | `> 130ms` | `不建议` |
| `ttfb_var` / TTFB 抖动 | `> 650ms` | `不建议` |

命中数值硬阈值时，[`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 输出 `-9999`。

### 3. 直接降级为“勉强”

满足任一条件会直接返回“勉强”：

```bash
waf == 疑似挑战
```

或任一数值项超过软阈值：

| 字段 | 软阈值 | 触发后结论 |
| --- | --- | --- |
| `avg_tcp` / `TCP建连` | `> 200ms` | `勉强` |
| `avg_tls` / `TLS握手` | `> 300ms` | `勉强` |
| `avg_ttfb` / `TTFB` / `平均延迟` | `> 900ms` | `勉强` |
| `tcp_var` / TCP 抖动 | `> 80ms` | `勉强` |
| `tls_var` / TLS 抖动 | `> 90ms` | `勉强` |
| `ttfb_var` / TTFB 抖动 | `> 450ms` | `勉强` |

### 4. `通配匹配` 的单独分支

当 `san_level == 通配匹配` 时，脚本不会直接淘汰，而是进入单独分支：

- 若同时满足 `200/301/302`、非错误页、非“波动大”、`avg_tls <= 120ms`、`avg_ttfb <= 800ms`，则判为“可用”；
- 否则只要状态码属于 `200/301/302/403`，则判为“勉强”。

### 5. 满足高标准则判为“推荐”

必须同时满足：

```bash
code ∈ {200,301,302}
page != 错误页
redirect != 跨站跳转
h2 == 支持
stability != 波动大
avg_tls <= 120ms
avg_ttfb <= 800ms
```

### 6. 其余常见可接受情况判为“可用”

如果未提前命中“不建议 / 勉强 / 推荐”分支，但状态码属于 `200 / 301 / 302 / 403`，则返回“可用”。

### 7. 其他情况回落为“勉强”

剩余未命中的情况，统一返回“勉强”。

---

## 评分机制与权重细节

当前评分由 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 计算，整体分为：

1. **第一层：安全性主权重**；
2. **第二层：站点自然性与背景权重**；
3. **第三层：性能 / 稳定性补充细化**。

### 后续权重校准原则：REALITY 最大安全优先

本脚本的最高设计目标是 **REALITY 最大安全**，不是单纯寻找最低延迟域名。后续任何权重调整都应坚持以下层级：

1. **一票否决层**：证书失败、SAN 不匹配 / 无 SAN、TLS1.3 不支持、X25519 不支持、H2 不支持、跨站跳转、证书剩余天数 `< 14` 天，以及任一数值项超过硬阈值。
2. **强安全排序层**：ASN 类型、多 IP 一致性、证书链完整、ALPN=h2、页面自然度、WAF 正常、稳定性。
3. **弱安全 / 站点卫生层**：OCSP、响应头自然度、状态码细节等。
4. **性能门槛 + 细分层**：TCP、TLS、TTFB 均值与抖动先走软 / 硬阈值，通过门槛后再按分档加减分。

因此，当前排序原则宁可选择**小幅慢一些**但 CDN 背景明确、多 IP 一致、证书链完整、页面自然、抖动稳定的候选，也不要优先选择均值略低但 ASN 未知、抖动异常或站点特征不自然的候选。

### 第一层：安全性 / 证书匹配 / 协议安全能力

| 字段 | 取值 | 分数 |
| --- | --- | --- |
| `result` | 推荐 / 可用 / 勉强 / 不建议 | `+16 / +9 / +2 / -8` |
| `san_level` | 精确匹配 / 通配匹配 / 无SAN / 不匹配 / 失败 | `+32 / +12 / -18 / -42 / -32` |
| `cert_ok` | 正常 / 其他 | `+20 / -24` |
| `tls13` | 支持 / 其他 | `+14 / -10` |
| `x25519` | 支持 / 其他 | `+14 / -10` |
| `h2` | 支持 / 其他 | `+4 / -2` |
| `alpn_result` | h2 / http/1.1 / 未知 / 其他 | `+5 / +1 / 0 / -1` |
| `cert_chain_status` | 完整 / 不完整 / 未知失败 | `+5 / -6 / -2` |
| `ocsp_stapling` | 支持 / 未提供 / 异常 / 未知 | `+2 / 0 / -3 / 0` |
| `expiry_days` | `<14` | 不评分，但直接“不建议” |

### 第二层：站点自然性与可用性

| 字段 | 取值 | 分数 |
| --- | --- | --- |
| `code` | 200 / 301、302 / 403 / 404 / 405 / 其他 | `+10 / +7 / +2 / -10 / -12 / -20` |
| `page` | 像正常网站 / HTML但特征弱 / 非HTML响应 / 错误页 / 未知 | `+12 / +6 / -6 / -18 / 0` |
| `header_naturalness` | 自然 / 一般 / 异常 | `+4 / +1 / -8` |
| `redirect` | 无跳转同域 / 主子域自然跳转 / 跨站跳转 / 未知 | `+7 / +4 / -20 / 0` |
| `waf` | 正常 / 疑似拦截 / 疑似挑战 | `+5 / -12 / -28` |
| `ip_consistency` | 一致 / 部分不一致 / 单IP未知 | `+5 / -8 / 0` |
| `asn_type` | CDN / Hosting / ISP / Edu / 未知 | `+8 / +1 / 0 / -8 / 0` |

### 第三层：性能与稳定性（先门槛，后评分）

#### 数值门槛速查（先于普通评分）

| 字段 | 软阈值：直接“勉强” | 硬阈值：直接“不建议 / -9999” |
| --- | --- | --- |
| `avg_tcp` / TCP建连 | `> 200ms` | `> 280ms` |
| `avg_tls` / TLS握手 | `> 300ms` | `> 650ms` |
| `avg_ttfb` / TTFB / 平均延迟 | `> 900ms` | `> 1200ms` |
| `tcp_var` / TCP 抖动 | `> 80ms` | `> 120ms` |
| `tls_var` / TLS 抖动 | `> 90ms` | `> 130ms` |
| `ttfb_var` / TTFB 抖动 | `> 450ms` | `> 650ms` |

#### `stability`

- `稳定`：`+7`
- `一般`：`+1`
- `波动大`：`-10`

#### `avg_tls` 分档

- `<= 20ms`：`+8`
- `<= 30ms`：`+7`
- `<= 40ms`：`+6`
- `<= 55ms`：`+5`
- `<= 70ms`：`+4`
- `<= 90ms`：`+3`
- `<= 120ms`：`+2`
- `<= 160ms`：`0`
- `<= 220ms`：`-6`
- `<= 300ms`：`-14`
- `> 300ms`：`-24`

#### `avg_ttfb` 分档

- `<= 120ms`：`+9`
- `<= 180ms`：`+8`
- `<= 240ms`：`+7`
- `<= 320ms`：`+6`
- `<= 420ms`：`+5`
- `<= 550ms`：`+4`
- `<= 700ms`：`+2`
- `<= 900ms`：`-6`
- `<= 1200ms`：`-18`
- `<= 1600ms`：`-32`
- `> 1600ms`：`-50`

#### `avg_tcp` 分档

- `<= 15ms`：`+6`
- `<= 25ms`：`+5`
- `<= 35ms`：`+4`
- `<= 50ms`：`+3`
- `<= 70ms`：`+2`
- `<= 100ms`：`+1`
- `<= 140ms`：`0`
- `<= 200ms`：`-5`
- `<= 280ms`：`-12`
- `> 280ms`：`-22`

#### 抖动分档

| 字段 | 正常范围加分 | 中等异常 | 严重异常 |
| --- | --- | --- | --- |
| `tcp_var` | `<=5ms +2`、`<=10ms +1` | `55–80ms -6`、`80–120ms -12` | `>120ms -20` |
| `tls_var` | `<=5ms +2`、`<=10ms +1` | `60–90ms -10`、`90–130ms -16` | `>130ms -25` |
| `ttfb_var` | `<=20ms +2`、`<=40ms +1` | `320–450ms -18`、`450–650ms -30` | `>650ms -45` |

### 关于分数的阅读方式

- 分数不是标准化百分制，也没有被裁剪到 `0~100`；
- 某些很差的候选可以出现负分；
- 命中 [`is_reality_hard_fail()`](reality_sni_probe_v2.2.sh:861) 或 [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881) 硬阈值的记录，评分会直接输出 `-9999`；
- 某些优质候选可以超过 `100`；
- 它更适合作为**同批候选之间的排序依据**。

---

## ASN 类型与“大树底下好乘凉”伪装原则

ASN（Autonomous System Number）可以粗略理解为：互联网上“谁家管哪一片 IP 地址”。一个域名最终落在哪个 ASN 上，会影响它是不是像一个“大树底下”的正常大流量站点。

### 为什么 REALITY 要关心 ASN

REALITY 的安全目标不是“找一个能访问的域名”，而是“找一个被主动探测时看起来足够自然、封禁代价足够高的目标”。

直观类比：

- `CDN`：大树，背后有海量正常网站和正常流量，优先级最高；
- `Hosting`：普通机房，有一定背景噪声，但不如 CDN；
- `ISP`：中性，视具体站点而定；
- `Edu`：大学 / 教育网常常是孤树，容易显得小众；
- `未知`：不惩罚，但建议人工复核。

### 当前 ASN 分类

| 类型 | 分数 | 含义 |
| --- | --- | --- |
| `CDN` | `+8` | Cloudflare、Akamai、Fastly、Microsoft、Google、Amazon 等大背景网络 |
| `Hosting` | `+1` | 常见云 / 机房网络 |
| `ISP` | `0` | 运营商网络，中性 |
| `Edu` | `-8` | 教育机构 / 学术网，小众背景惩罚 |
| `未知` | `0` | 查询失败或无法分类，不因工具缺失直接惩罚 |

### 建议的人工复核流程

1. 优先看 `结论` 和 `评分`；
2. 分数接近时，从 `SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP` 从左到右比较；
3. 若 `ASN类型=CDN` 且 `多IP=一致`，通常比 `ASN类型=未知` 更优；
4. 若候选是 `Edu`，即使速度很快，也应结合页面、证书、IP 背景谨慎使用；
5. 对最终候选导出 CSV / JSONL，查看 `remote_ip` 与 `asn` 做人工确认。

---

## 排序与筛选说明

### 1. 先过滤，再排序

脚本会先调用 [`filter_results()`](reality_sni_probe_v2.2.sh:1614)：

- `--only-good`：只保留“推荐 / 可用”；
- `--min-score N`：只保留分数 `>= N` 的记录。

### 2. 当前真实排序键

过滤完成后，脚本在 [`main()`](reality_sni_probe_v2.2.sh:1633) 中按以下键排序：

1. Reality 核心硬条件是否满足；
2. SAN 等级（精确匹配优先于通配匹配）；
3. 结论档位（推荐 > 可用 > 勉强 > 不建议）；
4. `score` 数值；
5. TLS 抖动；
6. TTFB 抖动。

也就是说，当前不是简单按 `score` 单键排序，而是先看 Reality 核心条件与 SAN 等级，再看结论档位和分数，最后用稳定性细项作 tie-break。

### 3. `--only-good` 与排序的关系

启用 `--only-good` 后，“勉强 / 不建议”会在排序前就被过滤掉，因此最终表格和导出中只剩“推荐 / 可用”。

### 4. `--min-score` 与负分

由于评分可能出现负值，`--min-score 0` 并不等于“显示全部”，它会把负分结果过滤掉。

---

## 示例输出与阅读方式

下面给出一个按当前列布局整理后的示意表。注意内容只是示意，不代表固定分值。

```txt
REALITY SNI 专业评估 v2.2
域名                       | 码   | TCP建连  | TLS握手  | TTFB     | 平均延迟 | 抖动T/TLS/F    | TLS13  | X25519 | H2     | ALPN     | SAN      | 证书 | 跳转           | WAF      | 页面       | 稳定性 | ASN类型  | 多IP       | 链         | 头部   | OCSP   | 评分  | 结论
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
www.hosei.ac.jp            | 200  | 11ms     | 13ms     | 29ms     | 29ms     | 5/0/3ms        | 支持   | 支持   | 支持   | h2       | 精确匹配 | 正常 | 无跳转/同域    | 正常     | 网页站     | 稳定   | CDN      | 一致       | 完整       | 一般   | 未提供 | 194   | 推荐
www.tus.ac.jp              | 200  | 14ms     | 13ms     | 36ms     | 36ms     | 14/1/14ms      | 支持   | 支持   | 支持   | h2       | 精确匹配 | 正常 | 无跳转/同域    | 正常     | 网页站     | 稳定   | 未知     | 一致       | 完整       | 一般   | 支持   | 186   | 推荐
www.chuo-u.ac.jp           | 200  | 39ms     | 14ms     | 928ms    | 928ms    | 2/0/17ms       | 支持   | 支持   | 支持   | h2       | 精确匹配 | 正常 | 无跳转/同域    | 正常     | 网页站     | 稳定   | CDN      | 一致       | 完整       | 自然   | 未提供 | 153   | 勉强
www.kogakuin.ac.jp         | 200  | 11ms     | 24ms     | 47ms     | 47ms     | 3/10/14ms      | 不支持 | 不支持 | 不支持 | http/1.1 | 精确匹配 | 正常 | 无跳转/同域    | 正常     | 网页站     | 稳定   | 未知     | 单IP/未知  | 完整       | 自然   | 未提供 | -9999 | 不建议
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

阅读建议：

1. 先看 `结论`，快速分组；
2. 再看左侧固定基础列：`TLS13`、`X25519`、`H2`、`ALPN`，确认 Reality 协议能力；
3. 如果 `评分 = -9999`，基本可直接视为命中了 Reality 核心硬淘汰或数值硬阈值；
4. 对“推荐 / 可用”且分数接近的候选，从 `SAN` 开始按列从左到右复核：`SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`；
5. 再看 `评分`，在同档位、关键列相近时做最终排序；
6. 最后结合 `TCP建连`、`TLS握手`、`TTFB` 与 `抖动T/TLS/F` 做性能复核；
7. 如需复查站点细节，请查看导出的 `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip`。

按列排序的直观例子：如果两个候选前半段性能几乎一样，一个是 `ASN类型=CDN / OCSP=未提供`，另一个是 `ASN类型=未知 / OCSP=支持`，通常前者更适合作为 REALITY 候选，因为 ASN 类型的“大树背景”权重高于 OCSP 这种轻量站点卫生信号。

---

## CSV / JSONL 导出字段说明

当前导出字段由 [`export_csv()`](reality_sni_probe_v2.2.sh:1578) 与 [`export_jsonl()`](reality_sni_probe_v2.2.sh:1597) 决定，顺序如下：

1. `domain`
2. `code`
3. `avg_tcp`
4. `avg_tls`
5. `avg_ttfb`
6. `avg_latency`
7. `jitter`
8. `tcp_jitter`
9. `tls_jitter`
10. `ttfb_jitter`
11. `tls13`
12. `x25519`
13. `h2`
14. `alpn_result`
15. `cert_ok`
16. `cert_chain_status`
17. `san_level`
18. `ocsp_stapling`
19. `page`
20. `header_naturalness`
21. `waf`
22. `redirect`
23. `ip_consistency`
24. `stability`
25. `score`
26. `result`
27. `issuer`
28. `final_url`
29. `title`
30. `content_type`
31. `size`
32. `remote_ip`
33. `asn`
34. `asn_type`

需要注意：

- 导出字段里没有 `expiry_days`；
- `expiry_days` 只参与 `< 14` 天临期硬保护，不再参与评分；
- `tcp_jitter` / `tls_jitter` / `ttfb_jitter` 在导出中会被格式化为带 `ms` 后缀的字符串；
- 若底层抖动值为 `999999`，v2.2 导出会写成 `-`，表示“该项抖动不可得”；
- 默认终端表格不会输出 `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip`；
- 默认终端表格中的 `页面` 列是摘要标签，而导出中的 `page` 保留原始分类值；
- 默认终端为了阅读，会把 `SAN / 证书 / 跳转 / WAF / 页面 / 稳定性 / ASN类型 / 多IP / 链 / 头部 / OCSP` 按权重展示；CSV / JSONL 导出字段仍保留原始稳定顺序。

### CSV 表头

```csv
"domain","code","avg_tcp","avg_tls","avg_ttfb","avg_latency","jitter","tcp_jitter","tls_jitter","ttfb_jitter","tls13","x25519","h2","alpn_result","cert_ok","cert_chain_status","san_level","ocsp_stapling","page","header_naturalness","waf","redirect","ip_consistency","stability","score","result","issuer","final_url","title","content_type","size","remote_ip","asn","asn_type"
```

### JSONL 单行结构示意

```json
{"domain":"www.microsoft.com","code":"200","avg_tcp":"24ms","avg_tls":"31ms","avg_ttfb":"118ms","avg_latency":"118ms","jitter":"TCP:5ms/TLS:8ms/TTFB:24ms","tcp_jitter":"5ms","tls_jitter":"8ms","ttfb_jitter":"24ms","tls13":"支持","x25519":"支持","h2":"支持","alpn_result":"h2","cert_ok":"正常","cert_chain_status":"完整","san_level":"精确匹配","ocsp_stapling":"支持","page":"像正常网站","header_naturalness":"自然","waf":"正常","redirect":"无跳转/同域","ip_consistency":"一致","stability":"稳定","score":"194","result":"推荐","issuer":"C=US, O=Microsoft Corporation, CN=Microsoft Azure RSA TLS Issuing CA 03","final_url":"https://www.microsoft.com/","title":"Microsoft – AI, Cloud, Productivity, Computing, Gaming & Apps","content_type":"text/html; charset=utf-8","size":"65842","remote_ip":"23.45.119.216","asn":"AS8075","asn_type":"CDN"}
```

> 注意：这里的 `score=194` 是按当前 v2.2 权重对上方示意字段推导出的示意值，不代表固定实测值。

---

## 局限性

当前版本依然有一些明确局限：

1. [`check_cert_ok()`](reality_sni_probe_v2.2.sh:413) 只判断“有没有拿到 PEM”，不等于完整证书链校验通过；
2. [`check_cert_chain_status()`](reality_sni_probe_v2.2.sh:443) 与 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.2.sh:468) 都基于 `openssl s_client` 文本输出，不是结构化 PKI / OCSP 验证器；
3. [`check_tls13_from_sclient()`](reality_sni_probe_v2.2.sh:484) 和 [`check_x25519_from_sclient()`](reality_sni_probe_v2.2.sh:489) 是基于文本匹配，不是结构化 TLS 指纹分析；
4. 页面 / 头部 / WAF / 跳转判断都属于启发式规则，不代表完整浏览器视角；
5. `avg_latency` 当前只是 `avg_ttfb` 的别名；
6. `expiry_days` 只参与 `< 14` 天临期硬保护，但当前不在默认终端和导出字段中显示；
7. 多 IP 一致性抽样当前只检查最多 3 个 IPv4 A 记录，不覆盖 AAAA，也不保证穷尽所有边缘节点；
8. ASN 分类依赖 `whois.cymru.com` 返回的 AS 名字做关键词匹配，不是权威 ASN 数据库，可能错判；
9. ASN 查询依赖外网 whois 服务，批量扫描时可能偶发限流；遇到时脚本会把对应记录写为 `asn="-" / asn_type="未知"`，不中断主流程；
10. 评分体系虽然已经从“速度优先”转向“安全性主权重”，但仍然只是启发式排序工具，不是绝对真理；
11. 结果高度依赖你本机的网络出口、DNS、地区与链路状态；
12. 终端表格虽然已做中英文宽度修复，但不同终端字体、East Asian Width 策略下仍可能存在轻微视觉偏差；
13. 默认终端和 CSV / JSONL 都会把抖动哨兵值 `999999` 摘要显示为 `-`，语义是“该项抖动不可得”；
14. 缺少 `curl` / `openssl` / 合适 locale 时，脚本会尽量退化运行，但结果解释必须更保守。

---

## FAQ

### 1. 为什么某些站点速度很好，分数却不高？

因为当前 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 的主权重已经放在证书、SAN、TLS1.3、X25519、ALPN、证书链这些安全与身份特征上。速度快只能在第三层补充分中加分，无法弥补根本性的证书或协议短板。OCSP 仍会参与评分，但已下调为轻量信号；`expiry_days` 只保留 `< 14` 天临期硬保护，不再参与评分排序。

### 2. 为什么 `通配匹配` 不再直接判死？

因为当前 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 已把 `通配匹配` 调整为“次优可用”。它不能拿到和 `精确匹配` 一样高的权重，但如果其他条件好，仍可得到“可用”；如果页面或稳定性较弱，则多半回落为“勉强”。

### 3. 为什么 `403` 有时还是“可用”或“勉强”？

因为当前 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 对 `403` 的处理是：只要没有提前命中证书 / SAN / 到期 / Reality 核心硬性淘汰条件，`403` 仍可能落入“可用”或“勉强”。这反映的是“可作为候选参考”，不等于“用户访问体验优秀”。

### 4. 为什么默认终端里能看到 `ALPN`、`OCSP`、`链`、`头部`、`多IP`，而且后半段列顺序变了？

因为当前 [`print_table()`](reality_sni_probe_v2.2.sh:1539) 的表头已经扩展，新增这些判定列，同时通过 [`table_display_width()`](reality_sni_probe_v2.2.sh:1447) 与 [`table_fit_text()`](reality_sni_probe_v2.2.sh:1466) 修复了中英文混排时的表格对齐问题。

v2.2 后半段站点判断列现在按阅读权重排列为：`SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`。这样分数接近时，不熟悉各项权重的用户也可以优先看左侧更重要的项，再看右侧轻量辅助项。

### 5. 为什么“平均延迟”和 `TTFB` 一样？

因为当前实现中 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 直接把 `avg_ttfb` 复用为 `avg_latency` 输出，它目前就是展示别名，不是新的独立指标。

### 6. 为什么默认并发改成 1 后，速度并没有慢很多？

因为这个脚本的耗时主要不是“同时跑多少个域名”决定的，而是每个域名内部有不少固定串行步骤：3 次 `curl` 采样、一次 `openssl s_client`、证书解析、H2 / ALPN / OCSP / 多 IP / ASN 等检测。并发只控制不同域名之间的 worker 数量。

在低配 VPS 上，高并发容易把 CPU 打满，反而污染 TLS / TTFB / 抖动数据。默认 `-j 1` 牺牲的速度通常不多，但检测质量更稳。需要快速初筛时可以手动使用 `-j 2` 或更高，并在最终候选上用默认低并发复测。

### 7. v2.2 为什么仍没有做 ECH / HTTP/3 / PQC 检测？

因为对 REALITY 的实际帮助极小，代价却很大：

- **ECH**：REALITY 要求 SNI 明文，和 ECH 的设计目标互斥；
- **HTTP/3 / QUIC**：REALITY 跑在 TCP 上，目标是否支持 H3 和伪装效果无关；
- **PQC**：这是 Xray / utls 客户端层要解决的问题，不是 SNI 探测职责。

### 8. 我该用旧版还是 v2.2？

默认推荐 **v2.2**。它包含 ASN 查询与分类、HTTP/2 退化修复、SAN 多行解析、macOS/BSD 日期解析、导出哨兵值友好显示、默认低并发、数值阈值和安全优先评分权重。

继续用旧版的唯一合理理由是：下游消费脚本严格依赖旧版某个具体的绝对分数阈值，且短期内不方便重新校准。

### 9. v2.2 跑同一个域名，为什么在不同服务器上分数不一样？

**都对，但只有“你实际部署 REALITY 的那台服务器”上的分数才有意义。**

脚本测的是“从当前这台服务器出口到目标 SNI 的真实链路质量”。不同服务器的上游运营商、peering 质量、transit 路径都不一样，结果差 10 倍都很正常。

**正确用法**：在你要部署 REALITY 的那台服务器上跑脚本，选它给出的高分候选。不要把一台服务器的结果搬到另一台。

### 10. 脚本把 `www.microsoft.com` 标成“疑似挑战”、`www.apple.com` 标成“无SAN”，这正常吗？

多半是本机环境问题，不是目标域名的实际情况。常见触发：

- Windows Git Bash / MSYS2 下的 `curl` 或 `openssl` 输出格式与 Linux 不同；
- 本机有代理、防火墙或杀软 MITM；
- 网络质量差，握手超时导致 TLS 输出残缺；
- 当前出口到目标站存在临时异常。

最可靠的验证环境是 Debian 12 / Ubuntu 22.04+ 上 stock `curl + openssl`。如果打算长期部署，在你实际跑 REALITY 的那台服务器上跑 v2.2 得到的结果才算数。
