# REALITY SNI Probe v2

用于**批量评估域名是否适合作为 REALITY SNI 候选站点**的 Bash 检测脚本，核心脚本为 [`reality_sni_probe_v2.sh`](reality_sni_probe_v2.sh)。

该脚本不是通用站点测速器，而是围绕 REALITY 场景做“候选 SNI 质量筛查”：

- 检查 TLS 侧是否具备较理想的协商特征；
- 检查证书是否可取、SAN 是否匹配；
- 检查 HTTP/2、跳转、页面形态、疑似 WAF/挑战页；
- 基于多次采样统计 TCP / TLS / TTFB 平均值与抖动；
- 给出 `推荐 / 可用 / 勉强 / 不建议` 结论与评分，便于批量筛选。

---

## 目录

- [项目简介](#项目简介)
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
- [排序与筛选说明](#排序与筛选说明)
- [示例输出与阅读方式](#示例输出与阅读方式)
- [CSV / JSONL 导出字段说明](#csv--jsonl-导出字段说明)
- [局限性](#局限性)
- [FAQ](#faq)

---

## 项目简介

[`reality_sni_probe_v2.sh`](reality_sni_probe_v2.sh) 的目标，是把“一个域名能不能拿来当 REALITY 的 SNI 候选”拆成多个可量化维度，再统一汇总成结论与分数。

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

- [`probe_one()`](reality_sni_probe_v2.sh:1014)：单域名完整检测主流程；
- [`judge_sni()`](reality_sni_probe_v2.sh:705)：根据硬门槛和分支规则给出结论；
- [`calc_sni_score()`](reality_sni_probe_v2.sh:778)：按当前三层权重累计分数；
- [`check_h2()`](reality_sni_probe_v2.sh:341)：独立检测 HTTP/2；
- [`fetch_tls_bundle()`](reality_sni_probe_v2.sh:232)：抓取 `openssl s_client` 输出与证书 PEM；
- [`check_san_level()`](reality_sni_probe_v2.sh:553)：判断证书 SAN 是否精确匹配、通配匹配或不匹配；
- [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.sh:265)：提取实际 ALPN 协商结果；
- [`check_cert_chain_status()`](reality_sni_probe_v2.sh:290)：判断证书链完整性；
- [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.sh:315)：判断 OCSP Stapling 状态；
- [`sample_ip_consistency()`](reality_sni_probe_v2.sh:469)：抽样检查多 IP 一致性；
- [`check_header_naturalness()`](reality_sni_probe_v2.sh:424)：评估 HTTP 响应头自然度。

---

## 核心能力概览

本脚本**当前真实具备**以下能力：

- 支持直接传入多个域名；
- 支持通过文件批量读入域名；
- 自动清洗输入域名，去掉协议头、路径、端口，并转为小写，见 [`normalize_domain()`](reality_sni_probe_v2.sh:112)；
- 启动时会尝试选择 UTF-8 locale，并在需要时重新 `exec` 自己，减少中文表头/内容在不同 shell 中的乱码问题，见 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.sh:28)；
- 每个域名默认进行 3 次 `curl` 采样，计算平均值与抖动；
- 检测 TCP 建连时间、TLS 握手时间、TTFB；
- 提取 HTTP 版本、状态码、内容类型、响应大小、最终 URL、HTML 标题、响应头摘要、远端 IP；
- 对 `curl` 响应体与响应头、以及 `openssl s_client` 输出都做 NUL 过滤，避免 `ignored null byte in input` 干扰，分别见 [`check_curl_once()`](reality_sni_probe_v2.sh:179)、[`fetch_tls_bundle()`](reality_sni_probe_v2.sh:232) 与 [`strip_nul_bytes()`](reality_sni_probe_v2.sh:87)；
- 通过 `openssl` 解析证书、到期时间、颁发者、SAN、证书链状态、OCSP Stapling、证书指纹；
- 判断 `TLS 1.3`、`X25519`、`HTTP/2` 与实际 `ALPN` 协商结果；
- 区分 SAN `精确匹配` 与 `通配匹配`，并把前者视为更优；
- 抽样检测同域名多个 IP 的一致性；
- 评估 HTTP 响应头自然度；
- 判断页面是否更像“正常网页 / 弱网页 / 非 HTML 响应 / 错误页”；
- 判断是否疑似 WAF 挑战或拦截；
- 判断跳转是否自然；
- 综合形成稳定性、结论和评分；
- 支持结果表格输出，并针对中英文混排做列宽对齐修复，见 [`table_display_width()`](reality_sni_probe_v2.sh:1189) 与 [`table_fit_text()`](reality_sni_probe_v2.sh:1208)；
- 支持 CSV / JSONL 导出；
- 支持仅保留 `推荐 / 可用`，以及按最小分数过滤；
- 会对输入域名去重，避免重复检测，见 [`dedup_domains()`](reality_sni_probe_v2.sh:1369)。

本脚本**没有实现**的能力包括但不限于：

- 不主动探测完整 ALPN 候选列表，只记录本次 `openssl s_client` 实际协商结果；
- 不检测 QUIC / HTTP/3；
- 不做 ASN、地理位置、运营商层面的分析；
- 不直接验证“真实 REALITY 握手是否可用”；
- 不做深度页面渲染，只做启发式文本级判断；
- 不提供交互式 UI。

---

## 依赖环境与前置要求

### 1. 运行环境

脚本头部使用 [`#!/usr/bin/env bash`](reality_sni_probe_v2.sh:1)，因此需要 Bash 环境。

适合环境示例：

- Linux
- macOS
- WSL
- Git Bash / MSYS2 / Cygwin（需自行确认 `locale`、`mktemp`、`jobs`、`mapfile` 等兼容性）

### 2. 必需依赖

#### `curl`

用于 HTTP/HTTPS 采样，见 [`check_curl_once()`](reality_sni_probe_v2.sh:175) 与 [`check_h2()`](reality_sni_probe_v2.sh:268)。

缺失时：

- 常规采样会返回占位值，无法得到有效延迟、状态码与页面信息；
- HTTP/2 检测直接返回 `不支持`；
- 页面、跳转、WAF、稳定性等结论会显著退化。

#### `openssl`

用于 TLS 握手信息与证书解析，见 [`fetch_tls_bundle()`](reality_sni_probe_v2.sh:224)、[`cert_text_from_pem()`](reality_sni_probe_v2.sh:248)、[`get_expiry_from_pem()`](reality_sni_probe_v2.sh:308)。

缺失时：

- 无法获取证书 PEM；
- 证书状态、SAN、到期时间、Issuer、TLS1.3、X25519 等关键指标都会退化；
- 由于 [`judge_sni()`](reality_sni_probe_v2.sh:469) 会把 `cert_ok != 正常` 直接降为 `不建议`，因此结果会明显偏保守。

### 3. 可选依赖

#### `timeout`

脚本通过 [`safe_timeout()`](reality_sni_probe_v2.sh:76) 包装 `openssl s_client` 调用。若系统存在 `timeout`，则 TLS 抓取阶段会被超时保护；若不存在，就直接执行命令。

#### `date -d`

到期剩余天数计算依赖 [`days_to_expiry_from_pem()`](reality_sni_probe_v2.sh:315) 中的 `date -d`。某些平台如 BSD/macOS 默认 `date` 语法不同，可能导致剩余天数为空。

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
chmod +x reality_sni_probe_v2.sh
```

如果你只是复制脚本文件，也可以：

```bash
chmod +x reality_sni_probe_v2.sh
```

### 方式二：保持为单文件脚本使用

本项目当前核心就是 [`reality_sni_probe_v2.sh`](reality_sni_probe_v2.sh)，无需额外安装 Python 包或 Node.js 依赖。

---

## 如何使用脚本

### 1. 直接检测若干域名

```bash
./reality_sni_probe_v2.sh www.microsoft.com www.cloudflare.com www.apple.com
```

### 2. 从文件批量检测

```bash
./reality_sni_probe_v2.sh -f domains.txt
```

`domains.txt` 示例：

```txt
www.microsoft.com
https://www.cloudflare.com/
www.apple.com:443
# 注释行会被忽略
```

这些输入会被 [`normalize_domain()`](reality_sni_probe_v2.sh:108) 统一规整为纯域名。

### 3. 指定并发、超时、采样次数

```bash
./reality_sni_probe_v2.sh -f domains.txt -j 8 --timeout 12 --samples 5
```

### 4. 仅保留较好结果

```bash
./reality_sni_probe_v2.sh -f domains.txt --only-good
```

`--only-good` 对应 [`filter_results()`](reality_sni_probe_v2.sh:1032)，只保留 `推荐` 和 `可用`。

### 5. 按最小分数过滤

```bash
./reality_sni_probe_v2.sh -f domains.txt --min-score 90
```

### 6. 导出 CSV / JSONL

```bash
./reality_sni_probe_v2.sh -f domains.txt -o result.csv --json result.jsonl
```

---

## 命令行参数说明

脚本参数定义见 [`usage()`](reality_sni_probe_v2.sh:87) 与 [`main()`](reality_sni_probe_v2.sh:1051)。

| 参数 | 含义 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `-f FILE` | 域名文件 | 无 | 从文件逐行读取域名，忽略空行与 `#` 注释行 |
| `-o FILE` | 导出 CSV | 空 | 调用 [`export_csv()`](reality_sni_probe_v2.sh:1000) |
| `--json FILE` | 导出 JSONL | 空 | 调用 [`export_jsonl()`](reality_sni_probe_v2.sh:1017) |
| `-j NUM` | 并发数 | `4` | 写入 [`JOBS`](reality_sni_probe_v2.sh:65)，通过 [`run_with_limit()`](reality_sni_probe_v2.sh:863) 控制后台任务数 |
| `--timeout NUM` | 单次请求超时 | `10` | 写入 [`TIMEOUT_SEC`](reality_sni_probe_v2.sh:66)，影响 `curl` 与 `openssl s_client` 超时 |
| `--samples NUM` | 采样次数 | `3` | 写入 [`SAMPLES`](reality_sni_probe_v2.sh:67)，每个域名执行多少次 `curl` 采样 |
| `--only-good` | 仅输出好结果 | `0` | 仅保留 `推荐 / 可用` |
| `--min-score N` | 最低分数筛选 | 空 | 只输出评分不低于该值的记录 |
| `-h`, `--help` | 帮助 | 无 | 显示帮助并退出 |

### 参数校验规则

脚本会在 [`main()`](reality_sni_probe_v2.sh:1060) 中做基础校验：

- `-j` 必须是正整数；
- `--timeout` 必须是正整数；
- `--samples` 必须是正整数；
- `--min-score` 必须是数值；
- 未提供任何有效域名会直接报错退出；
- 读取完成后还会做一次去重与空值过滤。

---

## UTF-8 / locale 兼容处理

这是近几轮修改里比较重要但容易被忽略的一点。

脚本在正式执行前，会先调用 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.sh:28)：

1. 通过 [`select_utf8_locale()`](reality_sni_probe_v2.sh:4) 优先从当前 `LC_CTYPE`、`LANG` 中挑选 UTF-8 locale；
2. 若当前环境不合适，再按 `C.UTF-8`、`en_US.UTF-8`、`UTF-8` 依次尝试；
3. 如果发现 `LC_ALL` 已设置，或 `LANG` / `LC_CTYPE` 不符合目标 locale，并且尚未完成 bootstrap，则重新 `exec` 脚本；
4. 重新启动时会显式 `unset LC_ALL`，并导出新的 `LANG`、`LC_CTYPE`；
5. 并发 worker 进程也会继承同样的 UTF-8 相关环境，见 [`main()`](reality_sni_probe_v2.sh:1451) 附近的 worker 启动逻辑。

这一处理的目标不是改变检测逻辑，而是尽量让：

- 中文表头和中文结果值更稳定地显示；
- [`table_display_width()`](reality_sni_probe_v2.sh:1189) / [`table_fit_text()`](reality_sni_probe_v2.sh:1208) 的宽度计算更不容易被错误 locale 干扰；
- 某些 shell 环境下的乱码或列错位概率降低。

需要注意：如果宿主系统本身没有可用 UTF-8 locale，脚本仍会回退到 `C.UTF-8` 字符串尝试运行，但实际显示效果仍取决于系统环境。

---

## 检测流程总览

单域名主流程由 [`probe_one()`](reality_sni_probe_v2.sh:1014) 驱动，可概括为：

1. **重复采样**：调用 [`check_curl_once()`](reality_sni_probe_v2.sh:179) 进行 `SAMPLES` 次 HTTPS 请求；
2. **提取样本指标**：收集 TCP 建连、TLS 握手、TTFB、HTTP 版本、状态码、内容类型、响应体大小、最终 URL、页面标题、响应头摘要、远端 IP；
3. **统计多次样本**：计算平均值与抖动；
4. **统计成功样本数**：状态码为 `200/301/302/403` 时视作 `ok sample`；
5. **选择首个有效样本**：并不是挑最快样本，而是取第一个拿到三位状态码的样本作为页面 / WAF / 跳转 / 头部分析基准；
6. **抓取 TLS 证书材料**：通过 [`fetch_tls_bundle()`](reality_sni_probe_v2.sh:232) 运行带 `-status` 与 `-alpn 'h2,http/1.1'` 的 `openssl s_client`；
7. **证书分析**：解析证书文本、`TLS1.3`、`X25519`、实际 `ALPN`、证书可用性、证书链状态、SAN、OCSP Stapling、证书指纹、到期时间、颁发者；
8. **HTTP/2 检测**：若首个有效样本已是 HTTP/2，则直接记为支持，否则走 [`check_h2()`](reality_sni_probe_v2.sh:341) 再测一次；
9. **启发式页面判断**：根据状态码、标题、内容类型、大小判断页面类型；
10. **启发式响应头判断**：调用 [`check_header_naturalness()`](reality_sni_probe_v2.sh:424) 评估头部自然度；
11. **启发式 WAF 判断**：根据状态码与关键字推断是否疑似挑战/拦截；
12. **跳转自然度判断**：分析最终 URL 是否同域、主子域、跨站；
13. **多 IP 一致性抽样**：调用 [`sample_ip_consistency()`](reality_sni_probe_v2.sh:469) 对最多 3 个 A 记录做一致性复核；
14. **稳定性判断**：根据成功样本数与 TLS/TTFB 抖动判断 `稳定 / 一般 / 波动大`；
15. **结论判定**：调用 [`judge_sni()`](reality_sni_probe_v2.sh:705) 产生 `推荐 / 可用 / 勉强 / 不建议`；
16. **评分**：调用 [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 叠加三层权重分；
17. **过滤、排序、展示/导出**：由 [`filter_results()`](reality_sni_probe_v2.sh:1354)、[`print_table()`](reality_sni_probe_v2.sh:1281)、[`export_csv()`](reality_sni_probe_v2.sh:1320)、[`export_jsonl()`](reality_sni_probe_v2.sh:1338) 完成。

---

## 脚本实际执行的检测项

这一节强调的是：**脚本真实做了哪些探测动作**，而不是默认表格显示了哪些列。

### 1. `curl` 常规 HTTPS 采样

见 [`check_curl_once()`](reality_sni_probe_v2.sh:179)。脚本实际执行的命令形态为：

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

见 [`check_h2()`](reality_sni_probe_v2.sh:341)。脚本按两步尝试：

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

只要最终版本号是 `2/2.0` 且状态码为任意三位 HTTP 码，就判为 `支持`。

### 3. `openssl s_client` TLS 抓取

见 [`fetch_tls_bundle()`](reality_sni_probe_v2.sh:232)。命令形态为：

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
- 通过 [`strip_nul_bytes()`](reality_sni_probe_v2.sh:87) 过滤 NUL 字节，减少 shell 变量告警。

### 4. `openssl x509` 证书解析

脚本内部会对 PEM 做多次解析：

#### 解析完整证书文本

见 [`cert_text_from_pem()`](reality_sni_probe_v2.sh:248)：

```bash
openssl x509 -text -noout
```

#### 读取证书到期时间

见 [`get_expiry_from_pem()`](reality_sni_probe_v2.sh:308) 与 [`days_to_expiry_from_pem()`](reality_sni_probe_v2.sh:315)：

```bash
openssl x509 -noout -enddate
```

#### 读取颁发者

见 [`get_issuer_short_from_pem()`](reality_sni_probe_v2.sh:330)：

```bash
openssl x509 -noout -issuer
```

### 5. SAN 覆盖级别判断

见 [`check_san_level()`](reality_sni_probe_v2.sh:553)。它不是外部命令，而是基于 `openssl x509 -text -noout` 的结果，读取 `X509v3 Subject Alternative Name` 进行判断：

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

见 [`check_tls13_from_sclient()`](reality_sni_probe_v2.sh:258)。脚本通过匹配 `openssl s_client` 输出中的以下模式做判断：

- `Protocol : TLSv1.3`
- `New, TLSv1.3`

匹配到即记为 `支持`，否则为 `不支持`。

### 7. X25519 判断

见 [`check_x25519_from_sclient()`](reality_sni_probe_v2.sh:263)。脚本匹配以下关键词：

- `Server Temp Key: X25519`
- `group: X25519`
- 任意 `X25519`

匹配到即记为 `支持`，否则为 `不支持`。

### 8. 页面类型判断

见 [`page_naturalness()`](reality_sni_probe_v2.sh:425)。这部分不是协议级硬校验，而是**启发式分析**：

- `200/301/302` 且内容类型像 HTML、大小至少 `512`、并且标题存在：`像正常网站`；
- `200/301/302` 且 HTML 但特征弱：`HTML但特征弱`；
- `200/301/302` 但不是 HTML：`非HTML响应`；
- `403/404/405`：`错误页`；
- 其他：`未知`。

### 9. WAF / 挑战页判断

见 [`detect_waf_challenge()`](reality_sni_probe_v2.sh:407)。同样属于**启发式分析**，不是严格 WAF 指纹引擎。

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

见 [`redirect_naturalness()`](reality_sni_probe_v2.sh:595)：

- 最终 host 与输入域名一致：`无跳转/同域`；
- 主域与 `www.` 等主子域互跳：`主子域自然跳转`；
- 跳到明显无关域名：`跨站跳转`；
- 无法提取：`未知`。

### 11. 稳定性判断

见 [`stability_level()`](reality_sni_probe_v2.sh:670)。输入包括：

- `ok_count`：成功样本数；
- `samples`：总采样数；
- `tls_var`：TLS 抖动；
- `ttfb_var`：TTFB 抖动。

规则为：

- 成功样本达到全部样本，且 `tls_var <= 40`，且 `ttfb_var <= 200`：`稳定`；
- 否则只要成功样本达到半数以上：`一般`；
- 其他：`波动大`。

### 12. 实际 ALPN 协商结果

见 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.sh:265)。脚本从 `openssl s_client` 输出中提取本次实际协商结果，可能值为：

- `h2`
- `http/1.1`
- `其他`
- `未知`

需要注意：

- 这不是“服务端支持列表”，而是**本次握手实际协商到的协议**；
- `H2` 与 `ALPN` 不是同一字段：`H2` 代表脚本对 HTTP/2 可用性的综合判断，`ALPN` 代表 TLS 握手里实际协商结果。

### 13. 证书链完整性

见 [`check_cert_chain_status()`](reality_sni_probe_v2.sh:290)。脚本根据 `openssl s_client` 输出中的验证结果，把证书链状态分为：

- `完整`：出现 `Verify return code: 0 (ok)`；
- `不完整`：出现本地发行者缺失、自签、verify error 等明显异常；
- `未知/失败`：握手失败、无证书、超时等无法可靠判断。

这项**不是当前结论的硬性条件**，但会参与评分。

### 14. OCSP Stapling

见 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.sh:315)。脚本通过 `openssl s_client -status` 检查 OCSP Stapling，可能值为：

- `支持`
- `未提供`
- `异常`
- `未知`

当前行为是：

- 只作为评分项，不会单独触发 `不建议`；
- `支持` 加分，`未提供` 与 `异常` 分别小幅减分。

### 15. HTTP 响应头自然度

见 [`check_header_naturalness()`](reality_sni_probe_v2.sh:424)。脚本会把状态码、内容类型和响应头拼接后做启发式评分：

- 常见的 `server:`、`content-type:`、`cache-control:`、`strict-transport-security:`、`content-encoding:`、`alt-svc:` 等头部会加分；
- 命中 `cf-ray`、`challenge`、`captcha` 等明显挑战 / 代理痕迹会减分；
- 最终归类为 `自然 / 一般 / 异常`。

### 16. 多 IP 一致性抽样

见 [`sample_ip_consistency()`](reality_sni_probe_v2.sh:469)。脚本会解析最多 3 个 IPv4 A 记录，并逐个复核：

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

终端表格列定义见 [`TABLE_HEADERS`](reality_sni_probe_v2.sh:1180)，默认显示以下 23 列：

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
- OCSP
- 证书
- 链
- SAN
- 页面
- 头部
- WAF
- 跳转
- 多IP
- 稳定性
- 评分
- 结论

### 2. 脚本实际还计算了但默认终端不会单独成列、或仅在导出中更完整可见的字段

在 [`probe_one()`](reality_sni_probe_v2.sh:1159) 输出的完整 TSV 中，脚本实际还包含，或以更底层形式保留：

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

这些字段：

- **仍然参与检测或判定**，例如 `title`、`content_type`、`size` 用于页面判断，`final_url` 用于跳转判断；
- **仍然存在于 CSV / JSONL 导出**，见 [`export_csv()`](reality_sni_probe_v2.sh:1320) 和 [`export_jsonl()`](reality_sni_probe_v2.sh:1338)；
- **不会出现在默认终端表格中**，默认终端只显示紧凑摘要列。

### 3. 默认终端里“已隐藏”与“摘要显示”的真实含义

当前终端表格中：

- **分项抖动数值不会单独成列**：`tcp_var`、`tls_var`、`ttfb_var` 会压缩进 `抖动T/TLS/F`；
- **页面列会做标签映射**：终端 `页面` 列不是直接输出原始 `page` 字段，而是由 [`print_table()`](reality_sni_probe_v2.sh:1281) 按当前规则映射为 `网页站 / 弱网页 / 接口/下载 / 错误页 / -`；
- **站点复核字段默认不进终端表格**：`issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip` 仅在导出中可见；
- **核心判定字段当前都会直接显示**：`TLS13`、`X25519`、`H2`、`ALPN`、`OCSP`、`证书`、`链`、`SAN`、`头部`、`WAF`、`跳转`、`多IP`、`稳定性`、`评分`、`结论` 都会直接显示。

### 4. `平均延迟` 的实际含义

这里要特别说明：在当前实现中，`平均延迟` 实际上直接等于 `avg_ttfb`，见 [`probe_one()`](reality_sni_probe_v2.sh:1084)。

也就是说：

- 它并不是 `TCP + TLS + TTFB` 的总和；
- 也不是独立新指标；
- 当前只是把 `avg_ttfb` 再以 `avg_latency` 名义输出一份。

因此阅读结果时，应把“平均延迟”理解为**平均首包时间**。

---

## 输出结果中每一项参数的详细解释

以下既包括默认表格列，也包括实际导出字段。

### `domain`

输入域名，经 [`normalize_domain()`](reality_sni_probe_v2.sh:112) 规整后的最终检测目标。

### `code`

首个有效样本的 HTTP 状态码。所谓“有效样本”，并不是严格选最快，而是 [`probe_one()`](reality_sni_probe_v2.sh:1055) 中**第一个能拿到三位状态码的样本**。

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

当前实现中等同于 `avg_ttfb`，只是换了字段名输出，见 [`probe_one()`](reality_sni_probe_v2.sh:1084)。

### `jitter`

完整抖动描述串，形如：

```txt
TCP:20ms/TLS:35ms/TTFB:120ms
```

如果三项抖动都不可得，则为 `-`。

需要补充说明两点：

- 当只拿到部分抖动值时，脚本仍会输出完整模板；未取到的项会保留底层哨兵值，例如 `TCP:999999ms/TLS:18ms/TTFB:65ms`；
- 默认终端表格不会原样显示这个字段，而是把 `999999` 视为“该项不可得”，在 `抖动T/TLS/F` 列中转写为 `-`。

### `tcp_jitter` / `tcp_var`

TCP 建连抖动，即多次采样中 `max_tcp - min_tcp`。

在导出时该字段会被格式化为字符串并追加 `ms`；若底层值为 `999999`，表示这一项抖动不可得，而不是“抖动真的高达 999999ms”。

### `tls_jitter` / `tls_var`

TLS 握手抖动，即多次采样中 `max_tls - min_tls`。

在导出时该字段会被格式化为字符串并追加 `ms`；若底层值为 `999999`，表示这一项抖动不可得，而不是“抖动真的高达 999999ms”。

### `ttfb_jitter` / `ttfb_var`

TTFB 抖动，即多次采样中 `max_ttfb - min_ttfb`。

在导出时该字段会被格式化为字符串并追加 `ms`；若底层值为 `999999`，表示这一项抖动不可得，而不是“抖动真的高达 999999ms”。

### `tls13`

由 [`check_tls13_from_sclient()`](reality_sni_probe_v2.sh:331) 判断，表示 `openssl s_client` 输出是否体现 `TLSv1.3`。

### `x25519`

由 [`check_x25519_from_sclient()`](reality_sni_probe_v2.sh:336) 判断，表示握手输出中是否出现 `X25519`。

### `h2`

HTTP/2 支持状态。可能来自：

- 首个有效样本本身已经显示 HTTP/2；
- 或 [`check_h2()`](reality_sni_probe_v2.sh:341) 二次验证得到。

### `alpn_result`

实际 ALPN 协商结果，来自 [`check_alpn_result_from_sclient()`](reality_sni_probe_v2.sh:265)。可能值为 `h2 / http/1.1 / 其他 / 未知`。

### `cert_ok`

证书是否成功获取。当前逻辑非常直接，见 [`check_cert_ok()`](reality_sni_probe_v2.sh:260)：

- 只要 PEM 非空，即 `正常`；
- 否则为 `失败`。

它不等于“证书链完整验证通过”，只是“有没有拿到证书”。

### `cert_chain_status`

证书链完整性状态，来自 [`check_cert_chain_status()`](reality_sni_probe_v2.sh:290)。可能值为：

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

OCSP Stapling 状态，来自 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.sh:315)。可能值为：

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

HTTP 响应头自然度，来自 [`check_header_naturalness()`](reality_sni_probe_v2.sh:424)，可能值为：

- `自然`
- `一般`
- `异常`

### `ip_consistency`

多 IP 一致性状态，来自 [`sample_ip_consistency()`](reality_sni_probe_v2.sh:469)，可能值为：

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

综合评分，来自 [`calc_sni_score()`](reality_sni_probe_v2.sh:778)。由于当前权重设计明显偏向安全性，因此 `score` 更适合用于**同一批候选中的相对排序**，而不是脱离上下文做绝对质量承诺。

### `result`

最终结论，来自 [`judge_sni()`](reality_sni_probe_v2.sh:705)：

- `推荐`
- `可用`
- `勉强`
- `不建议`

### `issuer`

证书颁发者，来自 [`get_issuer_short_from_pem()`](reality_sni_probe_v2.sh:542)，并经 [`shorten()`](reality_sni_probe_v2.sh:122) 截断为最多 60 个字符左右。

### `final_url`

经过 `curl -L` 跟随后得到的最终 URL，用于跳转分析，也便于复查站点实际落点。

### `title`

HTML 标题，来自 [`check_curl_once()`](reality_sni_probe_v2.sh:179) 对响应体中 `<title>` 的提取。

### `content_type`

响应内容类型，来自 `curl` 的 `%{content_type}`。

### `size`

响应下载大小，来自 `curl` 的 `%{size_download}`。

### `expiry_days`

证书剩余天数。当前**不会直接显示在默认终端或导出字段中**，但会参与 [`judge_sni()`](reality_sni_probe_v2.sh:705) 和 [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 的判定与加减分。

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
- `expiry_days`（未直接显示，但参与判定）
- `tls13`
- `x25519`
- `alpn_result`

原因：

- 证书拿不到，或者 SAN 不覆盖目标域名，脚本会直接判为 `不建议`；
- 证书剩余有效期过短，分数会明显被打低，且 `< 14` 天时直接 `不建议`；
- 没有 `TLS1.3`、`X25519`、`H2` 或发生跨站跳转，脚本会直接判为 `不建议`；
- 当前 [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 的最大加分也主要集中在这一层。

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

- [`judge_sni()`](reality_sni_probe_v2.sh:705) 要求 `推荐` 必须同时满足正常状态码、非错误页、非跨站跳转、支持 `H2`；
- [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 也会对这些项做中等幅度加减分；
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
- 三项平均值和三项抖动都在 [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 中分档加减分，用于拉开细粒度差距。

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

最终结论完全由 [`judge_sni()`](reality_sni_probe_v2.sh:705) 给出。下面按实际代码逻辑说明。

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

这里要注意：上述第二组条件由 [`is_reality_hard_fail()`](reality_sni_probe_v2.sh:685) 统一判断，属于当前脚本认定的 Reality 核心硬性淘汰逻辑。

### 2. 直接降级为 `勉强`

#### 命中疑似挑战页

```bash
waf == 疑似挑战
```

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

当前评分由 [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 计算，已经不是早期“偏性能主导”的思路，而是明确调整为：

1. **第一层：安全性主权重**；
2. **第二层：站点自然性次权重**；
3. **第三层：性能 / 稳定性补充细化**。

也就是说：一个站点即使速度很好，如果证书、SAN、TLS1.3、X25519 这些基础条件不好，也拿不到高分；相反，先满足身份与协议安全特征，后续页面自然性、可用性和性能才会继续拉开差距。

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

- `支持`：`+6`
- `未提供`：`-2`
- `异常`：`-4`
- `未知`：`0`

#### 10. `expiry_days` 分档

仅在能成功解析剩余天数时参与：

- `>= 365`：`+10`
- `>= 180`：`+8`
- `>= 120`：`+6`
- `>= 90`：`+4`
- `>= 60`：`+2`
- `>= 30`：`+0`
- `>= 14`：`-6`
- `>= 7`：`-14`
- `>= 0`：`-24`
- `< 0`：`-30`

### 第二层：站点自然性与可用性（次权重）

#### 1. `code`

- `200`：`+10`
- `301/302`：`+7`
- `403`：`+2`
- `404`：`-5`
- `405`：`-6`
- 其他：`-10`

#### 2. `page`

- `像正常网站`：`+12`
- `HTML但特征弱`：`+6`
- `非HTML响应`：`-3`
- `错误页`：`-9`
- `未知`：`0`

#### 3. `header_naturalness`

- `自然`：`+4`
- `一般`：`+1`
- `异常`：`-4`

#### 4. `redirect`

- `无跳转/同域`：`+7`
- `主子域自然跳转`：`+4`
- `跨站跳转`：`-10`
- `未知`：`0`

#### 5. `waf`

- `正常`：`+5`
- `疑似拦截`：`-6`
- `疑似挑战`：`-14`

#### 6. `ip_consistency`

- `一致`：`+5`
- `部分不一致`：`-4`
- `单IP/未知`：`0`

### 第三层：性能与稳定性（补充细化项）

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
- `<= 220ms`：`-2`
- `<= 300ms`：`-4`
- `> 300ms`：`-6`

#### 3. `avg_ttfb` 分档

- `<= 120ms`：`+9`
- `<= 180ms`：`+8`
- `<= 240ms`：`+7`
- `<= 320ms`：`+6`
- `<= 420ms`：`+5`
- `<= 550ms`：`+4`
- `<= 700ms`：`+3`
- `<= 900ms`：`+1`
- `<= 1200ms`：`-1`
- `<= 1600ms`：`-3`
- `> 1600ms`：`-6`

#### 4. `avg_tcp` 分档

- `<= 15ms`：`+6`
- `<= 25ms`：`+5`
- `<= 35ms`：`+4`
- `<= 50ms`：`+3`
- `<= 70ms`：`+2`
- `<= 100ms`：`+1`
- `<= 140ms`：`+0`
- `<= 200ms`：`-2`
- `<= 280ms`：`-4`
- `> 280ms`：`-6`

#### 5. `tcp_var` 分档

- `<= 5ms`：`+4`
- `<= 10ms`：`+3`
- `<= 20ms`：`+2`
- `<= 35ms`：`+1`
- `<= 55ms`：`+0`
- `<= 80ms`：`-2`
- `<= 120ms`：`-4`
- `> 120ms`：`-6`

#### 6. `tls_var` 分档

- `<= 5ms`：`+5`
- `<= 10ms`：`+4`
- `<= 18ms`：`+3`
- `<= 28ms`：`+2`
- `<= 40ms`：`+1`
- `<= 60ms`：`+0`
- `<= 90ms`：`-2`
- `<= 130ms`：`-4`
- `> 130ms`：`-6`

#### 7. `ttfb_var` 分档

- `<= 20ms`：`+6`
- `<= 40ms`：`+5`
- `<= 70ms`：`+4`
- `<= 110ms`：`+3`
- `<= 160ms`：`+2`
- `<= 230ms`：`+1`
- `<= 320ms`：`-1`
- `<= 450ms`：`-3`
- `<= 650ms`：`-5`
- `> 650ms`：`-7`

### 关于分数的阅读方式

- 分数**不是**标准化百分制，也没有被裁剪到 `0~100`；
- 某些很差的候选可以出现负分；
- 命中 [`is_reality_hard_fail()`](reality_sni_probe_v2.sh:685) 的记录，评分会直接输出为 `-9999`，用于明确标记 Reality 核心硬淘汰；
- 某些优质候选可以超过 `100`；
- 它更适合作为**同批候选之间的排序依据**。

---

## 排序与筛选说明

### 1. 先过滤，再排序

脚本会先调用 [`filter_results()`](reality_sni_probe_v2.sh:1354)：

- 如果使用 `--only-good`，仅保留 `推荐` 和 `可用`；
- 如果使用 `--min-score`，仅保留 `score >= 指定值`；
- 两者可以叠加使用。

### 2. 当前真实排序键

过滤完成后，脚本在 [`main()`](reality_sni_probe_v2.sh:1465) 中按以下键排序：

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

补充说明：默认终端 `页面` 列并不是直接输出原始 `page` 字段，而是由 [`print_table()`](reality_sni_probe_v2.sh:1281) 映射为 `网页站 / 弱网页 / 接口/下载 / 错误页 / -`；因此这里的示例列名与 CSV/JSONL 中的原始 `page` 值会刻意不同。

```txt
REALITY SNI 专业评估 v2
域名                       | 码   | TCP建连  | TLS握手  | TTFB     | 平均延迟 | 抖动T/TLS/F    | TLS13  | X25519 | H2   | ALPN     | OCSP   | 证书 | 链         | SAN      | 页面   | 头部 | WAF      | 跳转         | 多IP       | 稳定性 | 评分  | 结论
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
www.microsoft.com          | 200  | 24ms     | 31ms     | 118ms    | 118ms    | 5/8/24ms       | 支持   | 支持   | 支持 | h2       | 支持   | 正常 | 完整       | 精确匹配 | 网页站 | 自然 | 正常     | 无跳转/同域  | 一致       | 稳定   | 162   | 推荐
www.cloudflare.com         | 301  | 18ms     | 26ms     | 152ms    | 152ms    | 4/6/18ms       | 支持   | 支持   | 支持 | h2       | 支持   | 正常 | 完整       | 精确匹配 | 弱网页 | 自然 | 正常     | 主子域自然... | 一致       | 稳定   | 149   | 推荐
example.org                | 403  | 90ms     | 130ms    | 680ms    | 680ms    | 22/35/180ms    | 支持   | 支持   | 支持 | http/1.1 | 未提供 | 正常 | 完整       | 通配匹配 | 错误页 | 一般 | 疑似拦截 | 无跳转/同域  | 单IP/未知  | 一般   | 74    | 可用
bad.example                | -    | -        | -        | -        | -        | -              | 不支持 | 不支持 | 不支持 | 未知      | 未知   | 失败 | 未知/失败 | 失败     | -      | 一般 | 正常     | 未知         | 单IP/未知  | 波动大 | -9999 | 不建议
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
```

阅读建议：

1. 先看 `结论`，快速分组；
2. 再看 `SAN`、`TLS13`、`X25519`、`H2`、`ALPN`、`链`，确认 Reality 核心能力与证书质量；
3. 再看 `评分`，在同档位内做优先级排序；
4. 然后看 `页面`、`头部`、`WAF`、`跳转`、`多IP`，确认站点自然性与节点一致性；
5. 如果 `评分 = -9999`，基本可直接视为命中了 Reality 核心硬淘汰；
6. 最后结合 `TCP建连`、`TLS握手`、`TTFB` 与 `抖动T/TLS/F` 做性能复核；
7. 如需复查站点细节，请查看导出的 `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip`。

---

## CSV / JSONL 导出字段说明

当前导出字段由 [`export_csv()`](reality_sni_probe_v2.sh:1320) 与 [`export_jsonl()`](reality_sni_probe_v2.sh:1338) 决定，顺序如下：

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

需要注意：

- 导出字段里**没有** `expiry_days`；
- 但 `expiry_days` 已经参与结论与评分，只是当前未单独输出；
- `tcp_jitter` / `tls_jitter` / `ttfb_jitter` 在导出中会被格式化为带 `ms` 后缀的字符串；
- 若底层抖动值为 `999999`，导出会如实写成 `999999ms`，它表示“该项抖动不可得”的内部哨兵值，而不是实际测得的超大抖动；
- 默认终端表格不会输出 `issuer`、`final_url`、`title`、`content_type`、`size`、`remote_ip`；
- 默认终端表格中的 `页面` 列是摘要标签，而导出中的 `page` 保留原始分类值；
- 导出中的 `alpn_result`、`cert_chain_status`、`ocsp_stapling`、`header_naturalness`、`ip_consistency` 与终端表格中的 `ALPN / 链 / OCSP / 头部 / 多IP` 一一对应。

### CSV 表头

```csv
"domain","code","avg_tcp","avg_tls","avg_ttfb","avg_latency","jitter","tcp_jitter","tls_jitter","ttfb_jitter","tls13","x25519","h2","alpn_result","cert_ok","cert_chain_status","san_level","ocsp_stapling","page","header_naturalness","waf","redirect","ip_consistency","stability","score","result","issuer","final_url","title","content_type","size","remote_ip"
```

### JSONL 单行结构示意

```json
{"domain":"www.microsoft.com","code":"200","avg_tcp":"24ms","avg_tls":"31ms","avg_ttfb":"118ms","avg_latency":"118ms","jitter":"TCP:5ms/TLS:8ms/TTFB:24ms","tcp_jitter":"5ms","tls_jitter":"8ms","ttfb_jitter":"24ms","tls13":"支持","x25519":"支持","h2":"支持","alpn_result":"h2","cert_ok":"正常","cert_chain_status":"完整","san_level":"精确匹配","ocsp_stapling":"支持","page":"像正常网站","header_naturalness":"自然","waf":"正常","redirect":"无跳转/同域","ip_consistency":"一致","stability":"稳定","score":"162","result":"推荐","issuer":"C=US, O=Microsoft Corporation, CN=Microsoft Azure RSA TLS Issuing CA 03","final_url":"https://www.microsoft.com/","title":"Microsoft – AI, Cloud, Productivity, Computing, Gaming & Apps","content_type":"text/html; charset=utf-8","size":"65842","remote_ip":"23.45.119.216"}
```

---

## 局限性

当前版本依然有一些明确局限：

1. [`check_cert_ok()`](reality_sni_probe_v2.sh:260) 只判断“有没有拿到 PEM”，不等于完整证书链校验通过；
2. [`check_cert_chain_status()`](reality_sni_probe_v2.sh:290) 与 [`check_ocsp_stapling_from_sclient()`](reality_sni_probe_v2.sh:315) 都基于 `openssl s_client` 文本输出，不是结构化 PKI / OCSP 验证器；
3. [`check_tls13_from_sclient()`](reality_sni_probe_v2.sh:331) 和 [`check_x25519_from_sclient()`](reality_sni_probe_v2.sh:336) 是基于文本匹配，不是结构化 TLS 指纹分析；
4. 页面 / 头部 / WAF / 跳转判断都属于启发式规则，不代表完整浏览器视角；
5. `avg_latency` 当前只是 `avg_ttfb` 的别名，命名更偏展示用途；
6. `expiry_days` 已参与判断与评分，但当前不在默认终端和导出字段中显示；
7. 多 IP 一致性抽样当前只检查最多 3 个 IPv4 A 记录，不覆盖 AAAA，也不保证穷尽所有边缘节点；
8. 评分体系虽然已经从“速度优先”转向“安全性主权重”，但仍然只是启发式排序工具，不是绝对真理；
9. 结果高度依赖你本机的网络出口、DNS、地区与链路状态；
10. 终端表格虽然已做中英文宽度修复，但不同终端字体、East Asian Width 策略下仍可能存在轻微视觉偏差；
11. 默认终端会把抖动哨兵值 `999999` 摘要显示为 `-`，而 CSV/JSONL 会保留 `999999ms`；两者语义一致，都是“该项抖动不可得”；
12. 缺少 `curl` / `openssl` / 合适 locale 时，脚本会尽量退化运行，但结果解释必须更保守。

---

## FAQ

### 1. 为什么某些站点速度很好，分数却不高？

因为当前 [`calc_sni_score()`](reality_sni_probe_v2.sh:778) 的主权重已经放在证书、SAN、`TLS1.3`、`X25519`、`ALPN`、证书链、`OCSP`、有效期这些安全与身份特征上。速度快只能在第三层补充分中加分，无法弥补根本性的证书或协议短板。

### 2. 为什么 `通配匹配` 不再直接判死？

因为当前 [`judge_sni()`](reality_sni_probe_v2.sh:705) 已把 `通配匹配` 调整为“次优可用”。它不能拿到和 `精确匹配` 一样高的权重，但如果其他条件好，仍可得到 `可用`；如果页面或稳定性较弱，则多半回落为 `勉强`。

### 3. 为什么 `403` 有时还是 `可用` 或 `勉强`？

因为当前 [`judge_sni()`](reality_sni_probe_v2.sh:705) 对 `403` 的处理是：只要没有提前命中证书 / SAN / 到期 / Reality 核心硬性淘汰条件，`403` 仍可能落入 `可用` 或 `勉强`。这反映的是“可作为候选参考”，不等于“用户访问体验优秀”。

### 4. 为什么默认终端里现在能看到 `ALPN`、`OCSP`、`链`、`头部`、`多IP`？

因为当前 [`print_table()`](reality_sni_probe_v2.sh:1281) 的表头已经扩展，新增这些判定列，同时通过 [`table_display_width()`](reality_sni_probe_v2.sh:1189) 与 [`table_fit_text()`](reality_sni_probe_v2.sh:1208) 修复了中英文混排时的表格对齐问题。

### 5. 为什么“平均延迟”和 `TTFB` 一样？

因为当前实现中 [`probe_one()`](reality_sni_probe_v2.sh:1084) 直接把 `avg_ttfb` 复用为 `avg_latency` 输出，它目前就是展示别名，不是新的独立指标。

### 6. 为什么在某些环境下不再出现 `ignored null byte in input`？

因为当前版本会在两条链路上主动剥离 NUL 字节：

- `curl` 采样阶段会在读取响应体和响应头时做过滤，见 [`check_curl_once()`](reality_sni_probe_v2.sh:179)；
- `openssl s_client` 的原始输出也会经过 [`strip_nul_bytes()`](reality_sni_probe_v2.sh:87) 清洗，见 [`fetch_tls_bundle()`](reality_sni_probe_v2.sh:232)。

这能减少把异常二进制内容装入 shell 变量时触发的告警，但并不改变站点真实返回内容本身。

### 7. 为什么在某些环境下中文列宽或输出看起来更正常了？

因为当前版本增加了 [`ensure_clean_utf8_env()`](reality_sni_probe_v2.sh:28) 的 UTF-8 bootstrap，并在 [`table_display_width()`](reality_sni_probe_v2.sh:1189) / [`table_fit_text()`](reality_sni_probe_v2.sh:1208) 中按 ASCII 1 列、非 ASCII 2 列做宽度估算，减少中文显示错位。
