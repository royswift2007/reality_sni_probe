# REALITY SNI Probe v2 / v2.1 / v2.2

用于**批量评估域名是否适合作为 REALITY SNI 候选站点**的 Bash 检测脚本。

- 当前维护脚本 v2.2：[`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh)
- 历史脚本 v2.1：[`reality_sni_probe_v2.1.sh`](reality_sni_probe_v2.1.sh)

v2.2 是 v2.1 的兼容性与评分校准修订版：在 v2.1 的 ASN、随机抖动和评分校准基础上，修复了版本标识、HTTP/2 探测退化、macOS/BSD 证书日期解析、多行 SAN 解析、导出哨兵值展示，并下调 OCSP、移除证书剩余天数评分权重。关于 v2.1 的基础升级见 [v2.1 更新说明](#v21-更新说明)，关于 v2.2 的兼容性修复见 [v2.2 更新说明](#v22-更新说明)。

---

## ⚠️ 使用前必读：必须在 REALITY 服务器上运行

**这是本脚本最容易被忽略、但最关键的一条使用前提。**

脚本测出来的 **TCP 建连、TLS 握手、TTFB、抖动、稳定性** 全部是 **"从当前这台服务器出口到目标 SNI 的真实链路质量"**。这些数值和你的工位、手机、其他服务器上看到的**完全不一样**。

### 为什么必须在 REALITY 服务器上跑

REALITY 的伪装前提是：**当 GFW 主动探测你的节点时，服务端会向真实 SNI 目标转发握手**。GFW 观察到的握手特征（延迟、证书、ALPN 等）来自 **"REALITY 服务器到真实目标"** 这条路径——而不是你本地的路径。

所以：

- **同一个域名在不同服务器上分数可能差 10 倍**——这是正常的，反映的是"对这台服务器而言合不合适"
- **在 A 服务器测出的"推荐"候选，在 B 服务器上可能只是"勉强"或直接"不建议"**
- **从你笔记本 / 开发机上跑出来的结果，绝对不能搬到生产 REALITY 服务器上用**

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
| 服务器 B (日本 IP) | 700–1100ms | 98 分（"可用"） |
| 服务器 C (日本 IP) | 50–100ms | 192 分（"推荐"） |

**两台都是日本 IP，但上游 transit 路径不同，脚本评分正确反映了这个差异**。如果在服务器 B 上跑完结果拿去服务器 C 用，会选错 SNI；反过来也一样。

> **记住：脚本给出的分数只对"这台服务器当下的出口"负责。换服务器要重新跑。**

---

## 目录

- [⚠️ 使用前必读](#️-使用前必读必须在-reality-服务器上运行)
- [项目简介](#项目简介)
- [v2.2 更新说明](#v22-更新说明)
- [v2.1 更新说明](#v21-更新说明)
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
- [ASN 类型与"大树底下好乘凉"伪装原则](#asn-类型与大树底下好乘凉伪装原则)
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
3. 是否体现 `TLSv1.3`、是否出现 `X25519`；
4. 是否支持 HTTP/2；
5. 页面形态是否更像正常站点，还是明显错误页 / 挑战页 / 可疑拦截；
6. 跳转是否自然，是否出现跨站跳转；
7. 多次采样下的 TCP / TLS / TTFB 是否稳定；
8. 最终是否达到 `推荐`、至少 `可用`，还是仅 `勉强` / `不建议`。

脚本内部几个关键函数为：

- [`probe_one()`](reality_sni_probe_v2.2.sh:1248)：单域名完整检测主流程；
- [`judge_sni()`](reality_sni_probe_v2.2.sh:922)：根据硬门槛和分支规则给出结论；
- [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010)：按当前三层权重累计分数；
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

v2.2 是 v2.1 的兼容性与评分校准修订版，核心脚本位于 [`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh)。命令行参数继续兼容 v2.1。

### 这次修复了什么

1. **版本标识一致性**：终端标题与脚本注释统一显示 v2.2。
2. **HTTP/2 探测退化更保守**：当系统 `curl` 未编译 HTTP/2 支持时，脚本不再静默把 H2 判成 `不支持`，而是返回 `未知`，并优先使用 `openssl s_client` 的 ALPN=`h2` 结果兜底。
3. **macOS / BSD 日期兼容**：证书剩余天数解析不再只依赖 GNU `date -d`，会依次尝试 GNU `date -d`、BSD `date -j -f`，以及可选的 `python3` 解析。
4. **SAN 多行解析修复**：`check_san_level()` 不再只读取 `X509v3 Subject Alternative Name` 后一行，避免证书 SAN 换行时误判为 `不匹配` 或 `无SAN`。
5. **导出哨兵值更友好**：CSV / JSONL 中的 `tcp_jitter`、`tls_jitter`、`ttfb_jitter` 对不可得值输出 `-`，不再暴露内部哨兵 `999999ms`。
6. **依赖退化提示**：启动主流程后会提示缺失 `curl`、`openssl`、`whois`、`timeout/gtimeout`、`getent/dig/nslookup` 对结果的影响。
7. **UTF-8 locale 选择更稳**：候选 locale 改用固定字符串匹配，避免正则替换导致异常匹配。
8. **curl 临时文件读取更安静**：当 `curl` 超时、DNS/TLS 失败或远端提前断开导致响应体/响应头临时文件未生成时，脚本不再向终端打印 `No such file or directory`，而是按失败样本继续统计。
9. **OCSP 权重降为轻量信号**：`OCSP=支持` 只小幅加分，`未提供` 不再扣分，避免正常站点因未 Staple 被过度惩罚。
10. **证书剩余天数不再参与评分**：证书剩余天数只保留 `< 14` 天直接 `不建议` 的临期硬保护，不再用剩余天数长短拉开大站排序。
11. **TTFB 异常区间扣分加重**：`avg_ttfb > 900ms` 已经不只是“慢”，而是当前出口到目标站点的路径/站点自然性风险信号；v2.2 进一步加重 `900ms+` 档位扣分，避免数百毫秒级延迟差被 `CDN`、多 IP 一致性这类背景加分覆盖。
12. **数值项门槛进入结论判定**：`avg_tcp / avg_tls / avg_ttfb / tcp_var / tls_var / ttfb_var` 不再只参与评分；超过软阈值直接降为 `勉强`，超过硬阈值直接判为 `不建议` 并输出 `-9999`。
13. **默认并发降为 1**：默认优先保证低配 REALITY 服务器上的检测质量，避免 CPU 满载污染 TLS / TTFB / 抖动；需要快速初筛时仍可手动使用 `-j NUM`。
14. **默认终端关键列按权重重排**：`码 / TCP / TLS / TTFB / 抖动 / TLS13 / X25519 / H2 / ALPN` 的顺序保持不变；仅把后半段站点判断列按权重重排为 `SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`，方便小白在分数接近时从左到右筛选。

这些变更不会新增 CSV / JSONL 字段，只改变兼容性、退化语义、评分校准、默认并发、终端展示顺序和文档一致性。

---

## v2.1 更新说明

v2.1 是 v2 的增量升级，历史脚本位于 [`reality_sni_probe_v2.1.sh`](reality_sni_probe_v2.1.sh)，当前维护版本为 [`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh)。v2.2 继承 v2.1 的全部参数，并在 v2.1 评分体系上继续做安全优先校准。

### 为什么有 v2.1

v2 的评分体系已经覆盖了 REALITY 伪装最核心的几层指标（证书、SAN、TLS1.3/X25519/H2、页面形态、稳定性），但有一个明显缺口：

> **"这个域名背后的 IP 所在那条网络管道，到底是不是一棵大树？"**

这就是 ASN（Autonomous System Number，自治系统编号）要回答的问题。一个小众 ASN 上的孤立域名和一个 Cloudflare 边缘节点上的域名，哪怕 TLS 握手、证书、页面看起来都一样，被 GFW 主动封禁的边际代价完全不同——前者没邻居陪你挡枪，后者背后是半个互联网。

v2.1 的核心就是把这层"背景噪声"量化后纳入评分。顺带修掉 v2 的几个隐性 bug，并加了两个大批量扫描时方便的小参数。

### 刻意**没做**的几件事

评估 PRD 里提到的几个方向后，以下都**确认不做**：

- **ECH（加密 ClientHello）探测**：REALITY 协议本身要求 SNI 明文，和 ECH 功能互斥。探测目标是否支持 ECH 对 REALITY 伪装效果无加成，纯属噪声；
- **HTTP/3 / QUIC 真实握手**：REALITY 跑在 TCP 上，目标域名是否支持 H3 与伪装效果无关。Debian 12 默认 `curl` 也不带 `--http3`；
- **PQC（X25519MLKEM768 等）协商检测**：方向错位——PQC 是客户端 utls 的事，不是 SNI 探测的职责。检测"目标服务端是否支持 PQC"并不会让你的 REALITY 客户端握手变得更像 Chrome；
- **TFO / MSS 等 L4 指纹**：需要 raw socket 或 root 权限，破坏脚本"普通用户单文件 Bash"的运行姿态，投入产出比差；
- **切换到 BoringSSL / quictls**：上面这些都不做，底层换栈就没有意义。

### 这次升级具体改了什么

#### 新增 1：ASN 查询与分类（核心变化）

新增函数 `lookup_asn()`：

- 通过 `whois -h whois.cymru.com " -v IP"` 取得 IP 的 AS 号和 AS 名字；
- 基于名字关键词启发式分类为 `CDN / Hosting / ISP / Edu / 未知`；
- 把分类结果纳入评分。

评分权重：

- `CDN`：`+8`
- `Hosting`：`+1`
- `ISP`：`+0`
- `Edu`：`−8`
- `未知`：`+0`

完整原理、判断流程和"大树 / 孤树"决策清单见 [ASN 类型与"大树底下好乘凉"伪装原则](#asn-类型与大树底下好乘凉伪装原则)。

#### 新增 2：并发随机抖动 `--jitter`

新增命令行选项 `--jitter NUM`（单位：毫秒，默认 `0` 即禁用）。启用后每个 worker 启动前加 `0–NUM` 毫秒的随机延迟。

- 目的：避免大批量域名以完全相同的节奏连发请求，降低被云端 WAF 聚类识别为扫描器的概率；
- 对小批量（几十个域名）几乎无感知；
- 对几百 ~ 上千域名的批量扫，建议设置 `--jitter 200` 到 `--jitter 500`。

#### 新增 3：`--no-asn` 跳过 ASN 查询

用途：

- 大批量扫描时 `whois.cymru.com` 可能限流；
- 某些运行环境没有 `whois` 命令；
- 不需要 ASN 字段时每域可省约 0.3–0.8 秒。

启用 `--no-asn` 后，`asn` / `asn_type` 字段一律写为 `"-" / "未知"`，评分里 ASN 相关加减分为 0。

#### 新增 4：默认终端表格新增 `ASN类型` 列

[`print_table()`](reality_sni_probe_v2.2.sh:1539) 会显示 `ASN类型`，取值 `CDN / Hosting / ISP / Edu / 未知`。当前 v2.2 已把 `SAN / 证书 / 跳转 / WAF / 页面 / 稳定性 / ASN类型 / 多IP / 链 / 头部 / OCSP` 这组站点判断列按权重重排，方便一眼看到候选是大树还是孤树，也方便在分数接近时从左到右复核关键项。

同时把 `H2` 列宽从 `4` 调到 `6`，避免中文"不支持"三字被截断成 `...`。

#### 新增 5：CSV / JSONL 导出新增两个字段

在 v2 的 32 个字段后追加：

33. `asn`（ASN 编号，形如 `AS13335`）
34. `asn_type`（ASN 归类）

追加位置在末尾，**保持前 32 列与 v2 完全兼容**——下游只读 v2 字段的脚本可以不改。

#### Bug 修复 1：单样本抖动误判

v2 在只有 1 个成功采样时，`max - min = 0`，会被误判为"抖动极小"并因此加分。v2.1 起改为：当成功样本数 < 2 时，对应抖动值直接写为哨兵 `999999`，后续表格与导出显示为 `-`；在当前 v2.2 评分里，这个哨兵会落入抖动最差档，等价于把“样本不足、稳定性不可证”视为风险信号，而不是给“零抖动”加分。

#### Bug 修复 2：check_h2 在无有效样本时多走一轮

v2 里即使所有 `curl` 采样都失败，仍会额外调用 [`check_h2()`](reality_sni_probe_v2.2.sh:494) 再探一次。v2.1 先把 `best_code` 为空的情况改为不再多探；当前 v2.2 在此基础上又改得更保守：如果 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.2.sh:418) 已协商到 `h2`，则用 ALPN 兜底记为 `支持`，否则在没有有效 HTTP 样本时记为 `未知`，避免把“本机无法确认”写成目标站明确 `不支持`。

#### Bug 修复 3：calc_sni_score 的链式 `&& ||` 结构

v2 的第三层性能 / 抖动分档写法是：

```bash
[ "$tls_num" -le 20 ] && score=$((score + 8)) || \
[ "$tls_num" -le 30 ] && score=$((score + 7)) || ...
```

表面上像 `if/elif`，但 bash 里 `&&` 和 `||` 是**等优先级、左结合**的。当某个桶命中并执行赋值后，后续所有 `|| [ ... ] && ...` 的测试条件仍会继续求值，**只要条件为真就继续累加**。

例如 `tls_num = 30` 时，文档规定加 `+7`，v2 实际累加的是 `+7 + 6 + 5 + 4 + 3 + 2 + 0 − 2 − 4 = +21`。越快越稳的候选分数虚高越多。

v2.1 把这 6 个分档块（`avg_tcp / avg_tls / avg_ttfb / tcp_var / tls_var / ttfb_var`）全部改写为标准 `if/elif/else` 结构。

#### 权重重新校准：异常值加倍扣分，抖动加分压缩（v2.1 核心调整）

在 bug 修复 3 的基础上，v2.1 进一步**重新校准了第二层和第三层的分值**。核心原则：

> **SNI 选择的最高目标是安全性。任何偏离"正常大厂健康站点"典型值的指标本身就是风险信号——因此偏离越大，扣分越陡，不能线性降低。**

具体改动：

1. **第三层性能档位**（`avg_ttfb / avg_tls / avg_tcp`）：正常范围内加分不变，但异常范围扣分从"线性"改为"指数"式陡降。例如 `avg_ttfb > 1600ms` 从 `-6` 改为 `-35`。
2. **第三层抖动项**（`ttfb_var / tls_var / tcp_var`）：加分大幅压缩（例如 `ttfb_var <= 20ms` 从 `+6` 改为 `+2`），因为抖动"很小"不一定代表站点稳定；减分则加倍（例如 `ttfb_var > 650ms` 从 `-7` 改为 `-45`）。
3. **第二层异常扣分加重**：`waf=疑似挑战` 从 `-14` 改为 `-28`，`redirect=跨站跳转` 从 `-10` 改为 `-20`，`page=错误页` 从 `-9` 改为 `-18`，`asn_type=Edu` 从 `-4` 改为 `-8`。

**实际效果**：以两个 CDN 托管的大学域名为例（都是"可用"、"精确匹配"、"CDN"），只有 `avg_ttfb` 和抖动明显不同：

| 站点 | avg_ttfb | ttfb 抖动 | v2.1 早期分数 | 权重重新校准后 |
| --- | --- | --- | --- | --- |
| 站点 A | 1722ms | 2ms | 186 | **146** |
| 站点 B | 562ms | 230ms | 189 | **183** |

v2.1 早期两者差距只有 3 分，完全无法体现"一个 TTFB 极端异常、一个 TTFB 正常"的质变。重新校准后差距拉到 37 分，**评分终于反映安全性优劣**。

**影响**：

- **第二、三层的分值表**在 v2 和 v2.1 之间有实质变化，详见 [评分机制与权重细节](#评分机制与权重细节)；
- **好站点的绝对分数略降**（从 v2 虚高回落到合理值）；
- **异常站点的绝对分数大幅下降**，不再能靠"刷性能细项"蒙混过关；
- **排序合理性大幅提升**：TTFB 高达 1500+ms 的站点再也不会和 500ms 的站点同分；
- 如果你之前靠 v2 的绝对分数设置了 `--min-score` 阈值，**一定需要重新校准基线**。

#### Bug 修复 4：worker 继承 env 变量被顶层赋值覆盖（隐性 v2 bug）

v2 主进程启动 worker 时用 `env TIMEOUT_SEC=... SAMPLES=... TMP_ROOT=... bash "$0" --worker`，但脚本顶部 `TIMEOUT_SEC=10` 等无条件赋值会把环境变量覆盖回默认值。结果：

- `--samples 5` 传不到 worker；
- `--timeout 15` 传不到 worker；
- `TMP_ROOT` 被置空，worker 写 body/header 文件时落到根目录。

v2.1 把所有这类全局默认值改成 `${VAR:-default}` 形式，既保留脚本直接运行时的默认值，又允许父进程 env 传入覆盖。

#### Bug 修复 5：`check_curl_once` 的 `|` 分隔符冲突（隐性 v2 bug）

v2 用 `|` 作为 11 字段的内部分隔符，但 HTTP 响应头（CSP、Set-Cookie、部分 title）可能天然含 `|`，导致后续 `cut -d'|' -f11` 把错位字段取出来。最直接的表现：CSV/JSONL 里 `remote_ip` 列出现的不是 IP，而是一大段响应头文本。

v2.1 改为使用 ASCII Unit Separator `\x1f`（\\0x1F）作为分隔符，响应头内容不再污染后续字段。

### 字段位置速查（v2.1+ / v2.2）

终端默认显示 24 列，CSV / JSONL 34 个字段，详细结构请参考：

- 表格列定义：[默认终端显示项与导出字段的区别](#默认终端显示项与导出字段的区别)
- CSV/JSONL 字段顺序：[CSV / JSONL 导出字段说明](#csv--jsonl-导出字段说明)

### 升级建议

如果你现在在用 v2：

- **推荐**：直接切到 `reality_sni_probe_v2.2.sh`，所有 v2/v2.1 参数都兼容；
- **如果下游有脚本**：只读前 32 列的 CSV / JSONL 解析逻辑不需要改；
- **需要留意**：如果你靠绝对分数 + `--min-score` 过滤（比如 `--min-score 90`），v2.2 的分数分布继承 v2.1，会整体区别于 v2，建议先挑几个已知优质 SNI 跑一次 v2.2，看它们落在什么区间再定阈值。

### 依赖增量

v2.1 相对 v2 只新增一个**可选**依赖：

- `whois`：用于 ASN 查询；缺失时 `asn` / `asn_type` 记为 `"-" / "未知"`，ASN 相关评分为 0。

缺失也不会中断主流程，脚本退化运行。

---

## 核心能力概览

本脚本**当前真实具备**以下能力：

- 支持直接传入多个域名；
- 支持通过文件批量读入域名；
- 自动清洗输入域名，去掉协议头、路径、端口，并转为小写，见 [`normalize_domain()`](reality_sni_probe_v2.2.sh:147)；
- 启动时会尝试选择 UTF-8 locale，并在需要时重新 `exec` 自己，减少中文表头/内容在不同 shell 中的乱码问题，见 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.2.sh:28)；
- 每个域名默认进行 3 次 `curl` 采样，计算平均值与抖动；
- 检测 TCP 建连时间、TLS 握手时间、TTFB；
- 提取 HTTP 版本、状态码、内容类型、响应大小、最终 URL、HTML 标题、响应头摘要、远端 IP；
- 对 `curl` 响应体与响应头、以及 `openssl s_client` 输出都做 NUL 过滤，避免 `ignored null byte in input` 干扰，分别见 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319)、[`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384) 与 [`strip_nul_bytes()`](reality_sni_probe_v2.2.sh:120)；
- 通过 `openssl` 解析证书、到期时间、颁发者、SAN、证书链状态、OCSP Stapling、证书指纹；
- 判断 `TLS 1.3`、`X25519`、`HTTP/2` 与实际 `ALPN` 协商结果；
- 区分 SAN `精确匹配` 与 `通配匹配`，并把前者视为更优；
- 抽样检测同域名多个 IP 的一致性；
- 评估 HTTP 响应头自然度；
- 判断页面是否更像“正常网页 / 弱网页 / 非 HTML 响应 / 错误页”；
- 判断是否疑似 WAF 挑战或拦截；
- 判断跳转是否自然；
- 综合形成稳定性、结论和评分；
- 支持结果表格输出，并针对中英文混排做列宽对齐修复，见 [`table_display_width()`](reality_sni_probe_v2.2.sh:1447) 与 [`table_fit_text()`](reality_sni_probe_v2.2.sh:1466)；
- 支持 CSV / JSONL 导出；
- 支持仅保留 `推荐 / 可用`，以及按最小分数过滤；
- 会对输入域名去重，避免重复检测，见 [`dedup_domains()`](reality_sni_probe_v2.2.sh:1629)。

本脚本**没有实现**的能力包括但不限于（以 v2 为准，v2.1 的变化见 [v2.1 更新说明](#v21-更新说明)）：

- 不主动探测完整 ALPN 候选列表，只记录本次 `openssl s_client` 实际协商结果；
- 不检测 QUIC / HTTP/3；
- v2 不做 ASN 分析，**v2.2 继承 v2.1 已新增 ASN 查询与分类**，但不做地理位置 / 运营商层面的深度分析；
- 不直接验证“真实 REALITY 握手是否可用”；
- 不做深度页面渲染，只做启发式文本级判断；
- 不提供交互式 UI。

---

## 依赖环境与前置要求

### 1. 运行环境

脚本头部使用 [`#!/usr/bin/env bash`](reality_sni_probe_v2.2.sh:1)，因此需要 Bash 环境。

适合环境示例：

- Linux
- macOS
- WSL
- Git Bash / MSYS2 / Cygwin（需自行确认 `locale`、`mktemp`、`jobs`、`mapfile` 等兼容性）

### 2. 必需依赖

#### `curl`

用于 HTTP/HTTPS 采样，见 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319) 与 [`check_h2()`](reality_sni_probe_v2.2.sh:494)。

缺失时：

- 常规采样会返回占位值，无法得到有效延迟、状态码与页面信息；
- HTTP/2 检测会返回 `未知`，避免把本机能力缺失误读成目标站点明确 `不支持`；
- 页面、跳转、WAF、稳定性等结论会显著退化。

#### `openssl`

用于 TLS 握手信息与证书解析，见 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384)、[`cert_text_from_pem()`](reality_sni_probe_v2.2.sh:408)、[`get_expiry_from_pem()`](reality_sni_probe_v2.2.sh:689)。

缺失时：

- 无法获取证书 PEM；
- 证书状态、SAN、到期时间、Issuer、TLS1.3、X25519 等关键指标都会退化；
- 由于 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 会把 `cert_ok != 正常` 直接降为 `不建议`，因此结果会明显偏保守。

### 3. 可选依赖

#### `timeout`

脚本通过 [`safe_timeout()`](reality_sni_probe_v2.2.sh:107) 包装 `openssl s_client` 调用。若系统存在 `timeout`，则 TLS 抓取阶段会被超时保护；若不存在，就直接执行命令。

#### `date -d`

到期剩余天数计算由 [`days_to_expiry_from_pem()`](reality_sni_probe_v2.2.sh:696) 完成。v2.2 会优先尝试 GNU `date -d`，再尝试 BSD/macOS `date -j -f`，最后在存在 `python3` 时用 Python 兜底解析。

#### `whois`（**v2.1 新增**）

用于 ASN 查询，见 v2.1 的 `lookup_asn()`。

- 脚本通过 `whois -h whois.cymru.com " -v IP"` 查 AS 号和 AS 名字；
- 缺失时 `asn` / `asn_type` 记为 `"-" / "未知"`，ASN 相关评分项为 0；
- 大批量扫描时 `whois.cymru.com` 可能限流，可用 `--no-asn` 跳过；
- Debian / Ubuntu 通过 `apt install whois` 安装。

### 4. 网络前提

- 目标域名必须能从当前网络环境访问到 `443`；
- DNS 解析结果、地区出口、链路质量、WAF 策略都会影响结果；
- 同一域名在不同机器、不同国家/地区下，结果可能明显不同。

---

## 安装与获取方式

### 方式一：直接下载单文件

```bash
git clone https://github.com/yourname/reality_sni_probe.git
cd reality_sni_probe
chmod +x reality_sni_probe_v2.2.sh
```

如果你只是复制脚本文件，也可以：

```bash
chmod +x reality_sni_probe_v2.2.sh
```

### 方式二：保持为单文件脚本使用

本项目当前核心就是 [`reality_sni_probe_v2.2.sh`](reality_sni_probe_v2.2.sh)，无需额外安装 Python 包或 Node.js 依赖。

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

`--only-good` 对应 [`filter_results()`](reality_sni_probe_v2.2.sh:1614)，只保留 `推荐` 和 `可用`。

### 5. 按最小分数过滤

```bash
./reality_sni_probe_v2.2.sh -f domains.txt --min-score 90
```

### 6. 导出 CSV / JSONL

```bash
./reality_sni_probe_v2.2.sh -f domains.txt -o result.csv --json result.jsonl
```

### 7. v2.2 专属用法

上面的示例同样可以把脚本名换成 `reality_sni_probe_v2.2.sh`，所有 v2/v2.1 参数在 v2.2 下完全兼容。v2.1 起额外提供两个选项，v2.2 继续支持：

```bash
# 资源充足的大批量初筛可以手动提高并发并加随机抖动, 降低被云端 WAF 聚类识别的概率
./reality_sni_probe_v2.2.sh -f domains.txt -j 2 --jitter 300

# 没装 whois 或不想查 ASN 时跳过
./reality_sni_probe_v2.2.sh -f domains.txt --no-asn

# 查看新增的 ASN类型 列, 直接跑就行(默认启用)
./reality_sni_probe_v2.2.sh www.microsoft.com www.cloudflare.com
```

---

## 命令行参数说明

脚本参数定义见 [`usage()`](reality_sni_probe_v2.2.sh:124) 与 [`main()`](reality_sni_probe_v2.2.sh:1633)。

| 参数 | 含义 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `-f FILE` | 域名文件 | 无 | 从文件逐行读取域名，忽略空行与 `#` 注释行 |
| `-o FILE` | 导出 CSV | 空 | 调用 [`export_csv()`](reality_sni_probe_v2.2.sh:1578) |
| `--json FILE` | 导出 JSONL | 空 | 调用 [`export_jsonl()`](reality_sni_probe_v2.2.sh:1597) |
| `-j NUM` | 并发数 | `1` | 写入 [`JOBS`](reality_sni_probe_v2.2.sh:65)，通过 [`run_with_limit()`](reality_sni_probe_v2.2.sh:1417) 控制后台任务数；默认低并发优先保证检测质量，避免低配服务器 CPU 满载污染 TLS / TTFB / 抖动 |
| `--timeout NUM` | 单次请求超时 | `10` | 写入 [`TIMEOUT_SEC`](reality_sni_probe_v2.2.sh:66)，影响 `curl` 与 `openssl s_client` 超时 |
| `--samples NUM` | 采样次数 | `3` | 写入 [`SAMPLES`](reality_sni_probe_v2.2.sh:67)，每个域名执行多少次 `curl` 采样 |
| `--only-good` | 仅输出好结果 | `0` | 仅保留 `推荐 / 可用` |
| `--min-score N` | 最低分数筛选 | 空 | 只输出评分不低于该值的记录 |
| `--jitter NUM` | worker 启动随机延迟上限毫秒 | `0` | **v2.1+ / v2.2**。启用后每个 worker 启动前会随机 sleep `0–NUM` 毫秒，降低云端 WAF 聚类识别概率 |
| `--no-asn` | 禁用 ASN 查询 | 关闭（即默认启用 ASN） | **v2.1+ / v2.2**。批量扫描时 `whois.cymru.com` 可能限流，或系统未装 `whois` 时使用 |
| `-h`, `--help` | 帮助 | 无 | 显示帮助并退出 |

### 参数校验规则

脚本会在 [`main()`](reality_sni_probe_v2.2.sh:1633) 中做基础校验：

- `-j` 必须是正整数；
- `--timeout` 必须是正整数；
- `--samples` 必须是正整数；
- `--min-score` 必须是数值；
- **v2.1+ / v2.2**：`--jitter` 必须是非负整数（毫秒）；
- 未提供任何有效域名会直接报错退出；
- 读取完成后还会做一次去重与空值过滤。

---

## UTF-8 / locale 兼容处理

这是近几轮修改里比较重要但容易被忽略的一点。

脚本在正式执行前，会先调用 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.2.sh:28)：

1. 通过 [`select_utf8_locale()`](reality_sni_probe_v2.2.sh:4) 优先从当前 `LC_CTYPE`、`LANG` 中挑选 UTF-8 locale；
2. 若当前环境不合适，再按 `C.UTF-8`、`en_US.UTF-8`、`UTF-8` 依次尝试；
3. 如果发现 `LC_ALL` 已设置，或 `LANG` / `LC_CTYPE` 不符合目标 locale，并且尚未完成 bootstrap，则重新 `exec` 脚本；
4. 重新启动时会显式 `unset LC_ALL`，并导出新的 `LANG`、`LC_CTYPE`；
5. 并发 worker 进程也会继承同样的 UTF-8 相关环境，见 [`main()`](reality_sni_probe_v2.2.sh:1633) 附近的 worker 启动逻辑。

这一处理的目标不是改变检测逻辑，而是尽量让：

- 中文表头和中文结果值更稳定地显示；
- [`table_display_width()`](reality_sni_probe_v2.2.sh:1447) / [`table_fit_text()`](reality_sni_probe_v2.2.sh:1466) 的宽度计算更不容易被错误 locale 干扰；
- 某些 shell 环境下的乱码或列错位概率降低。

需要注意：如果宿主系统本身没有可用 UTF-8 locale，脚本仍会回退到 `C.UTF-8` 字符串尝试运行，但实际显示效果仍取决于系统环境。

---

## 检测流程总览

单域名主流程由 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 驱动，可概括为：

1. **重复采样**：调用 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319) 进行 `SAMPLES` 次 HTTPS 请求；
2. **提取样本指标**：收集 TCP 建连、TLS 握手、TTFB、HTTP 版本、状态码、内容类型、响应体大小、最终 URL、页面标题、响应头摘要、远端 IP；
3. **统计多次样本**：计算平均值与抖动；
4. **统计成功样本数**：状态码为 `200/301/302/403` 时视作 `ok sample`；
5. **选择首个有效样本**：并不是挑最快样本，而是取第一个拿到三位状态码的样本作为页面 / WAF / 跳转 / 头部分析基准；
6. **抓取 TLS 证书材料**：通过 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384) 运行带 `-status` 与 `-alpn 'h2,http/1.1'` 的 `openssl s_client`；
7. **证书分析**：解析证书文本、`TLS1.3`、`X25519`、实际 `ALPN`、证书可用性、证书链状态、SAN、OCSP Stapling、证书指纹、到期时间、颁发者；
8. **HTTP/2 检测**：若首个有效样本已是 HTTP/2，则直接记为支持；若 `openssl s_client` 的 ALPN 已协商到 `h2`，也会优先兜底记为支持；否则在已有 HTTP 状态码时走 [`check_h2()`](reality_sni_probe_v2.2.sh:494) 再测一次，无法确认时保守记为 `未知`；
9. **启发式页面判断**：根据状态码、标题、内容类型、大小判断页面类型；
10. **启发式响应头判断**：调用 [`check_header_naturalness()`](reality_sni_probe_v2.2.sh:587) 评估头部自然度；
11. **启发式 WAF 判断**：根据状态码与关键字推断是否疑似挑战/拦截；
12. **跳转自然度判断**：分析最终 URL 是否同域、主子域、跨站；
13. **多 IP 一致性抽样**：调用 [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632) 对最多 3 个 A 记录做一致性复核；
14. **稳定性判断**：根据成功样本数与 TLS/TTFB 抖动判断 `稳定 / 一般 / 波动大`；
15. **结论判定**：调用 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 产生 `推荐 / 可用 / 勉强 / 不建议`；
16. **评分**：调用 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 叠加三层权重分；
17. **过滤、排序、展示/导出**：由 [`filter_results()`](reality_sni_probe_v2.2.sh:1614)、[`print_table()`](reality_sni_probe_v2.2.sh:1539)、[`export_csv()`](reality_sni_probe_v2.2.sh:1578)、[`export_jsonl()`](reality_sni_probe_v2.2.sh:1597) 完成。

---

## 脚本实际执行的检测项

这一节强调的是：**脚本真实做了哪些探测动作**，而不是默认表格显示了哪些列。

### 1. `curl` 常规 HTTPS 采样

见 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319)。脚本实际执行的命令形态为：

```bash
curl -L -D HEADER_FILE -o BODY_FILE -s \
  -w '%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{http_version}\t%{response_code}\t%{content_type}\t%{size_download}\t%{url_effective}\t%{remote_ip}' \
  --connect-timeout 4 --max-time TIMEOUT \
  "https://DOMAIN"
```

它实际检测/提取的内容包括：

- `time_connect`：TCP 建连耗时；
- `time_appconnect`：SSL/TLS 完成耗时；
- `time_starttransfer`：TTFB；
- `http_version`：HTTP 版本；
- `response_code`：状态码；
- `content_type`：响应内容类型；
- `size_download`：下载大小；
- `url_effective`：最终 URL；
- `remote_ip`：本次样本命中的远端 IP；
- HTML `<title>`：从响应体中额外提取；
- 原始响应头：单独写入临时文件后再读取、清洗与压缩。

随后脚本转换出：

- `TCP建连`；
- `TLS握手` = `time_appconnect - time_connect`；
- `TTFB`；
- 标题、内容类型、大小、最终跳转地址；
- 压缩后的响应头摘要；
- 远端 IP。

### 2. `curl --http2` HTTP/2 检测

见 [`check_h2()`](reality_sni_probe_v2.2.sh:494)。脚本按两步尝试：

#### 第一次：HEAD 请求

```bash
curl -I -L -o /dev/null -s --http2 \
  -w "%{http_version}|%{response_code}" \
  --connect-timeout 5 --max-time TIMEOUT \
  "https://DOMAIN"
```

#### 第二次：普通请求回退

```bash
curl -L -o /dev/null -s --http2 \
  -w "%{http_version}|%{response_code}" \
  --connect-timeout 5 --max-time TIMEOUT \
  "https://DOMAIN"
```

只要最终版本号是 `2/2.0` 且状态码为任意三位 HTTP 码，就判为 `支持`。如果缺少 `curl` 或当前 `curl` 未编译 HTTP/2 能力，[`check_h2()`](reality_sni_probe_v2.2.sh:494) 会直接返回 `未知`；但在主流程里，如果 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.2.sh:418) 已确认 ALPN=`h2`，仍会把 `H2` 兜底记为 `支持`。

### 3. `openssl s_client` TLS 抓取

见 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384)。命令形态为：

```bash
openssl s_client -connect DOMAIN:443 -servername DOMAIN -showcerts -status -alpn 'h2,http/1.1' < /dev/null
```

若系统存在 `timeout`，则外层会变成：

```bash
timeout TIMEOUT openssl s_client -connect DOMAIN:443 -servername DOMAIN -showcerts -status -alpn 'h2,http/1.1' < /dev/null
```

这一阶段实际作用：

- 获取 `s_client` 全量输出；
- 从输出中截取第一张证书 PEM；
- 为后续 `TLS1.3` / `X25519` / `ALPN` / 证书链 / `OCSP` 解析提供原材料；
- 通过 [`strip_nul_bytes()`](reality_sni_probe_v2.2.sh:120) 过滤 NUL 字节，减少 shell 变量告警。

### 4. `openssl x509` 证书解析

脚本内部会对 PEM 做多次解析：

#### 解析完整证书文本

见 [`cert_text_from_pem()`](reality_sni_probe_v2.2.sh:408)：

```bash
openssl x509 -text -noout
```

#### 读取证书到期时间

见 [`get_expiry_from_pem()`](reality_sni_probe_v2.2.sh:689) 与 [`days_to_expiry_from_pem()`](reality_sni_probe_v2.2.sh:696)：

```bash
openssl x509 -noout -enddate
```

#### 读取颁发者

见 [`get_issuer_short_from_pem()`](reality_sni_probe_v2.2.sh:709)：

```bash
openssl x509 -noout -issuer
```

### 5. SAN 覆盖级别判断

见 [`check_san_level()`](reality_sni_probe_v2.2.sh:716)。它不是外部命令，而是基于 `openssl x509 -text -noout` 的结果，读取 `X509v3 Subject Alternative Name` 进行判断：

- `精确匹配`：SAN 中有与输入域名完全相同的 `DNS:` 项；
- `通配匹配`：存在如 `*.example.com`，且目标域名满足**单层子域**匹配；
- `无SAN`：找不到 SAN 行；
- `不匹配`：存在 SAN 但不覆盖目标域名；
- `失败`：证书文本为空，无法判断。

当前脚本中的含义需要特别注意：

- `精确匹配` 是最优等级；
- `通配匹配` 仍被视为**可接受但次优**，不会因仅为通配而被硬性淘汰；
- `不匹配 / 无SAN / 失败` 仍会被判为不合格，并触发结论降级或硬淘汰。

### 6. TLS1.3 判断

见 [`check_tls13_from_sclient()`](reality_sni_probe_v2.2.sh:484)。脚本通过匹配 `openssl s_client` 输出中的以下模式做判断：

- `Protocol : TLSv1.3`
- `New, TLSv1.3`

匹配到即记为 `支持`，否则为 `不支持`。

### 7. X25519 判断

见 [`check_x25519_from_sclient()`](reality_sni_probe_v2.2.sh:489)。脚本匹配以下关键词：

- `Server Temp Key: X25519`
- `group: X25519`
- 任意 `X25519`

匹配到即记为 `支持`，否则为 `不支持`。

### 8. 页面类型判断

见 [`page_naturalness()`](reality_sni_probe_v2.2.sh:817)。这部分不是协议级硬校验，而是**启发式分析**：

- `200/301/302` 且内容类型像 HTML、大小至少 `512`、并且标题存在：`像正常网站`；
- `200/301/302` 且 HTML 但特征弱：`HTML但特征弱`；
- `200/301/302` 但不是 HTML：`非HTML响应`；
- `403/404/405`：`错误页`；
- 其他：`未知`。

### 9. WAF / 挑战页判断

见 [`detect_waf_challenge()`](reality_sni_probe_v2.2.sh:799)。同样属于**启发式分析**，不是严格 WAF 指纹引擎。

脚本会把以下内容拼在一起后转小写再搜索关键字：

- 状态码
- `content_type`
- `title`
- `final_url`

若命中 `captcha`、`challenge`、`attention required`、`cf-chl`、`cloudflare`、`akamai`、`perimeterx`、`deny`、`forbidden` 等关键词，则记为 `疑似挑战`。

否则：

- 状态码是 `403` 或 `429`：记为 `疑似拦截`；
- 其他情况：记为 `正常`。

### 10. 跳转自然度判断

见 [`redirect_naturalness()`](reality_sni_probe_v2.2.sh:771)：

- 最终 host 与输入域名一致：`无跳转/同域`；
- 主域与 `www.` 等主子域互跳：`主子域自然跳转`；
- 跳到明显无关域名：`跨站跳转`；
- 无法提取：`未知`。

### 11. 稳定性判断

见 [`stability_level()`](reality_sni_probe_v2.2.sh:846)。输入包括：

- `ok_count`：成功样本数；
- `samples`：总采样数；
- `tls_var`：TLS 抖动；
- `ttfb_var`：TTFB 抖动。

规则为：

- 成功样本达到全部样本，且 `tls_var <= 40`，且 `ttfb_var <= 200`：`稳定`；
- 否则只要成功样本达到半数以上：`一般`；
- 其他：`波动大`。

### 12. 实际 ALPN 协商结果

见 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.2.sh:418)。脚本从 `openssl s_client` 输出中提取本次实际协商结果，可能值为：

- `h2`
- `http/1.1`
- `其他`
- `未知`

需要注意：

- 这不是“服务端支持列表”，而是**本次握手实际协商到的协议**；
- `H2` 与 `ALPN` 不是同一字段：`H2` 代表脚本对 HTTP/2 可用性的综合判断，`ALPN` 代表 TLS 握手里实际协商结果。

### 13. 证书链完整性

见 [`check_cert_chain_status()`](reality_sni_probe_v2.2.sh:443)。脚本根据 `openssl s_client` 输出中的验证结果，把证书链状态分为：

- `完整`：出现 `Verify return code: 0 (ok)`；
- `不完整`：出现本地发行者缺失、自签、verify error 等明显异常；
- `未知/失败`：握手失败、无证书、超时等无法可靠判断。

这项**不是当前结论的硬性条件**，但会参与评分。

### 14. OCSP Stapling

见 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.2.sh:468)。脚本通过 `openssl s_client -status` 检查 OCSP Stapling，可能值为：

- `支持`
- `未提供`
- `异常`
- `未知`

当前行为是：

- 只作为轻量评分项，不会单独触发 `不建议`；
- `支持` 小幅加分，`未提供` 不扣分，`异常` 小幅减分。

### 15. HTTP 响应头自然度

见 [`check_header_naturalness()`](reality_sni_probe_v2.2.sh:587)。脚本会把状态码、内容类型和响应头拼接后做启发式评分：

- 常见的 `server:`、`content-type:`、`cache-control:`、`strict-transport-security:`、`content-encoding:`、`alt-svc:` 等头部会加分；
- 命中 `cf-ray`、`challenge`、`captcha` 等明显挑战 / 代理痕迹会减分；
- 最终归类为 `自然 / 一般 / 异常`。

### 16. 多 IP 一致性抽样

见 [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632)。脚本会解析最多 3 个 IPv4 A 记录，并逐个复核：

- `TLS1.3`
- `X25519`
- `H2`
- `SAN 等级`
- 首张证书 SHA-256 指纹

输出值为：

- `一致`
- `部分不一致`
- `单IP/未知`

这项不是硬性门槛，但会参与评分，适合识别 CDN / 多节点行为不一致的问题。

---

## 默认终端显示项与导出字段的区别

这是当前实现里非常重要的一点。

### 1. 默认终端表格显示项

终端表格列定义见 [`TABLE_HEADERS`](reality_sni_probe_v2.2.sh:1438)。

**当前 v2.2 默认显示 24 列**：

- 域名
- 码
- TCP建连
- TLS握手
- TTFB
- 平均延迟
- 抖动T/TLS/F
- TLS13
- X25519
- H2
- ALPN
- SAN
- 证书
- 跳转
- WAF
- 页面
- 稳定性
- ASN类型
- 多IP
- 链
- 头部
- OCSP
- 评分
- 结论

其中 `码 / TCP建连 / TLS握手 / TTFB / 平均延迟 / 抖动T/TLS/F / TLS13 / X25519 / H2 / ALPN` 的顺序保持原样；后面的站点判断列按当前权重与 REALITY 安全优先级从高到低排列。

#### 默认终端后半段列权重阅读规则

当两个候选的 `结论` 和 `评分` 接近时，可以从 `SAN` 开始按列从左到右筛选：

`SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`

| 终端列 | 阅读优先级 | 当前规则 / 权重含义 |
| --- | --- | --- |
| `SAN` | 最高 | REALITY 身份匹配主项；`不匹配 / 无SAN / 失败` 直接 `不建议`，评分中 `精确匹配 +32`、`通配匹配 +12`、`不匹配 -42`、`无SAN -18`、`失败 -32`。 |
| `证书` | 最高 | 证书获取失败直接 `不建议`；评分中 `正常 +20`，其他 `-24`。 |
| `跳转` | 最高 | `跨站跳转` 直接 `不建议`；评分中 `无跳转/同域 +7`、`主子域自然跳转 +4`、`跨站跳转 -20`。 |
| `WAF` | 高 | `疑似挑战` 直接降为 `勉强`；评分中 `正常 +5`、`疑似拦截 -12`、`疑似挑战 -28`。 |
| `页面` | 高 | 正常网页形态更自然；评分中 `像正常网站 +12`、`HTML但特征弱 +6`、`非HTML响应 -6`、`错误页 -18`。 |
| `稳定性` | 高 | 影响 `推荐` 门槛和评分；评分中 `稳定 +7`、`一般 +1`、`波动大 -10`。 |
| `ASN类型` | 中高 | 反映“大树 / 孤树”背景；评分中 `CDN +8`、`Hosting +1`、`ISP 0`、`Edu -8`、`未知 0`。 |
| `多IP` | 中 | 多 IP 一致更像正常大站；评分中 `一致 +5`、`部分不一致 -8`、`单IP/未知 0`。 |
| `链` | 中 | 证书链完整是健康信号；评分中 `完整 +5`、`不完整 -6`、`未知/失败 -2`。 |
| `头部` | 低 | 响应头自然度属于辅助站点卫生信号；评分中 `自然 +4`、`一般 +1`、`异常 -8`。 |
| `OCSP` | 最低 | v2.2 已降为轻量信号；评分中 `支持 +2`、`未提供 0`、`异常 -3`、`未知 0`。 |

实用理解：

- 分数接近时，优先选择左侧关键列更好的候选，而不是只看 `OCSP` 这种轻量信号。
- `ASN类型=CDN`、`多IP=一致` 这类背景项通常比 `OCSP=支持` 更重要，因为 REALITY 更看重“大树底下好乘凉”的伪装背景。
- 如果某个候选在前面的 `SAN / 证书 / 跳转 / WAF` 已经明显更差，即使后面的 `头部 / OCSP` 更好，也不应优先。
- 这套列顺序只是默认终端阅读顺序；CSV / JSONL 导出字段顺序不随终端表格重排而改变，仍按 [CSV / JSONL 导出字段说明](#csv--jsonl-导出字段说明) 输出。

### 2. 脚本实际还计算了但默认终端不会单独成列、或仅在导出中更完整可见的字段

在 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 输出的完整 TSV 中，脚本实际还包含，或以更底层形式保留：

- `tcp_var`
- `tls_var`
- `ttfb_var`
- `page`（导出保留原始页面分类值，终端表格会映射成更紧凑的页面列标签）
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

**v2.1 额外新增的字段**（只在 CSV / JSONL 中显示，终端表格把 `asn_type` 摘要到 `ASN类型` 列）：

- `asn`（ASN 编号，形如 `AS13335`，仅 CSV/JSONL）
- 完整 `asn_type` 值（终端 `ASN类型` 列是这个字段的显示）

这些字段：

- **仍然参与检测或判定**，例如 `title`、`content_type`、`size` 用于页面判断，`final_url` 用于跳转判断；
- **仍然存在于 CSV / JSONL 导出**，见 [`export_csv()`](reality_sni_probe_v2.2.sh:1578) 和 [`export_jsonl()`](reality_sni_probe_v2.2.sh:1597)；
- **不会出现在默认终端表格中**，默认终端只显示紧凑摘要列。

### 3. 默认终端里“已隐藏”与“摘要显示”的真实含义

当前终端表格中：

- **分项抖动数值不会单独成列**：`tcp_var`、`tls_var`、`ttfb_var` 会压缩进 `抖动T/TLS/F`；
- **页面列会做标签映射**：终端 `页面` 列不是直接输出原始 `page` 字段，而是由 [`print_table()`](reality_sni_probe_v2.2.sh:1539) 按当前规则映射为 `网页站 / 弱网页 / 接口/下载 / 错误页 / -`；
- **站点复核字段默认不进终端表格**：`issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip` 仅在导出中可见；
- **核心判定字段当前都会直接显示**：`TLS13`、`X25519`、`H2`、`ALPN`、`SAN`、`证书`、`跳转`、`WAF`、`页面`、`稳定性`、`ASN类型`、`多IP`、`链`、`头部`、`OCSP`、`评分`、`结论` 都会直接显示；其中 `SAN` 到 `OCSP` 这组列按权重从高到低排列。

### 4. `平均延迟` 的实际含义

这里要特别说明：在当前实现中，`平均延迟` 实际上直接等于 `avg_ttfb`，见 [`probe_one()`](reality_sni_probe_v2.2.sh:1248)。

也就是说：

- 它并不是 `TCP + TLS + TTFB` 的总和；
- 也不是独立新指标；
- 当前只是把 `avg_ttfb` 再以 `avg_latency` 名义输出一份。

因此阅读结果时，应把“平均延迟”理解为**平均首包时间**。

---

## 输出结果中每一项参数的详细解释

以下既包括默认表格列，也包括实际导出字段。

### `domain`

输入域名，经 [`normalize_domain()`](reality_sni_probe_v2.2.sh:147) 规整后的最终检测目标。

### `code`

首个有效样本的 HTTP 状态码。所谓“有效样本”，并不是严格选最快，而是 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 中**第一个能拿到三位状态码的样本**。

这意味着：

- 页面 / WAF / 跳转判断主要基于这个“首个有效样本”；
- 多次采样的平均延迟与“首个有效样本页面形态”并非完全同一请求。

### `avg_tcp`

多次采样中 `TCP 建连` 的平均值，来源于 `curl` 的 `time_connect`。

### `avg_tls`

多次采样中 `TLS 握手` 的平均值，脚本按 `time_appconnect - time_connect` 计算。

### `avg_ttfb`

多次采样中 `TTFB` 平均值，来源于 `time_starttransfer`。

### `avg_latency`

当前实现中等同于 `avg_ttfb`，只是换了字段名输出，见 [`probe_one()`](reality_sni_probe_v2.2.sh:1248)。

### `jitter`

完整抖动描述串，形如：

```txt
TCP:20ms/TLS:35ms/TTFB:120ms
```

如果三项抖动都不可得，则为 `-`。

需要补充说明两点：

- 当只拿到部分抖动值时，脚本仍会输出完整模板；未取到的项在 v2.2 会显示为 `-`，例如 `TCP:-/TLS:18ms/TTFB:65ms`；
- 默认终端表格不会原样显示这个字段，而是把 `999999` 视为“该项不可得”，在 `抖动T/TLS/F` 列中转写为 `-`。

### `tcp_jitter` / `tcp_var`

TCP 建连抖动，即多次采样中 `max_tcp - min_tcp`。

在导出时该字段会被格式化为字符串并追加 `ms`；若底层值为 `999999`，v2.2 会导出为 `-`，表示这一项抖动不可得。

### `tls_jitter` / `tls_var`

TLS 握手抖动，即多次采样中 `max_tls - min_tls`。

在导出时该字段会被格式化为字符串并追加 `ms`；若底层值为 `999999`，v2.2 会导出为 `-`，表示这一项抖动不可得。

### `ttfb_jitter` / `ttfb_var`

TTFB 抖动，即多次采样中 `max_ttfb - min_ttfb`。

在导出时该字段会被格式化为字符串并追加 `ms`；若底层值为 `999999`，v2.2 会导出为 `-`，表示这一项抖动不可得。

### `tls13`

由 [`check_tls13_from_sclient()`](reality_sni_probe_v2.2.sh:484) 判断，表示 `openssl s_client` 输出是否体现 `TLSv1.3`。

### `x25519`

由 [`check_x25519_from_sclient()`](reality_sni_probe_v2.2.sh:489) 判断，表示握手输出中是否出现 `X25519`。

### `h2`

HTTP/2 支持状态。可能来自：

- 首个有效样本本身已经显示 HTTP/2；
- [`openssl s_client` 的 ALPN 结果](reality_sni_probe_v2.2.sh:418) 已经协商到 `h2`，主流程用它兜底确认；
- 或 [`check_h2()`](reality_sni_probe_v2.2.sh:494) 二次验证得到。

如果本机缺少 `curl` 或 `curl` 不支持 HTTP/2，`check_h2()` 返回 `未知`；这表示“当前环境无法确认”，不是目标站点已经明确不支持 HTTP/2。

### `alpn_result`

实际 ALPN 协商结果，来自 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.2.sh:418)。可能值为 `h2 / http/1.1 / 其他 / 未知`。

### `cert_ok`

证书是否成功获取。当前逻辑非常直接，见 [`check_cert_ok()`](reality_sni_probe_v2.2.sh:413)：

- 只要 PEM 非空，即 `正常`；
- 否则为 `失败`。

它不等于“证书链完整验证通过”，只是“有没有拿到证书”。

### `cert_chain_status`

证书链完整性状态，来自 [`check_cert_chain_status()`](reality_sni_probe_v2.2.sh:443)。可能值为：

- `完整`
- `不完整`
- `未知/失败`

### `san_level`

证书 SAN 覆盖等级，取值可能为：

- `精确匹配`
- `通配匹配`
- `无SAN`
- `不匹配`
- `失败`

这是 REALITY SNI 可用性里非常关键的一项。

其中需要注意：

- `精确匹配` 是当前最佳等级；
- `通配匹配` 仍可能得到 `可用` 或 `勉强`，但在排序与评分上会明显低于 `精确匹配`；
- `无SAN / 不匹配 / 失败` 都属于不合格状态。

### `ocsp_stapling`

OCSP Stapling 状态，来自 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.2.sh:468)。可能值为：

- `支持`
- `未提供`
- `异常`
- `未知`

### `page`

页面自然度判断，取值可能为：

- `像正常网站`
- `HTML但特征弱`
- `非HTML响应`
- `错误页`
- `未知`

注意：这是**启发式**页面分类，不是完整浏览器渲染结果。

### `waf`

WAF/挑战页启发式结果，取值可能为：

- `正常`
- `疑似拦截`
- `疑似挑战`

注意：这同样是**启发式**判断。

### `redirect`

跳转自然度，取值可能为：

- `无跳转/同域`
- `主子域自然跳转`
- `跨站跳转`
- `未知`

### `header_naturalness`

HTTP 响应头自然度，来自 [`check_header_naturalness()`](reality_sni_probe_v2.2.sh:587)，可能值为：

- `自然`
- `一般`
- `异常`

### `ip_consistency`

多 IP 一致性状态，来自 [`sample_ip_consistency()`](reality_sni_probe_v2.2.sh:632)，可能值为：

- `一致`
- `部分不一致`
- `单IP/未知`

### `remote_ip`

首个有效样本对应的远端 IP，来自 `curl` 的 `%{remote_ip}`。它不直接参与结论和评分，但有助于人工复核实际命中的边缘节点。

### `stability`

多样本稳定性，取值可能为：

- `稳定`
- `一般`
- `波动大`

### `score`

综合评分，来自 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010)。由于当前权重设计明显偏向安全性，因此 `score` 更适合用于**同一批候选中的相对排序**，而不是脱离上下文做绝对质量承诺。

### `result`

最终结论，来自 [`judge_sni()`](reality_sni_probe_v2.2.sh:922)：

- `推荐`
- `可用`
- `勉强`
- `不建议`

### `issuer`

证书颁发者，来自 [`get_issuer_short_from_pem()`](reality_sni_probe_v2.2.sh:709)，并经 [`shorten()`](reality_sni_probe_v2.2.sh:157) 截断为最多 60 个字符左右。

### `final_url`

经过 `curl -L` 跟随后得到的最终 URL，用于跳转分析，也便于复查站点实际落点。

### `title`

HTML 标题，来自 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319) 对响应体中 `<title>` 的提取。

### `content_type`

响应内容类型，来自 `curl` 的 `%{content_type}`。

### `size`

响应下载大小，来自 `curl` 的 `%{size_download}`。

### `expiry_days`

证书剩余天数。当前**不会直接显示在默认终端或导出字段中**，只参与 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 的临期硬保护：当证书剩余天数 `< 14` 天时直接判为 `不建议`。它不再参与 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 的评分加减分。

---

## 每项参数的重要性

从 REALITY SNI 候选筛选角度，可以把这些字段的重要性分为三层。

### 第一层：安全性 / 身份匹配主层

这些字段决定是否具备成为可靠候选的基本前提，也是当前评分体系中的**主权重层**：

- `result`
- `cert_ok`
- `cert_chain_status`
- `san_level`
- `ocsp_stapling`
- `expiry_days`（未直接显示；只参与 `< 14` 天临期硬保护，不参与评分）
- `tls13`
- `x25519`
- `alpn_result`

原因：

- 证书拿不到，或者 SAN 不覆盖目标域名，脚本会直接判为 `不建议`；
- 证书剩余有效期 `< 14` 天时直接 `不建议`；除此之外，剩余天数不再影响评分排序；
- 没有 `TLS1.3`、`X25519`、`H2` 或发生跨站跳转，脚本会直接判为 `不建议`；
- 当前 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 的最大加分也主要集中在这一层。

### 第二层：站点自然性与可用性次层

这些字段反映“像不像一个自然、稳定、正常站点”，属于当前评分体系的**次权重层**：

- `code`
- `page`
- `header_naturalness`
- `redirect`
- `waf`
- `h2`
- `ip_consistency`

其中：

- [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 要求 `推荐` 必须同时满足正常状态码、非错误页、非跨站跳转、支持 `H2`；
- [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 也会对这些项做中等幅度加减分；
- 这层不会像证书/SAN 那样一票否决全部，但会明显影响排序和是否冲到高档。

### 第三层：性能与稳定性补充层

这些字段用于把“都还不错”的候选继续拉开差距，属于当前评分体系的**补充细化层**：

- `stability`
- `avg_tcp`
- `avg_tls`
- `avg_ttfb`
- `tcp_var`
- `tls_var`
- `ttfb_var`
- `jitter`

例如：

- 稳定性会直接影响 `推荐` 与高分；
- `avg_tls`、`avg_ttfb` 还参与 `推荐` 门槛；
- 三项平均值和三项抖动会先进入 [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881) 的软 / 硬门槛：超过软阈值直接降为 `勉强`，超过硬阈值直接判为 `不建议`；
- 通过门槛后，这些数值仍会在 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 中分档加减分，用于拉开细粒度差距。

### 第四层：人工复核辅助层

这些字段不直接单独决定结论，但有助于人工解释或复核：

- `issuer`
- `final_url`
- `title`
- `content_type`
- `size`

例如：

- `issuer` 可以帮助判断证书来源是否常见；
- `final_url` 可揭示跨站跳转；
- `title` 与 `content_type` 可帮助理解页面形态；
- `size` 与 `title` 共同决定页面是否“像正常网站”。

---

## 结论判定逻辑

最终结论完全由 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 给出。下面按实际代码逻辑说明。

### 1. 硬门槛：直接判为 `不建议`

满足任一条件，立即返回 `不建议`：

#### 证书获取失败或 SAN 不合格

```bash
cert_ok != 正常
或 san_level == 不匹配
或 san_level == 无SAN
或 san_level == 失败
```

#### Reality 核心能力不满足

```bash
redirect == 跨站跳转
或 tls13 != 支持
或 x25519 != 支持
或 h2 != 支持
```

#### 证书剩余天数小于 14 天

```bash
expiry_days < 14
```

#### 数值项超过硬阈值

| 字段 | 硬阈值 | 触发后结论 |
| --- | --- | --- |
| `avg_tcp` / `TCP建连` | `> 280ms` | `不建议` |
| `avg_tls` / `TLS握手` | `> 650ms` | `不建议` |
| `avg_ttfb` / `TTFB` / `平均延迟` | `> 1200ms` | `不建议` |
| `tcp_var` / TCP 抖动 | `> 120ms` | `不建议` |
| `tls_var` / TLS 抖动 | `> 130ms` | `不建议` |
| `ttfb_var` / TTFB 抖动 | `> 650ms` | `不建议` |

这里要注意：`redirect / TLS13 / X25519 / H2 / SAN` 这组 Reality 核心硬条件由 [`is_reality_hard_fail()`](reality_sni_probe_v2.2.sh:861) 统一判断；`expiry_days < 14` 在 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 中单独判断；数值项硬阈值由 [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881) 统一判断，并会让 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 输出 `-9999`。

### 2. 直接降级为 `勉强`

#### 命中疑似挑战页

```bash
waf == 疑似挑战
```

#### 数值项超过软阈值

| 字段 | 软阈值 | 触发后结论 |
| --- | --- | --- |
| `avg_tcp` / `TCP建连` | `> 200ms` | `勉强` |
| `avg_tls` / `TLS握手` | `> 300ms` | `勉强` |
| `avg_ttfb` / `TTFB` / `平均延迟` | `> 900ms` | `勉强` |
| `tcp_var` / TCP 抖动 | `> 80ms` | `勉强` |
| `tls_var` / TLS 抖动 | `> 90ms` | `勉强` |
| `ttfb_var` / TTFB 抖动 | `> 450ms` | `勉强` |

以上任一满足，就直接返回 `勉强`。

### 3. `通配匹配` 的单独分支

当 `san_level == 通配匹配` 时，脚本不会直接淘汰，而是进入单独分支：

- 若同时满足 `200/301/302`、非错误页、非 `波动大`、`avg_tls <= 120ms`、`avg_ttfb <= 800ms`，则判为 `可用`；
- 否则只要状态码属于 `200/301/302/403`，则判为 `勉强`。

这意味着：**通配匹配当前是“次优可用”，而不是硬淘汰**。

### 4. 满足高标准则判为 `推荐`

必须同时满足以下条件：

```bash
code ∈ {200,301,302}
page != 错误页
redirect != 跨站跳转
h2 == 支持
stability != 波动大
avg_tls <= 120ms
avg_ttfb <= 800ms
```

注意这里使用的是**平均 TLS / 平均 TTFB**，而不是单次最佳值。

### 5. 其余常见可接受情况判为 `可用`

如果未提前命中上面的 `不建议` / `勉强` / `推荐` 分支，但状态码属于：

```bash
200 / 301 / 302 / 403
```

则返回 `可用`。

### 6. 其他情况回落为 `勉强`

剩余未命中的情况，统一返回 `勉强`。

---

## 评分机制与权重细节

当前评分由 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 计算，已经不是早期“偏性能主导”的思路，而是明确调整为：

1. **第一层：安全性主权重**；
2. **第二层：站点自然性次权重**；
3. **第三层：性能 / 稳定性补充细化**。

也就是说：一个站点即使速度很好，如果证书、SAN、TLS1.3、X25519 这些基础条件不好，也拿不到高分；相反，先满足身份与协议安全特征，后续页面自然性、可用性和性能才会继续拉开差距。

### 后续权重校准原则：REALITY 最大安全优先

本脚本的最高设计目标是 **REALITY 最大安全**，不是单纯寻找最低延迟域名。后续任何权重调整都应坚持以下层级：

1. **一票否决层**：证书失败、SAN 不匹配 / 无 SAN、`TLS1.3` 不支持、`X25519` 不支持、`H2` 不支持、跨站跳转、证书剩余天数 `< 14` 天，以及任一数值项超过硬阈值。这些会破坏 REALITY 握手伪装一致性或暴露明显异常，应优先判为 `不建议`。
2. **强安全排序层**：ASN 类型、多 IP 一致性、证书链完整、`ALPN=h2`、页面自然度、WAF 正常、稳定性。这些指标决定候选是否像真实大站、是否处在“大树”背景里、是否难以被单独封禁，应优先于单纯速度。
3. **弱安全 / 站点卫生层**：`OCSP`、响应头自然度、状态码细节等。这些能辅助判断站点是否健康自然，但不应单独强到压过核心安全背景。
4. **性能门槛 + 细分层**：`TCP`、`TLS`、`TTFB` 均值与抖动先走软 / 硬阈值。超过硬阈值直接 `不建议`，超过软阈值直接 `勉强`；只有通过门槛后，才继续用评分分档拉开差距。

因此，当前排序原则宁可选择**小幅慢一些**但 CDN 背景明确、多 IP 一致、证书链完整、页面自然、抖动稳定的候选，也不要优先选择均值略低但 ASN 未知、抖动异常或站点特征不自然的候选；但如果任一数值项超过软 / 硬阈值，就不再只是扣分问题，而会直接影响 `结论` 档位。

> **v2 与 v2.2 的分数差异**
>
> v2.1 在 v2 的基础上**重新校准了第二、三层权重**，核心原则是：
>
> **SNI 选择的最高目标是安全性。任何偏离"正常大厂健康站点"典型值的指标，本身就是风险信号——因此偏离越大，扣分应该越陡，不能线性降低。**
>
> 具体改动：
>
> - **第三层性能分档**（`avg_tls / avg_ttfb / avg_tcp` 和三个抖动）：**正常范围内加分基本不变**，但异常范围扣分从"线性"改为"指数"式陡降。例如 v2.1 先把 `avg_ttfb >1600ms` 从 `-6` 加重到 `-35`，当前 v2.2 又进一步把 `900ms+` 区间整体加重，`>1600ms` 为 `-50`；同时，软 / 硬数值阈值会先于普通评分触发 `勉强` 或 `不建议`。
> - **第三层抖动项的加分**大幅压缩（例如 `ttfb_var<=20ms` 从 `+6` 改为 `+2`）——因为抖动"很小"不一定代表站点稳定，更可能是采样命中了缓存，不值得为此重加分。
> - **第二层异常扣分加重**：`waf=疑似挑战` 从 `-14` 改为 `-28`、`redirect=跨站跳转` 从 `-10` 改为 `-20`、`page=错误页` 从 `-9` 改为 `-18` 等。
> - **`asn_type=Edu` 从 `-4` 改为 `-8`**，加重孤树惩罚。
> - v2.1 还在第二层新增 [`asn_type` 一档](#7-asn_typev21--v22)，这是唯一**新增**的评分维度。
> - **v2 实现里的链式 `&& ||` bug 也一并修掉**：v2 的第三层分档因为 bash 运算符特性会错误累加，导致好候选分数虚高。v2.1 用 `if/elif/else` 严格按表打分。
>
> 综合影响：
>
> - **排序逻辑变好**：TTFB 高达 1500+ms 的站点再也不会和 500ms 的站点同分；当前 v2.2 还避免 `900ms+` 的候选仅靠 `CDN` / 多 IP 背景加分压过 500–700ms 的候选，并把超过数值硬阈值的候选直接排到 `不建议 / -9999`；
> - **分数分布整体变化**：好站点分数略微下降（从 v2 虚高回落到合理值），异常站点分数大幅下降；
> - 如果以前靠绝对分数做阈值（`--min-score 90`），**v2.2 下需要重新校准基线**。
>
> 完整变更说明见 [v2.1 更新说明](#v21-更新说明)。

### 第一层：安全性 / 证书匹配 / 协议安全能力（主权重）

#### 1. `result` 基础分

- `推荐`：`+16`
- `可用`：`+9`
- `勉强`：`+2`
- `不建议`：`-8`

#### 2. `san_level`

- `精确匹配`：`+32`
- `通配匹配`：`+12`
- `无SAN`：`-18`
- `不匹配`：`-42`
- `失败`：`-32`

#### 3. `cert_ok`

- `正常`：`+20`
- 其他：`-24`

#### 4. `tls13`

- `支持`：`+14`
- 其他：`-10`

#### 5. `x25519`

- `支持`：`+14`
- 其他：`-10`

#### 6. `h2`

- `支持`：`+4`
- 其他：`-2`

#### 7. `alpn_result`

- `h2`：`+5`
- `http/1.1`：`+1`
- `未知`：`0`
- `其他`：`-1`

#### 8. `cert_chain_status`

- `完整`：`+5`
- `不完整`：`-6`
- `未知/失败`：`-2`

#### 9. `ocsp_stapling`

- `支持`：`+2`
- `未提供`：`0`
- `异常`：`-3`
- `未知`：`0`

#### 10. `expiry_days`

`expiry_days` 不再参与评分加减分，只保留在结论判定里的临期硬保护：

- `< 14`：由 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 直接判为 `不建议`
- `>= 14` 或无法解析：评分中不加分也不扣分

### 第二层：站点自然性与可用性（次权重）

> **v2.1 修订**：此层的异常项扣分全面加重，惩罚偏离正常大厂站点的行为。

#### 1. `code`

- `200`：`+10`
- `301/302`：`+7`
- `403`：`+2`
- `404`：`-10`（v2 为 `-5`）
- `405`：`-12`（v2 为 `-6`）
- 其他：`-20`（v2 为 `-10`）

#### 2. `page`

- `像正常网站`：`+12`
- `HTML但特征弱`：`+6`
- `非HTML响应`：`-6`（v2 为 `-3`）
- `错误页`：`-18`（v2 为 `-9`）
- `未知`：`0`

#### 3. `header_naturalness`

- `自然`：`+4`
- `一般`：`+1`
- `异常`：`-8`（v2 为 `-4`）

#### 4. `redirect`

- `无跳转/同域`：`+7`
- `主子域自然跳转`：`+4`
- `跨站跳转`：`-20`（v2 为 `-10`）
- `未知`：`0`

#### 5. `waf`

- `正常`：`+5`
- `疑似拦截`：`-12`（v2 为 `-6`）
- `疑似挑战`：`-28`（v2 为 `-14`）

#### 6. `ip_consistency`

- `一致`：`+5`
- `部分不一致`：`-8`（v2 为 `-4`）
- `单IP/未知`：`0`

#### 7. `asn_type`（**v2.1+ / v2.2**）

- `CDN`：`+8`
- `Hosting`：`+1`
- `ISP`：`+0`
- `Edu`：`-8`（v2.1 早期版本为 `-4`，后加重）
- `未知`：`+0`

详细背景与"大树 / 孤树"决策清单见 [ASN 类型与"大树底下好乘凉"伪装原则](#asn-类型与大树底下好乘凉伪装原则)。

### 第三层：性能与稳定性（v2.2：先门槛，后评分）

> **v2.1 / v2.2 设计原则**：
>
> - **正常范围内**加分基本保留——好的大厂站点该得到的分数不变；
> - **偏离正常值越远，扣分越陡**——因为异常本身就是风险信号。TTFB 从 500ms 涨到 1500ms 不是线性变差 3 倍，是"像正常站 → 不像正常站"的质变；
> - **抖动的加分大幅压缩**——正常大厂站点的抖动都差不多，"抖动极小"常常不是稳定信号而是缓存命中副产品，不值得为此大加分；
> - **超过数值门槛先改结论**——v2.2 不再让极端数值只靠扣分表达，而是先由 [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881) 触发 `勉强 / 不建议`。

#### 数值门槛速查（先于普通评分）

| 字段 | 软阈值：直接 `勉强` | 硬阈值：直接 `不建议 / -9999` |
| --- | --- | --- |
| `avg_tcp` / `TCP建连` | `> 200ms` | `> 280ms` |
| `avg_tls` / `TLS握手` | `> 300ms` | `> 650ms` |
| `avg_ttfb` / `TTFB` / `平均延迟` | `> 900ms` | `> 1200ms` |
| `tcp_var` / TCP 抖动 | `> 80ms` | `> 120ms` |
| `tls_var` / TLS 抖动 | `> 90ms` | `> 130ms` |
| `ttfb_var` / TTFB 抖动 | `> 450ms` | `> 650ms` |

#### 1. `stability`

- `稳定`：`+7`
- `一般`：`+1`
- `波动大`：`-10`

#### 2. `avg_tls` 分档

- `<= 20ms`：`+8`
- `<= 30ms`：`+7`
- `<= 40ms`：`+6`
- `<= 55ms`：`+5`
- `<= 70ms`：`+4`
- `<= 90ms`：`+3`
- `<= 120ms`：`+2`
- `<= 160ms`：`+0`
- `<= 220ms`：`-6`（v2 为 `-2`）
- `<= 300ms`：`-14`（v2 为 `-4`）
- `> 300ms`：`-24`（v2 为 `-6`）

#### 3. `avg_ttfb` 分档（v2.2 修订：`900ms+` 继续加重）

- `<= 120ms`：`+9`
- `<= 180ms`：`+8`
- `<= 240ms`：`+7`
- `<= 320ms`：`+6`
- `<= 420ms`：`+5`
- `<= 550ms`：`+4`
- `<= 700ms`：`+2`（v2 为 `+3`）
- `<= 900ms`：`-6`（v2 为 `+1`，**由加分变扣分并继续加重**）
- `<= 1200ms`：`-18`（v2 为 `-1`）
- `<= 1600ms`：`-32`（v2 为 `-3`）
- `> 1600ms`：`-50`（v2 为 `-6`）

#### 4. `avg_tcp` 分档

- `<= 15ms`：`+6`
- `<= 25ms`：`+5`
- `<= 35ms`：`+4`
- `<= 50ms`：`+3`
- `<= 70ms`：`+2`
- `<= 100ms`：`+1`
- `<= 140ms`：`+0`
- `<= 200ms`：`-5`（v2 为 `-2`）
- `<= 280ms`：`-12`（v2 为 `-4`）
- `> 280ms`：`-22`（v2 为 `-6`）

#### 5. `tcp_var` 分档（加分压缩，异常扣分加重）

- `<= 5ms`：`+2`（v2 为 `+4`）
- `<= 10ms`：`+1`（v2 为 `+3`）
- `<= 20ms`：`+0`（v2 为 `+2`）
- `<= 35ms`：`+0`（v2 为 `+1`）
- `<= 55ms`：`-2`（v2 为 `+0`）
- `<= 80ms`：`-6`（v2 为 `-2`）
- `<= 120ms`：`-12`（v2 为 `-4`）
- `> 120ms`：`-20`（v2 为 `-6`）

#### 6. `tls_var` 分档（加分压缩，异常扣分加重）

- `<= 5ms`：`+2`（v2 为 `+5`）
- `<= 10ms`：`+1`（v2 为 `+4`）
- `<= 18ms`：`+0`（v2 为 `+3`）
- `<= 28ms`：`+0`（v2 为 `+2`）
- `<= 40ms`：`-2`（v2 为 `+1`）
- `<= 60ms`：`-5`（v2 为 `+0`）
- `<= 90ms`：`-10`（v2 为 `-2`）
- `<= 130ms`：`-16`（v2 为 `-4`）
- `> 130ms`：`-25`（v2 为 `-6`）

#### 7. `ttfb_var` 分档（加分压缩，异常扣分最重——TTFB 抖动往往反映 WAF 干扰或路径不稳）

- `<= 20ms`：`+2`（v2 为 `+6`）
- `<= 40ms`：`+1`（v2 为 `+5`）
- `<= 70ms`：`+0`（v2 为 `+4`）
- `<= 110ms`：`+0`（v2 为 `+3`）
- `<= 160ms`：`-2`（v2 为 `+2`）
- `<= 230ms`：`-5`（v2 为 `+1`）
- `<= 320ms`：`-10`（v2 为 `-1`）
- `<= 450ms`：`-18`（v2 为 `-3`）
- `<= 650ms`：`-30`（v2 为 `-5`）
- `> 650ms`：`-45`（v2 为 `-7`）

### 关于分数的阅读方式

- 分数**不是**标准化百分制，也没有被裁剪到 `0~100`；
- 某些很差的候选可以出现负分；
- 命中 [`is_reality_hard_fail()`](reality_sni_probe_v2.2.sh:861) 或 [`performance_gate_status()`](reality_sni_probe_v2.2.sh:881) 硬阈值的记录，评分会直接输出为 `-9999`，用于明确标记 Reality 核心硬淘汰或数值项硬淘汰；
- 某些优质候选可以超过 `100`；
- 它更适合作为**同批候选之间的排序依据**。

---

## ASN 类型与"大树底下好乘凉"伪装原则

这一节从零讲起，让"完全没接触过 REALITY / 网络底层"的读者也能看明白为什么脚本会给某个域名加 8 分、给另一个扣 8 分。

### 1. 先用一句话解释 ASN 是什么

ASN（Autonomous System Number）可以粗略理解为：

> "互联网上，谁家管哪一片 IP 地址。"

整个互联网是由几万家机构自己的网络拼起来的，每家拿到一个 ASN 编号。你访问一个网站时，数据包其实是在一条条"属于某个 ASN 的管道"之间跳来跳去。

举例：

- 你访问 `www.microsoft.com`，最终落到的 IP 归属 **AS8075 (Microsoft)**；
- 你访问某大学官网，IP 可能归属 **AS某某大学自己的编号**；
- 你访问某个小型 VPS 上自建的博客，IP 归属那个机房的 ASN，例如 **AS14061 (DigitalOcean)**。

### 2. 为什么 REALITY 要关心 ASN

REALITY 的核心玩法，是把你的代理流量**伪装成访问某个"真实存在的大站"**。当 GFW 主动探测你的节点时，它看到的 TLS 握手和证书应当和真去访问那个站点完全一致。

但这件事不是"伪装得越像越好"就行，还取决于一个现实问题：

> **你藏在哪种人群里？**

这就是 PRD 里说的"背景噪声"——你的流量混入得越深，封禁代价越高，你就越安全。

这正是 ASN 的作用：ASN 决定了"你的伪装目标，在那条网络管道上有多少邻居陪你一起挡枪"。

### 3. 直白的类比：大树底下好乘凉

- **一个网站本身有多少访客** → 类似"这个人长多高"；
- **这个 IP 所在的 ASN 有多少背景流量** → 类似"这个人身边围了多少人"。

REALITY 要的不是"最高的人"，而是**最难被单独揪出来的人**。

因此脚本不看"这个网站本身有多火"，而是看：

> **"如果 GFW 对整条 ASN 管道动手，会不会误伤大批无辜服务？"**

误伤成本越高 → 这条 ASN 就是**大树**，GFW 不敢随便砍 → 你在树荫里乘凉最安全。
误伤成本越低 → 这条 ASN 就是**孤树**，砍掉几乎没有代价 → 你站在空地上毫无掩护。

### 4. 脚本把 ASN 分成哪五类

脚本通过 `whois -h whois.cymru.com` 拿到 ASN 编号和 AS 名字后，按名字里的关键词启发式归类：

| 分类 | 含义 | 评分权重 | 直觉理解 |
| --- | --- | --- | --- |
| **CDN** | 全球大流量的 CDN 或超大厂 | **+8** | 参天大树 |
| **Hosting** | VPS / IaaS 云厂商 | **+1** | 灌木丛 |
| **ISP** | 家用 / 企业宽带运营商 | **0** | 不合适当伪装目标 |
| **Edu** | 大学、教育机构 | **−8** | 孤树，直接扣分 |
| **未知** | 查不到，或归类不出 | **0** | 保留不加减 |

注意几点：

- `+8` 是第二层"站点自然性"里单项加分里的较高档位，说明当前评分体系高度重视 ASN 背景；
- `−8` 的 `Edu` 惩罚**只影响评分排序**，不直接触发结论降级（结论仍由 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 独立给出），但在同批候选里会把 Edu 域名明显压下去；
- `未知` 不惩罚，避免 `whois` 查不到就误伤；但强烈建议在跑完脚本后人工复核一次。

### 5. 哪些 ASN 属于"大树"（首选）

这一层最适合做 REALITY 的伪装目标，脚本会归到 `CDN` 并加 8 分。

| 典型 ASN | 归属 | 举例域名 | 为什么是大树 |
| --- | --- | --- | --- |
| **AS13335** | Cloudflare | `discord.com`、`zoom.us`、`shopify.com`、`www.cloudflare.com` | 全球 20%+ 网站都在它背后，封它会波及大批服务 |
| **AS8075** | Microsoft | `www.microsoft.com`、`teams.microsoft.com`、`outlook.office.com`、`*.azureedge.net` | 误伤 Teams / Outlook / Azure 的成本极高 |
| **AS15169** | Google | `www.googleapis.com`、`fonts.googleapis.com`、`lh3.googleusercontent.com` | 谷歌全家桶基础设施 |
| **AS16509 / AS14618** | Amazon / AWS | `s3.amazonaws.com`、`console.aws.amazon.com`、部分 CloudFront 域名 | 全球最大云之一，企业依赖极重 |
| **AS714 / AS6185** | Apple | `www.apple.com`、`www.icloud.com` | 流量巨大且稳定 |
| **AS20940** | Akamai | `www.akamai.com` 及大量挂 Akamai 的媒体金融站 | 老牌 CDN，覆盖面广 |
| **AS54113** | Fastly | `github.com`（部分）、`npmjs.com`、`www.fastly.com` | 开发者生态重度依赖 |
| **AS32934** | Meta / Facebook | `www.facebook.com`、`www.instagram.com` | 全球流量巨大，但国内访问性差 |

**实战优先级**：AS13335 ≈ AS8075 > AS15169 ≈ AS16509 > AS20940 > 其他。

### 6. 哪些 ASN 属于"灌木丛"（能用但不够强）

脚本会归到 `Hosting` 并加 1 分。能用，但不如大树。

| 典型 ASN | 归属 |
| --- | --- |
| AS14061 | DigitalOcean |
| AS63949 | Linode / Akamai Connected Cloud |
| AS20473 | Vultr / Choopa |
| AS16276 | OVH |
| AS24940 | Hetzner |
| AS51167 | Contabo |

为什么它们只是"灌木丛"：

1. **背景噪声薄**——这类 ASN 上的客户密度比不了 Cloudflare、Microsoft；
2. **政策高敏感**——大量翻墙服务器本身就租在这些 ASN 里，GFW 对这块的关注度天然偏高；
3. **画像陷阱**——如果你的 **REALITY 服务器本身也在某个 Hosting ASN**，而你选的 SNI 也恰好在同一个 Hosting ASN，那这条链路看起来就是"Vultr 服务器访问另一台 Vultr 的网页"，非常反常。

**建议实战动作**：

- 看到 `asn_type="Hosting"` 的候选时，**先查一下你自己 VPS 的 ASN**；
- 两边 ASN 相同或同一运营商：避开；
- 两边 ASN 完全不同：可以作为次优候选使用。

### 7. 哪些 ASN 属于"孤树 / 反模式"（应避免）

#### 7.1 严重孤树：Edu

脚本会直接扣 8 分。触发关键词包括 `university / college / school / edu / academic` 等。

为什么危险：

1. **受众窄**：大学官网平时的流量画像单薄，针对这条 ASN 做策略几乎零误伤成本；
2. **已被重点盯梢**：2023–2024 年 Edu 域名一度是社区热门推荐，**当前是明显被标记的模式**；
3. **政治不正确**：学术机构被"拿来翻墙"是非常敏感的场景，封禁理由现成。

一句话：**即使所有硬性指标全过，只要 `asn_type="Edu"`，REALITY 长期稳定性也极差。**

#### 7.2 中度孤树

脚本当前未单独扣分，但使用者应自己避免：

- **政府类域名**（`.gov`、`*.gov.*`）——高政治敏感，即使能跑也别碰；
- **小型 SaaS 自营 ASN**——流量薄；
- **国内运营商 ASN**（AS9808 移动、AS4134 电信 等）——跨境场景完全不适用；
- **某个具体中小公司的自有 ASN**——邻居太少。

#### 7.3 完美反模式（必须避免）

- **任何和翻墙相关的 ASN**：商业 VPN、翻墙代理服务商自己的 ASN；
- **已经被 `judge_sni()` 硬性淘汰的域名**：TLS1.3 不支持 / X25519 不支持 / SAN 不匹配等；
- **最终跳到其他域名的中转**：`redirect="跨站跳转"` 本身就是硬淘汰条件。

### 8. 怎么三秒钟看懂脚本给你的 ASN 结果

跑完脚本后，你会在 CSV / JSONL 里拿到两列：

- `asn`：ASN 编号，形如 `AS13335`；
- `asn_type`：分类结果，五个值之一。

简单决策表：

| 看到的组合 | 动作 |
| --- | --- |
| `asn_type="CDN"` + `推荐` + `精确匹配` | **首选**，进优选清单 |
| `asn_type="CDN"` + `可用` + `精确匹配` | **次选**，性能或自然性稍弱，仍可纳入 |
| `asn_type="Hosting"` + `推荐` | **谨慎使用**：先查你自己服务器 ASN 是否相同 |
| `asn_type="ISP"` 或 `asn="-"` / `asn_type="未知"` | 手工用 `whois` / `bgp.tools` / `ipinfo.io` 再核一次 |
| `asn_type="Edu"` | **直接放弃**，不管分数多高 |

### 9. 脚本做 ASN 判断的三个局限（务必知道）

1. **关键词匹配不精确**：AS 名字是人起的，拼写五花八门。某些 CDN 的 AS 名字里不一定含 `CDN` 关键词，会被错判成 `未知`；小型机房的名字里如果意外带 `SERVER` 字样，会被错判成 `Hosting`。
2. **whois.cymru.com 会限流**：一次性跑几百个域名时，可能偶尔拿不到返回。遇到时脚本只会写 `asn="-" / asn_type="未知"`，不会中断。
3. **只能看到探测那一刻的出口 IP**：Anycast 或多边缘 CDN 下，同一个域名在不同地区会命中不同 IP，进而可能命中不同 ASN。脚本使用的是 `curl` 实际返回的 `remote_ip`，反映的就是**你这台机器当下的命中结果**，不代表该域名在全球范围的归属。

### 10. 建议的人工复核流程

ASN 分是"快速筛选"，不是"最终审判"。实战里建议这样做：

1. 跑脚本得到 `推荐 + 精确匹配 + CDN` 的前 10–15 个候选；
2. 对每一个 IP 用 `whois`、`bgp.tools`、`ipinfo.io` 各查一次，**交叉验证 AS 号**；
3. 确认这个 ASN 不是你服务器所在的 ASN；
4. 再在你实际运行 REALITY 的服务器上，用这几个候选各试跑一次，观察稳定性；
5. 最终定 3–5 个作为轮换池，而不是固定依赖单一 SNI。

---

## 排序与筛选说明

### 1. 先过滤，再排序

脚本会先调用 [`filter_results()`](reality_sni_probe_v2.2.sh:1614)：

- 如果使用 `--only-good`，仅保留 `推荐` 和 `可用`；
- 如果使用 `--min-score`，仅保留 `score >= 指定值`；
- 两者可以叠加使用。

### 2. 当前真实排序键

过滤完成后，脚本在 [`main()`](reality_sni_probe_v2.2.sh:1633) 中按以下键排序：

1. **Reality 核心硬条件优先**：非跨站跳转、`TLS13=支持`、`X25519=支持`、`H2=支持`、且 `SAN ∈ {精确匹配, 通配匹配}` 的记录会先排前；
2. **SAN 等级降序**：`精确匹配 > 通配匹配 > 其他`；
3. **结论等级降序**：`推荐 > 可用 > 勉强 > 不建议`；
4. **评分降序**；
5. **TLS 抖动升序**；
6. **TTFB 抖动升序**。

也就是说，当前不是简单按 `score` 单键排序，而是先看 Reality 核心条件与 SAN 等级，再看结论档位和分数，最后用稳定性细项作 tie-break。

### 3. `--only-good` 与排序的关系

启用 `--only-good` 后，`勉强 / 不建议` 会在排序前就被过滤掉，因此最终表格和导出中只剩 `推荐 / 可用`。

### 4. `--min-score` 与负分

由于评分可能出现负值，`--min-score 0` 并不等于“显示全部”，它会把负分结果过滤掉。

---

## 示例输出与阅读方式

下面给出一个**按当前列布局整理后的示意表**。注意内容只是示意，不代表固定分值。

补充说明：默认终端 `页面` 列并不是直接输出原始 `page` 字段，而是由 [`print_table()`](reality_sni_probe_v2.2.sh:1539) 映射为 `网页站 / 弱网页 / 接口/下载 / 错误页 / -`；因此这里的示例列名与 CSV/JSONL 中的原始 `page` 值会刻意不同。

```txt
REALITY SNI 专业评估 v2.2
域名                       | 码   | TCP建连  | TLS握手  | TTFB     | 平均延迟 | 抖动T/TLS/F    | TLS13  | X25519 | H2     | ALPN     | SAN      | 证书 | 跳转           | WAF      | 页面       | 稳定性 | ASN类型  | 多IP       | 链         | 头部   | OCSP   | 评分  | 结论
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
www.microsoft.com          | 200  | 24ms     | 31ms     | 118ms    | 118ms    | 5/8/24ms       | 支持   | 支持   | 支持 | h2       | 精确匹配 | 正常 | 无跳转/同域  | 正常     | 网页站 | 稳定   | CDN      | 一致       | 完整       | 自然 | 支持   | 194   | 推荐
www.cloudflare.com         | 301  | 18ms     | 26ms     | 152ms    | 152ms    | 4/6/18ms       | 支持   | 支持   | 支持 | h2       | 精确匹配 | 正常 | 主子域自然... | 正常     | 弱网页 | 稳定   | CDN      | 一致       | 完整       | 自然 | 支持   | 183   | 推荐
example.org                | 403  | 90ms     | 130ms    | 680ms    | 680ms    | 22/35/180ms    | 支持   | 支持   | 支持 | http/1.1 | 通配匹配 | 正常 | 无跳转/同域  | 疑似拦截 | 错误页 | 一般   | 未知     | 单IP/未知  | 完整       | 一般 | 未提供 | 49    | 勉强
bad.example                | -    | -        | -        | -        | -        | -              | 不支持 | 不支持 | 不支持 | 未知      | 失败     | 失败 | 未知         | 正常     | -      | 波动大 | 未知     | 单IP/未知  | 未知/失败 | 一般 | 未知   | -9999 | 不建议
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

阅读建议：

1. 先看 `结论`，快速分组；
2. 再看左侧固定基础列：`TLS13`、`X25519`、`H2`、`ALPN`，确认 Reality 协议能力；
3. 如果 `评分 = -9999`，基本可直接视为命中了 Reality 核心硬淘汰或数值硬阈值；
4. 对 `推荐 / 可用` 且分数接近的候选，从 `SAN` 开始按列从左到右复核：`SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`；
5. 再看 `评分`，在同档位、关键列相近时做最终排序；
6. 最后结合 `TCP建连`、`TLS握手`、`TTFB` 与 `抖动T/TLS/F` 做性能复核；
7. 如需复查站点细节，请查看导出的 `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip`。

按列排序的直观例子：如果两个候选前半段性能几乎一样，一个是 `ASN类型=CDN / OCSP=未提供`，另一个是 `ASN类型=未知 / OCSP=支持`，通常前者更适合作为 REALITY 候选，因为 `ASN类型` 的“大树背景”权重高于 `OCSP` 这种轻量站点卫生信号。

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
33. `asn`（**v2.1+ / v2.2**：`remote_ip` 对应的 AS 编号，形如 `AS13335`，查询失败为 `-`）
34. `asn_type`（**v2.1+ / v2.2**：ASN 归类，`CDN / Hosting / ISP / Edu / 未知`）

需要注意：

- 导出字段里**没有** `expiry_days`；
- `expiry_days` 只参与 `< 14` 天临期硬保护，不再参与评分；
- `tcp_jitter` / `tls_jitter` / `ttfb_jitter` 在导出中会被格式化为带 `ms` 后缀的字符串；
- 若底层抖动值为 `999999`，v2.2 导出会写成 `-`，表示“该项抖动不可得”，不再暴露内部哨兵值；
- 默认终端表格不会输出 `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip`；
- 默认终端表格中的 `页面` 列是摘要标签，而导出中的 `page` 保留原始分类值；
- 默认终端为了阅读，会把 `SAN / 证书 / 跳转 / WAF / 页面 / 稳定性 / ASN类型 / 多IP / 链 / 头部 / OCSP` 按权重展示；CSV / JSONL 导出字段仍保留原始稳定顺序，不受终端列重排影响；
- 导出中的 `alpn_result`、`cert_chain_status`、`ocsp_stapling`、`header_naturalness`、`ip_consistency` 与终端表格中的 `ALPN / 链 / OCSP / 头部 / 多IP` 一一对应。

### CSV 表头

v2：

```csv
"domain","code","avg_tcp","avg_tls","avg_ttfb","avg_latency","jitter","tcp_jitter","tls_jitter","ttfb_jitter","tls13","x25519","h2","alpn_result","cert_ok","cert_chain_status","san_level","ocsp_stapling","page","header_naturalness","waf","redirect","ip_consistency","stability","score","result","issuer","final_url","title","content_type","size","remote_ip"
```

v2.1+ / v2.2（末尾追加 2 列）：

```csv
"domain","code","avg_tcp","avg_tls","avg_ttfb","avg_latency","jitter","tcp_jitter","tls_jitter","ttfb_jitter","tls13","x25519","h2","alpn_result","cert_ok","cert_chain_status","san_level","ocsp_stapling","page","header_naturalness","waf","redirect","ip_consistency","stability","score","result","issuer","final_url","title","content_type","size","remote_ip","asn","asn_type"
```

### JSONL 单行结构示意

v2：

```json
{"domain":"www.microsoft.com","code":"200","avg_tcp":"24ms","avg_tls":"31ms","avg_ttfb":"118ms","avg_latency":"118ms","jitter":"TCP:5ms/TLS:8ms/TTFB:24ms","tcp_jitter":"5ms","tls_jitter":"8ms","ttfb_jitter":"24ms","tls13":"支持","x25519":"支持","h2":"支持","alpn_result":"h2","cert_ok":"正常","cert_chain_status":"完整","san_level":"精确匹配","ocsp_stapling":"支持","page":"像正常网站","header_naturalness":"自然","waf":"正常","redirect":"无跳转/同域","ip_consistency":"一致","stability":"稳定","score":"162","result":"推荐","issuer":"C=US, O=Microsoft Corporation, CN=Microsoft Azure RSA TLS Issuing CA 03","final_url":"https://www.microsoft.com/","title":"Microsoft – AI, Cloud, Productivity, Computing, Gaming & Apps","content_type":"text/html; charset=utf-8","size":"65842","remote_ip":"23.45.119.216"}
```

v2.1+ / v2.2（末尾新增 `asn / asn_type`；下面分数按当前 v2.2 权重示意）：

```json
{"domain":"www.microsoft.com","code":"200","avg_tcp":"24ms","avg_tls":"31ms","avg_ttfb":"118ms","avg_latency":"118ms","jitter":"TCP:5ms/TLS:8ms/TTFB:24ms","tcp_jitter":"5ms","tls_jitter":"8ms","ttfb_jitter":"24ms","tls13":"支持","x25519":"支持","h2":"支持","alpn_result":"h2","cert_ok":"正常","cert_chain_status":"完整","san_level":"精确匹配","ocsp_stapling":"支持","page":"像正常网站","header_naturalness":"自然","waf":"正常","redirect":"无跳转/同域","ip_consistency":"一致","stability":"稳定","score":"194","result":"推荐","issuer":"C=US, O=Microsoft Corporation, CN=Microsoft Azure RSA TLS Issuing CA 03","final_url":"https://www.microsoft.com/","title":"Microsoft – AI, Cloud, Productivity, Computing, Gaming & Apps","content_type":"text/html; charset=utf-8","size":"65842","remote_ip":"23.45.119.216","asn":"AS8075","asn_type":"CDN"}
```

> 注意：这里的 `score=194` 是按当前 v2.2 权重对上方示意字段推导出的示意值，不代表固定实测值。它相对 v2 示例不同，来自 v2 评分 bug 修复、v2.1 第二/三层权重重校，以及 v2.2 对 `OCSP` 降权、对 `expiry_days` 去评分化后的结果。详见 [v2.1 更新说明](#v21-更新说明) 与 [v2.2 更新说明](#v22-更新说明)。

---

## 局限性

当前版本依然有一些明确局限：

1. [`check_cert_ok()`](reality_sni_probe_v2.2.sh:413) 只判断“有没有拿到 PEM”，不等于完整证书链校验通过；
2. [`check_cert_chain_status()`](reality_sni_probe_v2.2.sh:443) 与 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.2.sh:468) 都基于 `openssl s_client` 文本输出，不是结构化 PKI / OCSP 验证器；
3. [`check_tls13_from_sclient()`](reality_sni_probe_v2.2.sh:484) 和 [`check_x25519_from_sclient()`](reality_sni_probe_v2.2.sh:489) 是基于文本匹配，不是结构化 TLS 指纹分析；
4. 页面 / 头部 / WAF / 跳转判断都属于启发式规则，不代表完整浏览器视角；
5. `avg_latency` 当前只是 `avg_ttfb` 的别名，命名更偏展示用途；
6. `expiry_days` 只参与 `< 14` 天临期硬保护，但当前不在默认终端和导出字段中显示；
7. 多 IP 一致性抽样当前只检查最多 3 个 IPv4 A 记录，不覆盖 AAAA，也不保证穷尽所有边缘节点；
8. 评分体系虽然已经从“速度优先”转向“安全性主权重”，但仍然只是启发式排序工具，不是绝对真理；
9. 结果高度依赖你本机的网络出口、DNS、地区与链路状态；
10. 终端表格虽然已做中英文宽度修复，但不同终端字体、East Asian Width 策略下仍可能存在轻微视觉偏差；
11. 默认终端和 v2.2 的 CSV/JSONL 都会把抖动哨兵值 `999999` 摘要显示为 `-`，语义是“该项抖动不可得”；
12. 缺少 `curl` / `openssl` / 合适 locale 时，脚本会尽量退化运行，但结果解释必须更保守。

### v2.1+ / v2.2 专属局限

1. ASN 分类依赖 `whois.cymru.com` 返回的 AS 名字做关键词匹配，不是权威 ASN 数据库，**可能错判**（特别是小众 CDN 或名字特殊的机构）；
2. ASN 查询依赖外网 whois 服务，批量扫描时可能偶发限流；遇到时脚本会把对应记录写为 `asn="-" / asn_type="未知"`，不中断主流程；
3. 不检测 ECH / HTTP/3 / PQC 等新协议特征——经评估后认为这些方向对 REALITY SNI 选择的实际帮助极小，参见 [v2.1 更新说明 → 刻意没做的几件事](#刻意没做的几件事)；
4. 不检测 TFO / MSS / Anycast 等 L3/L4 指纹——需要 root 或 raw socket，破坏脚本的"普通用户单文件 Bash"运行姿态。

---

## FAQ

### 1. 为什么某些站点速度很好，分数却不高？

因为当前 [`calc_sni_score()`](reality_sni_probe_v2.2.sh:1010) 的主权重已经放在证书、SAN、`TLS1.3`、`X25519`、`ALPN`、证书链这些安全与身份特征上。速度快只能在第三层补充分中加分，无法弥补根本性的证书或协议短板。`OCSP` 仍会参与评分，但在 v2.2 中已下调为轻量信号；`expiry_days` 只保留 `< 14` 天临期硬保护，不再参与评分排序。

### 2. 为什么 `通配匹配` 不再直接判死？

因为当前 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 已把 `通配匹配` 调整为“次优可用”。它不能拿到和 `精确匹配` 一样高的权重，但如果其他条件好，仍可得到 `可用`；如果页面或稳定性较弱，则多半回落为 `勉强`。

### 3. 为什么 `403` 有时还是 `可用` 或 `勉强`？

因为当前 [`judge_sni()`](reality_sni_probe_v2.2.sh:922) 对 `403` 的处理是：只要没有提前命中证书 / SAN / 到期 / Reality 核心硬性淘汰条件，`403` 仍可能落入 `可用` 或 `勉强`。这反映的是“可作为候选参考”，不等于“用户访问体验优秀”。

### 4. 为什么默认终端里现在能看到 `ALPN`、`OCSP`、`链`、`头部`、`多IP`，而且后半段列顺序变了？

因为当前 [`print_table()`](reality_sni_probe_v2.2.sh:1539) 的表头已经扩展，新增这些判定列，同时通过 [`table_display_width()`](reality_sni_probe_v2.2.sh:1447) 与 [`table_fit_text()`](reality_sni_probe_v2.2.sh:1466) 修复了中英文混排时的表格对齐问题。

v2.2 后半段站点判断列现在按阅读权重排列为：`SAN → 证书 → 跳转 → WAF → 页面 → 稳定性 → ASN类型 → 多IP → 链 → 头部 → OCSP`。这样分数接近时，不熟悉各项权重的用户也可以优先看左侧更重要的项，再看右侧轻量辅助项。

### 5. 为什么“平均延迟”和 `TTFB` 一样？

因为当前实现中 [`probe_one()`](reality_sni_probe_v2.2.sh:1248) 直接把 `avg_ttfb` 复用为 `avg_latency` 输出，它目前就是展示别名，不是新的独立指标。

### 6. 为什么在某些环境下不再出现 `ignored null byte in input`？

因为当前版本会在两条链路上主动剥离 NUL 字节：

- `curl` 采样阶段会在读取响应体和响应头时做过滤，见 [`check_curl_once()`](reality_sni_probe_v2.2.sh:319)；
- `openssl s_client` 的原始输出也会经过 [`strip_nul_bytes()`](reality_sni_probe_v2.2.sh:120) 清洗，见 [`fetch_tls_bundle()`](reality_sni_probe_v2.2.sh:384)。

这能减少把异常二进制内容装入 shell 变量时触发的告警，但并不改变站点真实返回内容本身。

### 7. 为什么在某些环境下中文列宽或输出看起来更正常了？

因为当前版本增加了 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.2.sh:28) 的 UTF-8 bootstrap，并在 [`table_display_width()`](reality_sni_probe_v2.2.sh:1447) / [`table_fit_text()`](reality_sni_probe_v2.2.sh:1466) 中按 ASCII 1 列、非 ASCII 2 列做宽度估算，减少中文显示错位。

### 8. 我该用 v2、v2.1 还是 v2.2？

默认推荐 **v2.2**。它继承 v2.1 的 ASN 与参数兼容性，并额外修复 HTTP/2 退化、SAN 多行解析、macOS/BSD 日期解析、导出哨兵值等问题，同时继续校准安全优先评分权重。继续用 v2 或 v2.1 的唯一合理理由是：下游消费脚本严格依赖某个具体的绝对分数阈值，且短期内不方便重新校准。

### 9. v2.2 为什么仍没有做 ECH / HTTP/3 / PQC 检测？

因为对 REALITY 的实际帮助极小，代价却很大：

- **ECH（加密 ClientHello）**：REALITY 协议本身要求 SNI 明文，和 ECH 的设计目标互斥。探测目标是否支持 ECH 对 REALITY 伪装效果既无加成也无明确危害，只是纯噪声。而做握手级 ECH 验证还需要特殊构建的 `curl + OpenSSL 3.5+ / BoringSSL`，无法作为单文件 Bash 的默认依赖。
- **HTTP/3 / QUIC**：REALITY 跑在 TCP 上，目标是否支持 H3 和伪装效果无关。Debian 12 默认 `curl` 也不带 `--http3`，真正的 QUIC 握手还得自编 ngtcp2 版 curl。
- **PQC（X25519MLKEM768 等）**：这是 Xray / utls **客户端层**要解决的问题——GFW 看的是你的客户端发了什么 PQC key share，不是目标服务端支不支持 PQC。把"目标是否支持 PQC"塞进 SNI 探测脚本只会无谓缩小候选池。如果想对齐浏览器指纹，正确路径是升级 Xray 版本和它的 utls 栈。

更完整的评估请参考 [v2.1 更新说明 → 刻意没做的几件事](#刻意没做的几件事)。

### 10. 跑一次 v2.2 比 v2 慢多少？

取决于是否启用 ASN 查询，以及是否手动提高并发：

- 默认并发为 `1`，v2.2 会明显比高并发扫描慢，但能减少低配服务器 CPU 满载对 TLS / TTFB / 抖动的污染；
- 默认情况下每域多花 **0.3–0.8 秒**，主要是 `whois` 查 ASN；
- 加 `--no-asn` 可以省掉这一步，回到更接近 v2 的单域检测速度；
- 加 `--jitter 300` 会在每个 worker 启动前最多再加 0.3 秒随机 sleep；
- 如果确认机器资源充足，100 域可手动用 `-j 2` 或更高并发做初筛，但最终候选建议仍用默认 `-j 1` 复测。

如果需要追求最快体验，`--no-asn` 搭配手动提高 `-j` 可以加快初筛；但最终用于 REALITY 的候选应以低并发复测结果为准。

### 11. v2、v2.1 和 v2.2 跑同一个域名，为什么分数不一样？

两个原因叠加：

1. **v2 有 bug**：第三层分档用 `&& ||` 链式结构，bash 运算符特性导致命中某档后后续档位仍会累加，越好的候选分数虚高越多。v2.1 改为 `if/elif/else` 严格按表打分。
2. **v2.1 / v2.2 主动重新校准了权重**：核心原则是"偏离正常值越远扣分越陡"。v2.1 先把 `avg_ttfb` 超过 1600ms 的扣分从 `-6` 加到 `-35`，当前 v2.2 又进一步加重 `900ms+` 区间，`>1600ms` 为 `-50`，并继续压缩 `ttfb_var` 的加分。

综合影响：

- **理想大厂站点**：分数基本持平或略高（v2 虚高被修，但权重校准给了更清晰的区分）；
- **TTFB 异常高的站点**：分数大幅下降，当前 v2.2 对 `900ms+` 已明显加重，避免 900–1200ms 站点仅靠背景分压过 500–700ms 站点；
- **抖动极端的站点**：分数明显下降；
- **相对排序会按"安全性"重排**：再也不会出现 TTFB 1500+ms 的站点和 500ms 的站点同分，也会避免一方 900ms+、另一方 500–700ms 时仍被轻量背景分反超。

详细分值变化见 [评分机制与权重细节](#评分机制与权重细节) 里各档的 "v2.1 为 X / v2 为 Y" 注释。

### 12. 脚本把 `www.microsoft.com` 标成 "疑似挑战"、`www.apple.com` 标成 "无SAN"，这正常吗？

多半是本机环境问题，不是目标域名的实际情况。常见触发：

- **Windows Git Bash / MSYS2 下的 `curl`**：某些版本对 HTTP/2 上报不完整；v2.2 会尽量用 OpenSSL ALPN 兜底，无法确认时标为 `未知`；
- **Windows Git Bash 下的 `openssl`**：对某些 SAN 扩展的文本输出格式与 Linux 不同；v2.2 已改为读取完整 SAN 块以降低漏捞概率；
- **代理 / 防火墙**：本机有企业代理或杀软 MITM 也会让证书链异常、SAN 不匹配；
- **网络质量差**：握手超时导致 TLS 抖动大，`check_tls13_from_sclient()` 拿到残缺输出后误判"不支持"。

**最可靠的验证环境是 Debian 12 / Ubuntu 22.04+ 上 stock `curl + openssl`**。如果打算长期部署，在你实际跑 REALITY 的那台服务器上跑 v2.2 得到的结果才算数。

### 13. 同一个域名，我在不同服务器上测出来的分数差很多，哪个才对？

**都对，但只有"你实际部署 REALITY 的那台服务器"上的分数才有意义。**

脚本测的是"从当前这台服务器出口到目标 SNI 的真实链路质量"。不同服务器的上游运营商、peering 质量、transit 路径都不一样，结果差 10 倍都很正常。

举个实测案例：两台都标注"日本 IP"的 VPS，访问同样的 `.ac.jp` 大学域名：

- 服务器 B：TTFB 700–1100ms，最优站点只能拿到 98 分（"可用"）
- 服务器 C：TTFB 50–100ms，最优站点拿到 192 分（"推荐"）

两台都在日本，但上游不同——服务器 C 直接 peer 日本学术网 SINET，服务器 B 绕了远路。

**正确用法**：在你要部署 REALITY 的那台服务器上跑脚本，选它给出的高分候选。不要把一台服务器的结果搬到另一台。

详见开头的 [⚠️ 使用前必读](#️-使用前必读必须在-reality-服务器上运行)。
