#!/usr/bin/env bash
UTF8_BOOTSTRAP_DONE="${UTF8_BOOTSTRAP_DONE:-0}"

select_utf8_locale() {
  local candidates=()
  local candidate

  case "${LC_CTYPE:-}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) candidates+=("$LC_CTYPE") ;;
  esac
  case "${LANG:-}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) candidates+=("$LANG") ;;
  esac

  candidates+=("C.UTF-8" "C.utf8" "en_US.UTF-8" "en_US.utf8" "UTF-8")

  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if locale -a 2>/dev/null | grep -Fxiq "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "C.UTF-8"
}

ensure_clean_utf8_env() {
  local selected_locale need_reexec=0

  selected_locale="$(select_utf8_locale)"

  if [ "${LC_ALL+x}" = x ]; then
    need_reexec=1
  fi

  case "${LC_CTYPE:-}" in
    "$selected_locale") ;;
    *) need_reexec=1 ;;
  esac

  case "${LANG:-}" in
    "$selected_locale") ;;
    *) need_reexec=1 ;;
  esac

  if [ "$need_reexec" -eq 1 ] && [ "$UTF8_BOOTSTRAP_DONE" != "1" ]; then
    exec env -u LC_ALL LANG="$selected_locale" LC_CTYPE="$selected_locale" UTF8_BOOTSTRAP_DONE=1 bash "$0" "$@"
  fi

  unset LC_ALL
  export LANG="$selected_locale"
  export LC_CTYPE="$selected_locale"
  export UTF8_BOOTSTRAP_DONE=1
}

ensure_clean_utf8_env "$@"
set -u

# =========================================================
# REALITY SNI probe - pro v2.3
# Focus: evaluate whether a domain is suitable as REALITY SNI
# =========================================================

JOBS="${JOBS:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10}"
SAMPLES="${SAMPLES:-3}"
OUT_CSV="${OUT_CSV:-}"
OUT_JSON="${OUT_JSON:-}"
ONLY_GOOD="${ONLY_GOOD:-0}"
MIN_SCORE="${MIN_SCORE:-}"
TMP_ROOT="${TMP_ROOT:-}"
JITTER_MS_MAX="${JITTER_MS_MAX:-0}"
ASN_ENABLED="${ASN_ENABLED:-1}"
ASN_TIMEOUT_SEC="${ASN_TIMEOUT_SEC:-5}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

curl_supports_http2() {
  have_cmd curl && curl --version 2>/dev/null | grep -Eiq '(^|[[:space:]])HTTP2([[:space:]]|$)'
}

warn_dependencies() {
  if ! have_cmd curl; then
    echo "警告: 缺少 curl，HTTP 采样、H2、页面/WAF/跳转判断会退化。" >&2
  elif ! curl_supports_http2; then
    echo "警告: 当前 curl 未启用 HTTP/2，H2 会尽量用 OpenSSL ALPN 兜底，无法确认时标记为 未知。" >&2
  fi

  if ! have_cmd openssl; then
    echo "警告: 缺少 openssl，TLS/证书/SAN/ALPN/OCSP 检测会退化。" >&2
  fi

  if [ "${ASN_ENABLED:-1}" = "1" ] && ! have_cmd whois; then
    echo "警告: 缺少 whois，ASN 查询会退化为 未知；如不需要 ASN 可使用 --no-asn。" >&2
  fi

  if ! have_cmd timeout && ! have_cmd gtimeout; then
    echo "警告: 缺少 timeout/gtimeout，openssl/whois 阶段无法被外层超时保护。" >&2
  fi

  if ! have_cmd getent && ! have_cmd dig && ! have_cmd nslookup; then
    echo "警告: 缺少 getent/dig/nslookup，多 IP 一致性检测会退化为 单IP/未知。" >&2
  fi
}

safe_timeout() {
  local secs="$1"
  shift

  if have_cmd timeout; then
    timeout "$secs" "$@"
  elif have_cmd gtimeout; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

strip_nul_bytes() {
  tr -d '\000'
}

usage() {
  cat <<USAGE
用法:
  $0 domain1.com domain2.com ...
  $0 -f domains.txt [选项]

选项:
  -f FILE         域名文件
  -o FILE         导出 CSV
  --json FILE     导出 JSONL
  -j NUM          并发数，默认 1
  --timeout NUM   单次请求超时，默认 10
  --samples NUM   采样次数，默认 3
  --only-good     仅输出 推荐/可用
  --min-score N   仅输出分数 >= N
  --jitter NUM    worker 启动随机延迟上限毫秒，默认 0 (禁用)
  --no-asn        禁用 ASN 查询（默认启用，需 whois 或网络）
  -h, --help      帮助
USAGE
}

trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

normalize_domain() {
  local x="$1"
  x="$(echo "$x" | trim)"
  x="${x#http://}"
  x="${x#https://}"
  x="${x%%/*}"
  x="${x%%:*}"
  echo "$x" | tr 'A-Z' 'a-z'
}

shorten() {
  local s="${1:-}"
  local n="${2:-60}"
  if [ "${#s}" -le "$n" ]; then echo "$s"; else echo "${s:0:$((n-3))}..."; fi
}

to_ms() {
  local sec="${1:-}"
  awk -v s="$sec" 'BEGIN{
    if (s ~ /^[0-9]+(\.[0-9]+)?$/) printf "%.0f", s*1000;
  }'
}

num_or_big() {
  local s="${1:-}"
  s="${s/ms/}"
  if [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf "%.0f\n" "$s"
  else
    echo "999999"
  fi
}

csv_escape() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

median3() {
  printf '%s\n' "$@" | sort -n | awk 'NR==2{print $1}'
}

avg_nums() {
  awk '{s+=$1;n++} END{ if(n>0) printf "%.0f", s/n; else print "" }'
}

ms_or_dash() {
  local v="${1:-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -lt 999999 ]; then
    printf '%sms' "$v"
  else
    printf '%s' '-'
  fi
}

jitter_token() {
  local label="$1"
  local v="${2:-}"
  printf '%s:%s' "$label" "$(ms_or_dash "$v")"
}

date_to_epoch() {
  local ds="$1"
  local epoch

  [ -n "$ds" ] || return 1

  if epoch="$(LC_TIME=C date -d "$ds" +%s 2>/dev/null)"; then
    printf '%s\n' "$epoch"
    return 0
  fi

  if epoch="$(LC_TIME=C date -j -f "%b %e %T %Y %Z" "$ds" +%s 2>/dev/null)"; then
    printf '%s\n' "$epoch"
    return 0
  fi

  if have_cmd python3; then
    python3 - "$ds" <<'PY' 2>/dev/null
import calendar
import datetime as _dt
import sys

value = sys.argv[1]
normalized = " ".join(value.split())
for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
    try:
        dt = _dt.datetime.strptime(normalized, fmt)
        print(calendar.timegm(dt.timetuple()))
        sys.exit(0)
    except ValueError:
        pass
sys.exit(1)
PY
    return $?
  fi

  return 1
}

# ============================================================
# v2.1 新增: ASN 检测
# ============================================================

# 查询 IP 的 ASN 信息
# 返回: "asn|asn_name|asn_type"
# asn_type: CDN / Hosting / ISP / Edu / 未知
lookup_asn() {
  local ip="$1"
  local whois_out asn="-" name="-" type="未知"
  local cymru_line upper

  [ "$ASN_ENABLED" -ne 1 ] && { echo "-|-|未知"; return; }
  [ -z "$ip" ] || [ "$ip" = "-" ] && { echo "-|-|未知"; return; }

  # IPv4 正则检查, 先排除无效输入
  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "-|-|未知"
    return
  fi

  if have_cmd whois; then
    whois_out="$(safe_timeout "$ASN_TIMEOUT_SEC" whois -h whois.cymru.com " -v $ip" 2>/dev/null | strip_nul_bytes)"
    # 取第一条非表头行, 字段形如: AS | IP | BGP Prefix | CC | Registry | Allocated | AS Name
    cymru_line="$(echo "$whois_out" | awk -F'|' 'NR>1 && NF>=7 {print; exit}')"
    if [ -n "$cymru_line" ]; then
      asn="$(echo "$cymru_line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}')"
      name="$(echo "$cymru_line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$7); print $7}')"
    fi
  fi

  # ASN 分类: 基于名字做启发式 (快速离线方案)
  upper="$(printf '%s' "$name" | tr 'a-z' 'A-Z')"
  case "$upper" in
    *CLOUDFLARE*|*FASTLY*|*AKAMAI*|*CDNETWORKS*|*CLOUDFRONT*|*CDN77*|*LIMELIGHT*|*STACKPATH*|*BUNNY*|*EDGE*|*AZURE*CDN*)
      type="CDN" ;;
    *GOOGLE*|*AMAZON*|*AWS*|*MICROSOFT*|*FACEBOOK*|*META*|*APPLE*|*NETFLIX*|*TWITTER*|*ORACLE*|*ALIBABA*|*TENCENT*)
      type="CDN" ;;
    *DIGITALOCEAN*|*LINODE*|*VULTR*|*OVH*|*HETZNER*|*CONTABO*|*SCALEWAY*|*LEASEWEB*|*CHOOPA*|*HOSTING*|*SERVER*|*DATACENTER*)
      type="Hosting" ;;
    *UNIVERSITY*|*UNIV*|*COLLEGE*|*SCHOOL*|*EDU*|*ACADEMIC*)
      type="Edu" ;;
    *TELECOM*|*COMCAST*|*VERIZON*|*AT\&T*|*DEUTSCHE*|*CHINA*|*KOREA*|*BROADBAND*|*ISP*|*COMMUNICATIONS*)
      type="ISP" ;;
    -|"") type="未知" ;;
    *) type="未知" ;;
  esac

  echo "${asn:--}|${name:--}|${type:-未知}"
}

# ============================================================
# v2.3 新增: CDN 检测
# ============================================================

# 解析域名的 CNAME 链, 看是否指向已知 CDN 服务商
# 返回: 已知CDN名 / 空 (无 CNAME 或非 CDN)
resolve_cname_chain() {
  local domain="$1"
  local chain="" cname_line cname

  # 用 dig 取 CNAME 链 (最多追 3 跳)
  if have_cmd dig; then
    chain="$(dig +short +time=2 +tries=1 "$domain" CNAME 2>/dev/null | tr -d '\r' | head -n 5)"
    # 如果 CNAME 没直接命中, 尝试用 +trace 或递归一次
    if [ -z "$chain" ]; then
      chain="$(dig +short +time=2 +tries=1 "$domain" 2>/dev/null | grep -v '^[0-9]' | tr -d '\r' | head -n 5)"
    fi
  elif have_cmd host; then
    chain="$(host -t CNAME "$domain" 2>/dev/null | grep 'is an alias for' | awk '{print $NF}' | sed 's/\.$//' | head -n 5)"
  fi

  printf '%s\n' "$chain"
}

# 检测域名是否套了第三方 CDN
# 返回: "套CDN|具体CDN名" / "可能套CDN|-" / "未套CDN|-" / "未知|-"
# 输入:
#   $1 domain - 输入域名
#   $2 headers - 已抓到的响应头(由 check_curl_once 提供)
detect_cdn() {
  local domain="$1"
  local headers="$2"
  local cname_chain lc_headers lc_cname cdn_name="" hits=0 weak_hits=0

  lc_headers="$(printf '%s' "$headers" | tr 'A-Z' 'a-z')"

  # ===== 第一层: 响应头精确匹配 (最可靠) =====
  if echo "$lc_headers" | grep -Eq 'cf-ray:|cf-cache-status:|server: cloudflare'; then
    cdn_name="Cloudflare"; hits=$((hits + 2))
  fi
  if echo "$lc_headers" | grep -Eq 'x-amz-cf-id:|x-amz-cf-pop:|via:[^,]*cloudfront\.net'; then
    cdn_name="${cdn_name:+$cdn_name+}CloudFront"; hits=$((hits + 2))
  fi
  if echo "$lc_headers" | grep -Eq 'x-akamai-|server: *akamaighost|akamai-grn:'; then
    cdn_name="${cdn_name:+$cdn_name+}Akamai"; hits=$((hits + 2))
  fi
  if echo "$lc_headers" | grep -Eq 'x-fastly-|x-served-by: *cache-|via:[^,]*varnish'; then
    cdn_name="${cdn_name:+$cdn_name+}Fastly"; hits=$((hits + 2))
  fi
  if echo "$lc_headers" | grep -Eq 'x-cdn:|x-edge-|x-tencent-|x-cos-'; then
    cdn_name="${cdn_name:+$cdn_name+}通用CDN"; hits=$((hits + 1))
  fi

  # ===== 第二层: CNAME 链匹配 =====
  cname_chain="$(resolve_cname_chain "$domain")"
  lc_cname="$(printf '%s' "$cname_chain" | tr 'A-Z' 'a-z')"

  if [ -n "$lc_cname" ]; then
    if echo "$lc_cname" | grep -Eq 'cloudfront\.net|cloudflare\.net|cdn\.cloudflare|akamai(edge|hd|tech)?\.net|akamai\.net|fastly\.net|fastlylb\.net|edgekey\.net|edgesuite\.net|cdn77\.|stackpathdns|impervadns|incapdns'; then
      [ -z "$cdn_name" ] && cdn_name="$(echo "$cname_chain" | head -n1)"
      hits=$((hits + 2))
    fi
  fi

  # ===== 第三层: 通用缓存头 (弱信号) =====
  if echo "$lc_headers" | grep -Eq '^age:|x-cache:|x-served-by:|cf-cache-status:|x-cache-hits:'; then
    weak_hits=$((weak_hits + 1))
  fi

  # ===== 综合判定 =====
  if [ "$hits" -ge 2 ]; then
    echo "套CDN|${cdn_name:-未识别}"
  elif [ "$hits" -ge 1 ] || [ "$weak_hits" -ge 1 ]; then
    echo "可能套CDN|${cdn_name:-未识别}"
  elif [ -z "$headers" ] || [ "$headers" = "-" ]; then
    echo "未知|-"
  else
    echo "未套CDN|-"
  fi
}

rank_result() {
  case "$1" in
    推荐) echo 4 ;;
    可用) echo 3 ;;
    勉强) echo 2 ;;
    不建议) echo 1 ;;
    *) echo 0 ;;
  esac
}

check_curl_once() {
  local domain="$1"
  local sample_id="$2"
  local body_file="$TMP_ROOT/body_${$}_${sample_id}.txt"
  local header_file="$TMP_ROOT/header_${$}_${sample_id}.txt"
  local max_time="${TIMEOUT_SEC:-10}"
  local data t_connect t_appconnect t_starttransfer http_ver code ctype size eff remote_ip

  if ! have_cmd curl; then
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "缺失" "缺失" "缺失" "" "缺失" "缺失" "0" "-" "-" "-" "-"
    return
  fi

  data="$(curl -L -D "$header_file" -o "$body_file" -s \
    -w $'%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{http_version}\t%{response_code}\t%{content_type}\t%{size_download}\t%{url_effective}\t%{remote_ip}' \
    --connect-timeout 4 --max-time "$max_time" \
    "https://${domain}" 2>/dev/null)"

  IFS=$'\t' read -r t_connect t_appconnect t_starttransfer http_ver code ctype size eff remote_ip <<< "$data"

  local tcp_ms tls_ms ttfb_ms body headers title_line title
  if [[ "$t_connect" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$t_connect" != "0.000000" ]; then
    tcp_ms="$(to_ms "$t_connect")ms"
  else
    tcp_ms="失败"
  fi

  if [[ "$t_connect" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$t_appconnect" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$t_appconnect" != "0.000000" ]; then
    tls_ms="$(awk -v a="$t_appconnect" -v b="$t_connect" 'BEGIN{printf "%.0f", (a-b)*1000}')"
    [[ "$tls_ms" =~ ^- ]] && tls_ms="失败" || tls_ms="${tls_ms}ms"
  else
    tls_ms="失败"
  fi

  if [[ "$t_starttransfer" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$t_starttransfer" != "0.000000" ]; then
    ttfb_ms="$(to_ms "$t_starttransfer")ms"
  else
    ttfb_ms="失败"
  fi

  # curl 超时、DNS/TLS 失败或被远端提前断开时，-o/-D 目标文件可能不会生成。
  # 不能直接用输入重定向读取不存在的文件，否则重定向错误会在 2>/dev/null 生效前打到终端。
  if [ -f "$body_file" ]; then
    body="$(tr -d '\000' < "$body_file" 2>/dev/null || true)"
  else
    body=""
  fi

  if [ -f "$header_file" ]; then
    headers="$(tr -d '\000' < "$header_file" 2>/dev/null || true)"
  else
    headers=""
  fi

  rm -f "$body_file" "$header_file" 2>/dev/null || true

  title_line="$(echo "$body" | tr '\n' ' ' | sed -n 's/.*<title[^>]*>\(.*\)<\/title>.*/\1/p' | head -n1)"
  title="$(echo "$title_line" | sed 's/[[:space:]]\+/ /g' | cut -c1-100)"
  headers="$(printf '%s' "$headers" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-600)"

  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$tcp_ms" "$tls_ms" "$ttfb_ms" "$http_ver" "$code" "${ctype:--}" "${size:-0}" "${eff:--}" "${title:--}" "${headers:--}" "${remote_ip:--}"
}

fetch_tls_bundle() {
  local domain="$1"
  local max_time="${TIMEOUT_SEC:-10}"
  local sclient certpem

  if ! have_cmd openssl; then
    echo "NO_OPENSSL"
    return
  fi

  sclient="$(safe_timeout "$max_time" openssl s_client -connect "${domain}:443" -servername "$domain" -showcerts -status -alpn 'h2,http/1.1' < /dev/null 2>&1 | strip_nul_bytes)"
  certpem="$(echo "$sclient" | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' | sed -n '1,/-----END CERTIFICATE-----/p')"

  {
    echo "----SCLIENT----"
    echo "$sclient"
    echo "----CERTPEM----"
    echo "$certpem"
  }
}

extract_sclient() { awk '/^----SCLIENT----$/{flag=1;next}/^----CERTPEM----$/{flag=0}flag'; }
extract_certpem() { awk '/^----CERTPEM----$/{flag=1;next}flag'; }

cert_text_from_pem() {
  local pem="$1"
  [ -n "$pem" ] && echo "$pem" | openssl x509 -text -noout 2>/dev/null
}

check_cert_ok() {
  local pem="$1"
  [ -n "$pem" ] && echo "正常" || echo "失败"
}

check_alpn_result_from_sclient() {
  local sclient="$1"
  local alpn

  [ -z "$sclient" ] && { echo "未知"; return; }

  alpn="$(echo "$sclient" | sed -n 's/^ALPN protocol: *//p' | head -n1 | trim)"
  [ -z "$alpn" ] && alpn="$(echo "$sclient" | sed -n 's/^.*ALPN, server accepted to use //p' | head -n1 | trim)"

  case "$alpn" in
    h2)
      echo "h2"
      ;;
    http/1.1)
      echo "http/1.1"
      ;;
    ""|none|NONE|"no application protocol"|"No ALPN negotiated")
      echo "未知"
      ;;
    *)
      echo "其他"
      ;;
  esac
}

check_cert_chain_status() {
  local sclient="$1"

  [ -z "$sclient" ] && { echo "未知/失败"; return; }

  if echo "$sclient" | grep -Eiq 'no peer certificate available|handshake failure|connection refused|connect:errno=|Connection timed out|Name or service not known'; then
    echo "未知/失败"
  elif echo "$sclient" | grep -Eq 'Verify return code: 0 \(ok\)'; then
    echo "完整"
  elif echo "$sclient" | grep -Eiq 'unable to get local issuer certificate|unable to verify the first certificate|self-signed certificate|self signed certificate|certificate verify failed|verify error|certificate chain too long'; then
    echo "不完整"
  else
    echo "未知/失败"
  fi
}

get_cert_fingerprint_from_pem() {
  local pem="$1"
  local fp

  [ -z "$pem" ] && { echo "-"; return; }
  fp="$(echo "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g')"
  [ -n "$fp" ] && echo "$fp" || echo "-"
}

check_ocsp_stapling_from_sclient() {
  local sclient="$1"

  [ -z "$sclient" ] && { echo "未知"; return; }

  if echo "$sclient" | grep -Eq 'OCSP response: no response sent|no response sent'; then
    echo "未提供"
  elif echo "$sclient" | grep -Eq 'OCSP Response Status: *successful'; then
    echo "支持"
  elif echo "$sclient" | grep -Eq 'OCSP Response Status:'; then
    echo "异常"
  else
    echo "未知"
  fi
}

check_tls13_from_sclient() {
  local sclient="$1"
  echo "$sclient" | grep -Eq 'Protocol *: *TLSv1\.3|New, TLSv1\.3' && echo "支持" || echo "不支持"
}

check_x25519_from_sclient() {
  local sclient="$1"
  echo "$sclient" | grep -Eiq 'Server Temp Key: *X25519|group: *X25519|X25519' && echo "支持" || echo "不支持"
}

check_h2() {
  local domain="$1"
  local max_time="${TIMEOUT_SEC:-10}"
  local data ver code

  if ! have_cmd curl; then
    echo "未知"
    return
  fi

  if ! curl_supports_http2; then
    echo "未知"
    return
  fi

  data="$(curl -I -L -o /dev/null -s --http2 \
    -w "%{http_version}|%{response_code}" \
    --connect-timeout 5 --max-time "$max_time" \
    "https://${domain}" 2>/dev/null)"
  ver="$(echo "$data" | cut -d'|' -f1)"
  code="$(echo "$data" | cut -d'|' -f2)"

  case "$ver" in
    2|2.0)
      [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && { echo "支持"; return; }
      ;;
  esac

  data="$(curl -L -o /dev/null -s --http2 \
    -w "%{http_version}|%{response_code}" \
    --connect-timeout 5 --max-time "$max_time" \
    "https://${domain}" 2>/dev/null)"
  ver="$(echo "$data" | cut -d'|' -f1)"
  code="$(echo "$data" | cut -d'|' -f2)"

  case "$ver" in
    2|2.0)
      [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && echo "支持" || echo "不支持"
      ;;
    *)
      echo "不支持"
      ;;
  esac
}

check_h2_on_ip() {
  local domain="$1"
  local ip="$2"
  local max_time="${TIMEOUT_SEC:-10}"
  local data ver code

  if ! have_cmd curl; then
    echo "未知"
    return
  fi

  if ! curl_supports_http2; then
    echo "未知"
    return
  fi

  data="$(curl -I -L -o /dev/null -s --http2 \
    --resolve "${domain}:443:${ip}" \
    -w "%{http_version}|%{response_code}" \
    --connect-timeout 5 --max-time "$max_time" \
    "https://${domain}" 2>/dev/null)"
  ver="$(echo "$data" | cut -d'|' -f1)"
  code="$(echo "$data" | cut -d'|' -f2)"

  case "$ver" in
    2|2.0)
      [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && { echo "支持"; return; }
      ;;
  esac

  data="$(curl -L -o /dev/null -s --http2 \
    --resolve "${domain}:443:${ip}" \
    -w "%{http_version}|%{response_code}" \
    --connect-timeout 5 --max-time "$max_time" \
    "https://${domain}" 2>/dev/null)"
  ver="$(echo "$data" | cut -d'|' -f1)"
  code="$(echo "$data" | cut -d'|' -f2)"

  case "$ver" in
    2|2.0)
      [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && echo "支持" || echo "不支持"
      ;;
    *)
      echo "不支持"
      ;;
  esac
}

check_header_naturalness() {
  local code="$1"
  local ctype="$2"
  local headers="$3"
  local score=0
  local lc

  [ -z "$headers" ] || [ "$headers" = "-" ] && { echo "一般"; return; }
  lc="$(printf '%s %s %s\n' "$code" "$ctype" "$headers" | tr 'A-Z' 'a-z')"

  echo "$lc" | grep -Eq 'server:' && score=$((score + 1))
  echo "$lc" | grep -Eq 'content-type:' && score=$((score + 1))
  echo "$lc" | grep -Eq 'cache-control:' && score=$((score + 1))
  echo "$lc" | grep -Eq 'strict-transport-security:' && score=$((score + 1))
  echo "$lc" | grep -Eq 'content-encoding:' && score=$((score + 1))
  echo "$lc" | grep -Eq 'alt-svc:' && score=$((score + 1))
  echo "$lc" | grep -Eiq 'cf-ray|x-sucuri|x-akamai|x-perimeterx|captcha|challenge|attention required|deny' && score=$((score - 2))
  [[ "$code" =~ ^(200|301|302|403)$ ]] && score=$((score + 1))
  echo "$ctype" | grep -Eiq 'text/html|application/xhtml|application/json|text/plain' && score=$((score + 1))

  if [ "$score" -ge 5 ]; then
    echo "自然"
  elif [ "$score" -ge 2 ]; then
    echo "一般"
  else
    echo "异常"
  fi
}

resolve_domain_ips() {
  local domain="$1"
  local limit="${2:-3}"
  local ips=""

  if have_cmd getent; then
    ips="$(getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/ {print $1}' | awk '!seen[$0]++' | head -n "$limit")"
  elif have_cmd dig; then
    ips="$(dig +short "$domain" A 2>/dev/null | awk '/^[0-9.]+$/ {print $1}' | awk '!seen[$0]++' | head -n "$limit")"
  elif have_cmd nslookup; then
    ips="$(nslookup "$domain" 2>/dev/null | awk 'BEGIN{found=0} /^Name:/{found=1; next} found && /^Address: /{print $2} found && /^Addresses: /{for(i=2;i<=NF;i++) print $i; next} found && /^[[:space:]]+[0-9.]+$/{gsub(/^[[:space:]]+/, "", $0); print $0}' | awk '!seen[$0]++' | head -n "$limit")"
  fi

  printf '%s\n' "$ips" | awk 'NF'
}

sample_ip_consistency() {
  local domain="$1"
  local primary_tls13="$2"
  local primary_x25519="$3"
  local primary_h2="$4"
  local primary_san_level="$5"
  local primary_cert_fp="$6"
  local max_time="${TIMEOUT_SEC:-10}"
  local ips ip_count=0 checked=0 mismatch=0 ip bundle cert_pem cert_text tls13_ip x25519_ip alpn_ip h2_ip san_ip cert_fp_ip

  if ! have_cmd openssl; then
    echo "单IP/未知"
    return
  fi

  ips="$(resolve_domain_ips "$domain" 3)"
  [ -z "$ips" ] && { echo "单IP/未知"; return; }

  while IFS= read -r ip; do
    [ -n "$ip" ] && ip_count=$((ip_count + 1))
  done <<< "$ips"

  [ "$ip_count" -le 1 ] && { echo "单IP/未知"; return; }

  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    bundle="$(safe_timeout "$max_time" openssl s_client -connect "${ip}:443" -servername "$domain" -showcerts -alpn 'h2,http/1.1' < /dev/null 2>&1 | strip_nul_bytes)"
    cert_pem="$(echo "$bundle" | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' | sed -n '1,/-----END CERTIFICATE-----/p')"
    cert_text="$(cert_text_from_pem "$cert_pem")"
    tls13_ip="$(check_tls13_from_sclient "$bundle")"
    x25519_ip="$(check_x25519_from_sclient "$bundle")"
    alpn_ip="$(check_alpn_result_from_sclient "$bundle")"
    h2_ip="$(check_h2_on_ip "$domain" "$ip")"
    [ "$h2_ip" = "未知" ] && [ "$alpn_ip" = "h2" ] && h2_ip="支持"
    san_ip="$(check_san_level "$domain" "$cert_text")"
    cert_fp_ip="$(get_cert_fingerprint_from_pem "$cert_pem")"
    checked=$((checked + 1))

    if [ "$tls13_ip" != "$primary_tls13" ] || \
       [ "$x25519_ip" != "$primary_x25519" ] || \
       [ "$h2_ip" != "$primary_h2" ] || \
       [ "$san_ip" != "$primary_san_level" ]; then
      mismatch=$((mismatch + 1))
    elif [ "$primary_cert_fp" != "-" ] && [ "$cert_fp_ip" != "-" ] && [ "$cert_fp_ip" != "$primary_cert_fp" ]; then
      mismatch=$((mismatch + 1))
    fi
  done <<< "$ips"

  if [ "$checked" -le 1 ]; then
    echo "单IP/未知"
  elif [ "$mismatch" -eq 0 ]; then
    echo "一致"
  else
    echo "部分不一致"
  fi
}

get_expiry_from_pem() {
  local pem="$1"
  local expiry
  expiry="$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [ -n "$expiry" ] && echo "$expiry" || echo "-"
}

days_to_expiry_from_pem() {
  local pem="$1"
  local enddate end_epoch now_epoch days
  enddate="$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [ -z "$enddate" ] && { echo ""; return; }
  end_epoch="$(date_to_epoch "$enddate" || true)"
  [ -n "$end_epoch" ] || { echo ""; return; }

  now_epoch="$(date +%s)"
  days=$(( (end_epoch - now_epoch) / 86400 ))
  echo "$days"
}

get_issuer_short_from_pem() {
  local pem="$1"
  local issuer
  issuer="$(echo "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  [ -n "$issuer" ] && shorten "$issuer" 60 || echo "-"
}

check_san_level() {
  local domain="$1"
  local cert_text="$2"
  local san_block item host suffix left
  local items=()

  [ -z "$cert_text" ] && { echo "失败"; return; }
  san_block="$(printf '%s\n' "$cert_text" | awk '
    /X509v3 Subject Alternative Name/ {
      sub(/^.*X509v3 Subject Alternative Name:[[:space:]]*/, "", $0)
      if ($0 != "") print $0
      flag=1
      next
    }
    flag {
      if ($0 ~ /^[[:space:]]*(X509v3 |Signature Algorithm:)/) exit
      if ($0 ~ /^[[:space:]]*$/) next
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
    }
  ' | tr '\n' ',' | sed 's/,$//')"
  [ -z "$san_block" ] && { echo "无SAN"; return; }

  IFS=',' read -r -a items <<< "$san_block"

  for item in "${items[@]}"; do
    item="$(echo "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ "$item" != DNS:* ]] && continue
    host="${item#DNS:}"

    if [ "$host" = "$domain" ]; then
      echo "精确匹配"
      return
    fi

    if [[ "$host" == \*.* ]]; then
      suffix="${host#*.}"
      if [[ "$domain" == *".${suffix}" ]]; then
        left="${domain%.$suffix}"
        if [[ -n "$left" && "$left" != *.* ]]; then
          echo "通配匹配"
          return
        fi
      fi
    fi
  done

  echo "不匹配"
}

extract_host_from_url() {
  local url="$1"
  echo "$url" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#'
}

redirect_naturalness() {
  local input_domain="$1"
  local final_url="$2"
  local final_host

  [ -z "$final_url" ] || [ "$final_url" = "-" ] && { echo "未知"; return; }
  final_host="$(extract_host_from_url "$final_url")"
  [ -z "$final_host" ] && { echo "未知"; return; }

  if [ "$final_host" = "$input_domain" ]; then
    echo "无跳转/同域"
    return
  fi

  case "$final_host" in
    www."$input_domain"|"$input_domain")
      echo "主子域自然跳转"
      ;;
    *)
      if [[ "$input_domain" == *".${final_host#www.}" ]] || [[ "$final_host" == *".${input_domain#www.}" ]]; then
        echo "主子域自然跳转"
      else
        echo "跨站跳转"
      fi
      ;;
  esac
}

detect_waf_challenge() {
  local code="$1"
  local ctype="$2"
  local title="$3"
  local final_url="$4"

  local lc
  lc="$(printf '%s %s %s %s\n' "$code" "$ctype" "$title" "$final_url" | tr 'A-Z' 'a-z')"

  if echo "$lc" | grep -Eiq 'captcha|challenge|attention required|cf-chl|cloudflare|akamai|perimeterx|deny|forbidden'; then
    echo "疑似挑战"
  elif [ "$code" = "403" ] || [ "$code" = "429" ]; then
    echo "疑似拦截"
  else
    echo "正常"
  fi
}

page_naturalness() {
  local code="$1"
  local ctype="$2"
  local size="$3"
  local title="$4"

  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    if echo "$ctype" | grep -Eiq 'text/html|application/xhtml'; then
      if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 512 ]; then
        if [ -n "${title:-}" ] && [ "$title" != "-" ]; then
          echo "像正常网站"
          return
        fi
      fi
      echo "HTML但特征弱"
      return
    fi
    echo "非HTML响应"
    return
  fi

  if [[ "$code" =~ ^(403|404|405)$ ]]; then
    echo "错误页"
    return
  fi

  echo "未知"
}

stability_level() {
  local ok_count="$1"
  local samples="$2"
  local tls_var="$3"
  local ttfb_var="$4"

  if [ "$ok_count" -ge "$samples" ] && [ "$tls_var" -le 40 ] && [ "$ttfb_var" -le 200 ]; then
    echo "稳定"
  elif [ "$ok_count" -ge $(( (samples+1)/2 )) ]; then
    echo "一般"
  else
    echo "波动大"
  fi
}

is_reality_hard_fail() {
  local tls13="$1"
  local x25519="$2"
  local h2="$3"
  local san_level="$4"
  local redirect="$5"

  if [ "$redirect" = "跨站跳转" ] ||
     [ "$tls13" != "支持" ] ||
     [ "$x25519" != "支持" ] ||
     [ "$h2" != "支持" ] ||
     [ "$san_level" = "不匹配" ] ||
     [ "$san_level" = "无SAN" ] ||
     [ "$san_level" = "失败" ]; then
    echo "1"
  else
    echo "0"
  fi
}

performance_gate_status() {
  local tcp_ms="$1"
  local tls_ms="$2"
  local ttfb_ms="$3"
  local tcp_var="$4"
  local tls_var="$5"
  local ttfb_var="$6"

  local tcp_num tls_num ttfb_num tcp_var_num tls_var_num ttfb_var_num
  tcp_num="$(num_or_big "$tcp_ms")"
  tls_num="$(num_or_big "$tls_ms")"
  ttfb_num="$(num_or_big "$ttfb_ms")"
  tcp_var_num="$(num_or_big "$tcp_var")"
  tls_var_num="$(num_or_big "$tls_var")"
  ttfb_var_num="$(num_or_big "$ttfb_var")"

  # 数值项门槛：超过硬阈值直接不建议，超过软阈值直接降为勉强。
  # 只对真实可得的数值生效；999999 代表不可得，显示为 '-'，不在这里直接硬淘汰。
  if { [ "$tcp_num" -lt 999999 ] && [ "$tcp_num" -gt 280 ]; } ||
     { [ "$tls_num" -lt 999999 ] && [ "$tls_num" -gt 650 ]; } ||
     { [ "$ttfb_num" -lt 999999 ] && [ "$ttfb_num" -gt 1200 ]; } ||
     { [ "$tcp_var_num" -lt 999999 ] && [ "$tcp_var_num" -gt 120 ]; } ||
     { [ "$tls_var_num" -lt 999999 ] && [ "$tls_var_num" -gt 130 ]; } ||
     { [ "$ttfb_var_num" -lt 999999 ] && [ "$ttfb_var_num" -gt 650 ]; }; then
    echo "不建议"
    return
  fi

  if { [ "$tcp_num" -lt 999999 ] && [ "$tcp_num" -gt 200 ]; } ||
     { [ "$tls_num" -lt 999999 ] && [ "$tls_num" -gt 300 ]; } ||
     { [ "$ttfb_num" -lt 999999 ] && [ "$ttfb_num" -gt 900 ]; } ||
     { [ "$tcp_var_num" -lt 999999 ] && [ "$tcp_var_num" -gt 80 ]; } ||
     { [ "$tls_var_num" -lt 999999 ] && [ "$tls_var_num" -gt 90 ]; } ||
     { [ "$ttfb_var_num" -lt 999999 ] && [ "$ttfb_var_num" -gt 450 ]; }; then
    echo "勉强"
    return
  fi

  echo "通过"
}

judge_sni() {
  local tls13="$1"
  local x25519="$2"
  local h2="$3"
  local cert_ok="$4"
  local san_level="$5"
  local code="$6"
  local waf="$7"
  local page="$8"
  local redirect="$9"
  local tls_ms="${10}"
  local ttfb_ms="${11}"
  local expiry_days="${12}"
  local stability="${13}"
  local tcp_ms="${14:-}"
  local tcp_var="${15:-}"
  local tls_var="${16:-}"
  local ttfb_var="${17:-}"

  local tls_num ttfb_num hard_fail performance_gate
  tls_num="$(num_or_big "$tls_ms")"
  ttfb_num="$(num_or_big "$ttfb_ms")"
  hard_fail="$(is_reality_hard_fail "$tls13" "$x25519" "$h2" "$san_level" "$redirect")"
  performance_gate="$(performance_gate_status "$tcp_ms" "$tls_ms" "$ttfb_ms" "$tcp_var" "$tls_var" "$ttfb_var")"

  if [ "$cert_ok" != "正常" ] || [ "$san_level" = "不匹配" ] || [ "$san_level" = "无SAN" ] || [ "$san_level" = "失败" ]; then
    echo "不建议"
    return
  fi

  if [ "$hard_fail" = "1" ]; then
    echo "不建议"
    return
  fi

  if [[ "$expiry_days" =~ ^-?[0-9]+$ ]] && [ "$expiry_days" -lt 14 ]; then
    echo "不建议"
    return
  fi

  if [ "$performance_gate" = "不建议" ]; then
    echo "不建议"
    return
  fi

  if [ "$waf" = "疑似挑战" ]; then
    echo "勉强"
    return
  fi

  if [ "$performance_gate" = "勉强" ]; then
    echo "勉强"
    return
  fi

  if [ "$san_level" = "通配匹配" ]; then
    if [[ "$code" =~ ^(200|301|302)$ ]] &&
       [ "$page" != "错误页" ] &&
       [ "$stability" != "波动大" ] &&
       [ "$tls_num" -le 120 ] &&
       [ "$ttfb_num" -le 800 ]; then
      echo "可用"
      return
    fi

    if [[ "$code" =~ ^(200|301|302|403)$ ]]; then
      echo "勉强"
      return
    fi
  fi

  if [[ "$code" =~ ^(200|301|302)$ ]] &&
     [ "$page" != "错误页" ] &&
     [ "$stability" != "波动大" ] &&
     [ "$tls_num" -le 120 ] &&
     [ "$ttfb_num" -le 800 ]; then
    echo "推荐"
    return
  fi

  if [[ "$code" =~ ^(200|301|302|403)$ ]]; then
    echo "可用"
    return
  fi

  echo "勉强"
}

calc_sni_score() {
  local tls13="$1"
  local x25519="$2"
  local h2="$3"
  local alpn_result="$4"
  local cert_ok="$5"
  local cert_chain_status="$6"
  local san_level="$7"
  local code="$8"
  local waf="$9"
  local page="${10}"
  local redirect="${11}"
  local tls_ms="${12}"
  local ttfb_ms="${13}"
  local expiry_days="${14}"
  local result="${15}"
  local stability="${16}"
  local tls_var="${17}"
  local ttfb_var="${18}"
  local tcp_ms="${19}"
  local tcp_var="${20}"
  local ocsp_stapling="${21}"
  local header_naturalness="${22}"
  local ip_consistency="${23}"
  local asn_type="${24:-未知}"
  local cdn_status="${25:-未知}"

  local score=0
  local tcp_num tls_num ttfb_num tcp_var_num tls_var_num ttfb_var_num hard_fail performance_gate
  tcp_num="$(num_or_big "$tcp_ms")"
  tls_num="$(num_or_big "$tls_ms")"
  ttfb_num="$(num_or_big "$ttfb_ms")"
  tcp_var_num="$(num_or_big "$tcp_var")"
  tls_var_num="$(num_or_big "$tls_var")"
  ttfb_var_num="$(num_or_big "$ttfb_var")"
  hard_fail="$(is_reality_hard_fail "$tls13" "$x25519" "$h2" "$san_level" "$redirect")"
  performance_gate="$(performance_gate_status "$tcp_ms" "$tls_ms" "$ttfb_ms" "$tcp_var" "$tls_var" "$ttfb_var")"

  if [ "$hard_fail" = "1" ] || [ "$performance_gate" = "不建议" ]; then
    echo "-9999"
    return
  fi

  # 第一层：安全性 / 证书匹配 / 协议安全能力（主权重）
  case "$result" in
    推荐) score=$((score + 16)) ;;
    可用) score=$((score + 9)) ;;
    勉强) score=$((score + 2)) ;;
    不建议) score=$((score - 8)) ;;
  esac

  case "$san_level" in
    精确匹配) score=$((score + 32)) ;;
    通配匹配) score=$((score + 12)) ;;
    无SAN) score=$((score - 18)) ;;
    不匹配) score=$((score - 42)) ;;
    失败) score=$((score - 32)) ;;
  esac

  case "$cert_ok" in
    正常) score=$((score + 20)) ;;
    *) score=$((score - 24)) ;;
  esac

  case "$tls13" in
    支持) score=$((score + 14)) ;;
    *) score=$((score - 10)) ;;
  esac

  case "$x25519" in
    支持) score=$((score + 14)) ;;
    *) score=$((score - 10)) ;;
  esac

  case "$h2" in
    支持) score=$((score + 4)) ;;
    *) score=$((score - 2)) ;;
  esac

  case "$alpn_result" in
    h2) score=$((score + 5)) ;;
    http/1.1) score=$((score + 1)) ;;
    未知) score=$((score + 0)) ;;
    *) score=$((score - 1)) ;;
  esac

  case "$cert_chain_status" in
    完整) score=$((score + 5)) ;;
    不完整) score=$((score - 6)) ;;
    *) score=$((score - 2)) ;;
  esac

  case "$ocsp_stapling" in
    支持) score=$((score + 2)) ;;
    未提供) score=$((score + 0)) ;;
    异常) score=$((score - 3)) ;;
    *) score=$((score + 0)) ;;
  esac

  # 证书剩余天数仅用于 judge_sni() 的临期硬保护，不再参与评分加减分。

  # 第二层：站点自然性与可用性（v2.1 修订：异常值扣分加重）
  case "$code" in
    200) score=$((score + 10)) ;;
    301|302) score=$((score + 7)) ;;
    403) score=$((score + 2)) ;;
    404) score=$((score - 10)) ;;
    405) score=$((score - 12)) ;;
    *) score=$((score - 20)) ;;
  esac

  case "$page" in
    像正常网站) score=$((score + 12)) ;;
    HTML但特征弱) score=$((score + 6)) ;;
    非HTML响应) score=$((score - 6)) ;;
    错误页) score=$((score - 18)) ;;
  esac

  case "$header_naturalness" in
    自然) score=$((score + 4)) ;;
    一般) score=$((score + 1)) ;;
    异常) score=$((score - 8)) ;;
  esac

  case "$redirect" in
    无跳转/同域) score=$((score + 7)) ;;
    主子域自然跳转) score=$((score + 4)) ;;
    跨站跳转) score=$((score - 20)) ;;
  esac

  case "$waf" in
    正常) score=$((score + 5)) ;;
    疑似拦截) score=$((score - 12)) ;;
    疑似挑战) score=$((score - 28)) ;;
  esac

  case "$ip_consistency" in
    一致) score=$((score + 5)) ;;
    部分不一致) score=$((score - 8)) ;;
    *) score=$((score + 0)) ;;
  esac

  # v2.1 新增: ASN 类型权重, 鼓励选择大流量背景 ASN
  case "$asn_type" in
    CDN)     score=$((score + 8)) ;;
    Hosting) score=$((score + 1)) ;;
    ISP)     score=$((score + 0)) ;;
    Edu)     score=$((score - 8)) ;;
    *)       score=$((score + 0)) ;;
  esac

  # v2.3 新增: CDN 套用检测权重
  # 套 CDN 域名作为 SNI 存在争议: Anycast 路由不一致、回落行为差异等问题
  # 出于安全考虑给予较大扣分, 仅次于一票否决 (硬淘汰为 -9999)
  case "$cdn_status" in
    套CDN)     score=$((score - 30)) ;;
    可能套CDN) score=$((score - 12)) ;;
    未套CDN)   score=$((score + 0)) ;;
    *)         score=$((score + 0)) ;;
  esac

  # 第三层：性能与稳定性（v2.1 修订：异常值加倍扣分，抖动加分压缩）
  # 设计原则：偏离大厂典型值越远，扣分越陡，因为异常本身就是风险信号
  case "$stability" in
    稳定) score=$((score + 7)) ;;
    一般) score=$((score + 1)) ;;
    波动大) score=$((score - 10)) ;;
  esac

  # avg_tls: 正常范围加分不变，超过 160ms 急剧扣分
  if   [ "$tls_num" -le 20 ];  then score=$((score + 8))
  elif [ "$tls_num" -le 30 ];  then score=$((score + 7))
  elif [ "$tls_num" -le 40 ];  then score=$((score + 6))
  elif [ "$tls_num" -le 55 ];  then score=$((score + 5))
  elif [ "$tls_num" -le 70 ];  then score=$((score + 4))
  elif [ "$tls_num" -le 90 ];  then score=$((score + 3))
  elif [ "$tls_num" -le 120 ]; then score=$((score + 2))
  elif [ "$tls_num" -le 160 ]; then score=$((score + 0))
  elif [ "$tls_num" -le 220 ]; then score=$((score - 6))
  elif [ "$tls_num" -le 300 ]; then score=$((score - 14))
  else                              score=$((score - 24))
  fi

  # avg_ttfb: 正常范围加分保留，超过 700ms 急剧扣分；900ms+ 视为明显风险信号
  if   [ "$ttfb_num" -le 120 ];  then score=$((score + 9))
  elif [ "$ttfb_num" -le 180 ];  then score=$((score + 8))
  elif [ "$ttfb_num" -le 240 ];  then score=$((score + 7))
  elif [ "$ttfb_num" -le 320 ];  then score=$((score + 6))
  elif [ "$ttfb_num" -le 420 ];  then score=$((score + 5))
  elif [ "$ttfb_num" -le 550 ];  then score=$((score + 4))
  elif [ "$ttfb_num" -le 700 ];  then score=$((score + 2))
  elif [ "$ttfb_num" -le 900 ];  then score=$((score - 6))
  elif [ "$ttfb_num" -le 1200 ]; then score=$((score - 18))
  elif [ "$ttfb_num" -le 1600 ]; then score=$((score - 32))
  else                                score=$((score - 50))
  fi

  # avg_tcp: 正常范围加分保留，超过 140ms 急剧扣分
  if   [ "$tcp_num" -le 15 ];  then score=$((score + 6))
  elif [ "$tcp_num" -le 25 ];  then score=$((score + 5))
  elif [ "$tcp_num" -le 35 ];  then score=$((score + 4))
  elif [ "$tcp_num" -le 50 ];  then score=$((score + 3))
  elif [ "$tcp_num" -le 70 ];  then score=$((score + 2))
  elif [ "$tcp_num" -le 100 ]; then score=$((score + 1))
  elif [ "$tcp_num" -le 140 ]; then score=$((score + 0))
  elif [ "$tcp_num" -le 200 ]; then score=$((score - 5))
  elif [ "$tcp_num" -le 280 ]; then score=$((score - 12))
  else                              score=$((score - 22))
  fi

  # tcp_var: 加分大幅压缩, 异常值急剧扣分
  if   [ "$tcp_var_num" -le 5 ];   then score=$((score + 2))
  elif [ "$tcp_var_num" -le 10 ];  then score=$((score + 1))
  elif [ "$tcp_var_num" -le 20 ];  then score=$((score + 0))
  elif [ "$tcp_var_num" -le 35 ];  then score=$((score + 0))
  elif [ "$tcp_var_num" -le 55 ];  then score=$((score - 2))
  elif [ "$tcp_var_num" -le 80 ];  then score=$((score - 6))
  elif [ "$tcp_var_num" -le 120 ]; then score=$((score - 12))
  else                                  score=$((score - 20))
  fi

  # tls_var: 加分大幅压缩, 异常值急剧扣分
  if   [ "$tls_var_num" -le 5 ];   then score=$((score + 2))
  elif [ "$tls_var_num" -le 10 ];  then score=$((score + 1))
  elif [ "$tls_var_num" -le 18 ];  then score=$((score + 0))
  elif [ "$tls_var_num" -le 28 ];  then score=$((score + 0))
  elif [ "$tls_var_num" -le 40 ];  then score=$((score - 2))
  elif [ "$tls_var_num" -le 60 ];  then score=$((score - 5))
  elif [ "$tls_var_num" -le 90 ];  then score=$((score - 10))
  elif [ "$tls_var_num" -le 130 ]; then score=$((score - 16))
  else                                  score=$((score - 25))
  fi

  # ttfb_var: 加分大幅压缩, 异常值急剧扣分(抖动往往反映WAF干扰或路径不稳)
  if   [ "$ttfb_var_num" -le 20 ];  then score=$((score + 2))
  elif [ "$ttfb_var_num" -le 40 ];  then score=$((score + 1))
  elif [ "$ttfb_var_num" -le 70 ];  then score=$((score + 0))
  elif [ "$ttfb_var_num" -le 110 ]; then score=$((score + 0))
  elif [ "$ttfb_var_num" -le 160 ]; then score=$((score - 2))
  elif [ "$ttfb_var_num" -le 230 ]; then score=$((score - 5))
  elif [ "$ttfb_var_num" -le 320 ]; then score=$((score - 10))
  elif [ "$ttfb_var_num" -le 450 ]; then score=$((score - 18))
  elif [ "$ttfb_var_num" -le 650 ]; then score=$((score - 30))
  else                                   score=$((score - 45))
  fi

  echo "$score"
}

probe_one() {
  local domain="$1"

  local sample_rows=()
  local i row
  for i in $(seq 1 "$SAMPLES"); do
    row="$(check_curl_once "$domain" "$i")"
    sample_rows+=("$row")
  done

  local tcp_nums=() tls_nums=() ttfb_nums=()
  local ok_count=0
  local best_code="" best_http_ver="" best_ctype="" best_size="" best_final_url="" best_title="" best_headers="" best_remote_ip=""

  for row in "${sample_rows[@]}"; do
    local tcp_ms tls_ms ttfb_ms http_ver code ctype size final_url title headers remote_ip
    IFS=$'\x1f' read -r tcp_ms tls_ms ttfb_ms http_ver code ctype size final_url title headers remote_ip <<< "$row"

    local tls_num ttfb_num tcp_num
    tcp_num="$(num_or_big "$tcp_ms")"
    tls_num="$(num_or_big "$tls_ms")"
    ttfb_num="$(num_or_big "$ttfb_ms")"

    [ "$tcp_num" -lt 999999 ] && tcp_nums+=("$tcp_num")
    [ "$tls_num" -lt 999999 ] && tls_nums+=("$tls_num")
    [ "$ttfb_num" -lt 999999 ] && ttfb_nums+=("$ttfb_num")

    if [[ "$code" =~ ^(200|301|302|403)$ ]]; then
      ok_count=$((ok_count + 1))
    fi

    if [ -z "$best_code" ] && [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
      best_code="$code"
      best_http_ver="$http_ver"
      best_ctype="$ctype"
      best_size="$size"
      best_final_url="$final_url"
      best_title="$title"
      best_headers="$headers"
      best_remote_ip="$remote_ip"
    fi
  done

  local avg_tcp avg_tls avg_ttfb min_tcp max_tcp min_tls max_tls min_ttfb max_ttfb tcp_var tls_var ttfb_var stability avg_latency jitter
  avg_tcp="$(printf '%s\n' "${tcp_nums[@]:-}" | awk '/^[0-9]+$/' | avg_nums)"
  avg_tls="$(printf '%s\n' "${tls_nums[@]:-}" | awk '/^[0-9]+$/' | avg_nums)"
  avg_ttfb="$(printf '%s\n' "${ttfb_nums[@]:-}" | awk '/^[0-9]+$/' | avg_nums)"

  min_tcp="$(printf '%s\n' "${tcp_nums[@]:-}" | awk '/^[0-9]+$/' | sort -n | head -n1)"
  max_tcp="$(printf '%s\n' "${tcp_nums[@]:-}" | awk '/^[0-9]+$/' | sort -n | tail -n1)"
  min_tls="$(printf '%s\n' "${tls_nums[@]:-}" | awk '/^[0-9]+$/' | sort -n | head -n1)"
  max_tls="$(printf '%s\n' "${tls_nums[@]:-}" | awk '/^[0-9]+$/' | sort -n | tail -n1)"
  min_ttfb="$(printf '%s\n' "${ttfb_nums[@]:-}" | awk '/^[0-9]+$/' | sort -n | head -n1)"
  max_ttfb="$(printf '%s\n' "${ttfb_nums[@]:-}" | awk '/^[0-9]+$/' | sort -n | tail -n1)"

  [ -n "$min_tcp" ] && [ -n "$max_tcp" ] && tcp_var=$((max_tcp - min_tcp)) || tcp_var=999999
  [ -n "$min_tls" ] && [ -n "$max_tls" ] && tls_var=$((max_tls - min_tls)) || tls_var=999999
  [ -n "$min_ttfb" ] && [ -n "$max_ttfb" ] && ttfb_var=$((max_ttfb - min_ttfb)) || ttfb_var=999999

  # v2.1 修正: 只有 1 个成功样本时, max-min=0 会被误判为"抖动极小", 应视为"抖动未知"
  [ "${#tcp_nums[@]}" -lt 2 ] && tcp_var=999999
  [ "${#tls_nums[@]}" -lt 2 ] && tls_var=999999
  [ "${#ttfb_nums[@]}" -lt 2 ] && ttfb_var=999999

  stability="$(stability_level "$ok_count" "$SAMPLES" "$tls_var" "$ttfb_var")"

  if [ -n "$avg_ttfb" ]; then
    avg_latency="${avg_ttfb}ms"
  else
    avg_latency="-"
  fi

  if [ "$tcp_var" -lt 999999 ] || [ "$tls_var" -lt 999999 ] || [ "$ttfb_var" -lt 999999 ]; then
    jitter="$(jitter_token TCP "$tcp_var")/$(jitter_token TLS "$tls_var")/$(jitter_token TTFB "$ttfb_var")"
  else
    jitter="-"
  fi

  [ -n "$best_code" ] || {
    best_code="-"
    best_http_ver="-"
    best_ctype="-"
    best_size="0"
    best_final_url="-"
    best_title="-"
    best_headers="-"
    best_remote_ip="-"
  }

  local bundle sclient cert_pem cert_text tls13 x25519 h2 alpn_result cert_ok cert_chain_status san_level cert_fp ocsp_stapling expiry_raw expiry_days issuer redirect waf page header_naturalness ip_consistency result score expiry_show
  local asn_raw asn asn_name asn_type
  local cdn_raw cdn_status cdn_name
 
  bundle="$(fetch_tls_bundle "$domain")"
  if [ "$bundle" = "NO_OPENSSL" ]; then
    sclient=""
    cert_pem=""
  else
    sclient="$(echo "$bundle" | extract_sclient)"
    cert_pem="$(echo "$bundle" | extract_certpem)"
  fi
 
  cert_text="$(cert_text_from_pem "$cert_pem")"
  tls13="$(check_tls13_from_sclient "$sclient")"
  x25519="$(check_x25519_from_sclient "$sclient")"
  alpn_result="$(check_alpn_result_from_sclient "$sclient")"
  cert_chain_status="$(check_cert_chain_status "$sclient")"
  cert_fp="$(get_cert_fingerprint_from_pem "$cert_pem")"
  ocsp_stapling="$(check_ocsp_stapling_from_sclient "$sclient")"
 
  case "$best_http_ver" in
    2|2.0) h2="支持" ;;
    *)
      # v2.3: curl 无 HTTP/2 能力时，优先使用 openssl ALPN 结果兜底，避免误判为不支持
      if [ "$alpn_result" = "h2" ]; then
        h2="支持"
      elif [ "$best_code" = "-" ]; then
        h2="未知"
      else
        h2="$(check_h2 "$domain")"
        [ "$h2" = "未知" ] && [ "$alpn_result" = "h2" ] && h2="支持"
      fi
      ;;
  esac
 
  cert_ok="$(check_cert_ok "$cert_pem")"
  san_level="$(check_san_level "$domain" "$cert_text")"
  expiry_raw="$(get_expiry_from_pem "$cert_pem")"
  expiry_days="$(days_to_expiry_from_pem "$cert_pem")"
  issuer="$(get_issuer_short_from_pem "$cert_pem")"
 
  if [ "$expiry_raw" != "-" ]; then
    expiry_show="$(echo "$expiry_raw" | cut -c1-16)"
  else
    expiry_show="-"
  fi
 
  redirect="$(redirect_naturalness "$domain" "$best_final_url")"
  waf="$(detect_waf_challenge "$best_code" "$best_ctype" "$best_title" "$best_final_url")"
  page="$(page_naturalness "$best_code" "$best_ctype" "$best_size" "$best_title")"
  header_naturalness="$(check_header_naturalness "$best_code" "$best_ctype" "$best_headers")"
  ip_consistency="$(sample_ip_consistency "$domain" "$tls13" "$x25519" "$h2" "$san_level" "$cert_fp")"

  # v2.1 新增: ASN 查询
  asn_raw="$(lookup_asn "$best_remote_ip")"
  asn="$(echo "$asn_raw" | cut -d'|' -f1)"
  asn_name="$(echo "$asn_raw" | cut -d'|' -f2)"
  asn_type="$(echo "$asn_raw" | cut -d'|' -f3)"

  # v2.3 新增: CDN 检测
  cdn_raw="$(detect_cdn "$domain" "$best_headers")"
  cdn_status="$(echo "$cdn_raw" | cut -d'|' -f1)"
  cdn_name="$(echo "$cdn_raw" | cut -d'|' -f2)"
 
  local avg_tcp_show avg_tls_show avg_ttfb_show tls_for_judge ttfb_for_judge
  [ -n "$avg_tcp" ] && avg_tcp_show="${avg_tcp}ms" || avg_tcp_show="-"
  [ -n "$avg_tls" ] && avg_tls_show="${avg_tls}ms" || avg_tls_show="-"
  [ -n "$avg_ttfb" ] && avg_ttfb_show="${avg_ttfb}ms" || avg_ttfb_show="-"
  tls_for_judge="$avg_tls_show"
  ttfb_for_judge="$avg_ttfb_show"
 
  result="$(judge_sni "$tls13" "$x25519" "$h2" "$cert_ok" "$san_level" "$best_code" "$waf" "$page" "$redirect" "$tls_for_judge" "$ttfb_for_judge" "$expiry_days" "$stability" "$avg_tcp_show" "$tcp_var" "$tls_var" "$ttfb_var")"
  score="$(calc_sni_score "$tls13" "$x25519" "$h2" "$alpn_result" "$cert_ok" "$cert_chain_status" "$san_level" "$best_code" "$waf" "$page" "$redirect" "$tls_for_judge" "$ttfb_for_judge" "$expiry_days" "$result" "$stability" "$tls_var" "$ttfb_var" "$avg_tcp" "$tcp_var" "$ocsp_stapling" "$header_naturalness" "$ip_consistency" "$asn_type" "$cdn_status")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" "$best_code" "$avg_tcp_show" "$avg_tls_show" "$avg_ttfb_show" \
    "$avg_latency" "$jitter" "$tcp_var" "$tls_var" "$ttfb_var" \
    "$tls13" "$x25519" "$h2" "$alpn_result" "$cert_ok" "$cert_chain_status" "$san_level" "$ocsp_stapling" "$page" "$header_naturalness" "$waf" "$redirect" "$ip_consistency" "$stability" "$score" "$result" "$issuer" "$best_final_url" "$best_title" "$best_ctype" "$best_size" "$best_remote_ip" \
    "$asn" "$asn_type" "$cdn_status" "$cdn_name"
}

worker_main() {
  probe_one "$1"
}

run_with_limit() {
  local max_jobs="$1"
  shift
  while :; do
    [ "$(jobs -rp | wc -l)" -lt "$max_jobs" ] && break
    sleep 0.1
  done
  # v2.1 新增: 在达到并发上限之前, 给每个 worker 启动加上随机延迟
  # 用途: 避免一批域名以完全相同的节奏发出请求, 降低被云端 WAF 聚类识别的概率
  if [ "$JITTER_MS_MAX" -gt 0 ]; then
    local rand_ms rand_sec
    rand_ms=$(( RANDOM % (JITTER_MS_MAX + 1) ))
    if [ "$rand_ms" -gt 0 ]; then
      rand_sec="$(awk -v m="$rand_ms" 'BEGIN{printf "%.3f", m/1000}')"
      sleep "$rand_sec" 2>/dev/null || true
    fi
  fi
  "$@" &
}

TABLE_WIDTHS=(26 4 8 8 8 8 14 6 6 6 8 8 4 14 8 10 6 8 10 10 6 6 8 5 6)
TABLE_HEADERS=("域名" "码" "TCP建连" "TLS握手" "TTFB" "平均延迟" "抖动T/TLS/F" "TLS13" "X25519" "H2" "ALPN" "SAN" "证书" "跳转" "WAF" "页面" "稳定性" "ASN类型" "多IP" "链" "头部" "OCSP" "CDN" "评分" "结论")

table_strip_ansi() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
}

table_display_width() {
  local s stripped i ch code width=0
  s="${1:-}"
  stripped="$(table_strip_ansi "$s")"

  for ((i=0; i<${#stripped}; i++)); do
    ch="${stripped:i:1}"
    printf -v code '%d' "'$ch"

    if [ "$code" -le 127 ]; then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done

  echo "$width"
}

table_fit_text() {
  local s stripped width current_width limit i ch code char_width out=""
  s="${1:-}"
  width="$2"
  stripped="$(table_strip_ansi "$s")"

  current_width="$(table_display_width "$stripped")"
  if [ "$current_width" -le "$width" ]; then
    printf '%s' "$stripped"
    return
  fi

  limit=$((width - 3))
  if [ "$limit" -le 0 ]; then
    printf '%.*s' "$width" "..."
    return
  fi

  current_width=0
  for ((i=0; i<${#stripped}; i++)); do
    ch="${stripped:i:1}"
    printf -v code '%d' "'$ch"

    if [ "$code" -le 127 ]; then
      char_width=1
    else
      char_width=2
    fi

    [ $((current_width + char_width)) -gt "$limit" ] && break
    out+="$ch"
    current_width=$((current_width + char_width))
  done

  printf '%s...' "$out"
}

table_pad_cell() {
  local text="${1:-}"
  local width="$2"
  local fitted display_width pad

  fitted="$(table_fit_text "$text" "$width")"
  display_width="$(table_display_width "$fitted")"
  pad=$((width - display_width))

  printf '%s' "$fitted"
  [ "$pad" -gt 0 ] && printf '%*s' "$pad" ''
}

table_print_rule() {
  local total=0 width i

  for i in "${!TABLE_WIDTHS[@]}"; do
    width="${TABLE_WIDTHS[$i]}"
    total=$((total + width))
    [ "$i" -gt 0 ] && total=$((total + 3))
  done

  printf '%*s\n' "$total" '' | tr ' ' '-'
}

table_print_row() {
  local values=("$@")
  local i

  for i in "${!TABLE_WIDTHS[@]}"; do
    [ "$i" -gt 0 ] && printf ' | '
    table_pad_cell "${values[$i]:-}" "${TABLE_WIDTHS[$i]}"
  done
  printf '\n'
}

print_table() {
  local sorted_file="$1"

  echo "REALITY SNI 专业评估 v2.3"
  table_print_row "${TABLE_HEADERS[@]}"
  table_print_rule

  while IFS=$'\t' read -r domain code avg_tcp avg_tls avg_ttfb avg_latency jitter tcp_var tls_var ttfb_var tls13 x25519 h2 alpn_result cert_ok cert_chain_status san_level ocsp_stapling page header_naturalness waf redirect ip_consistency stability score result issuer final_url title ctype size remote_ip asn asn_type cdn_status cdn_name; do
    local type_label="-"
    local tcp_var_show="$tcp_var"
    local tls_var_show="$tls_var"
    local ttfb_var_show="$ttfb_var"
    local jitter_compact
    local cdn_label

    case "$page" in
      像正常网站) type_label="网页站" ;;
      HTML但特征弱) type_label="弱网页" ;;
      非HTML响应) type_label="接口/下载" ;;
      错误页) type_label="错误页" ;;
    esac

    [ "$tcp_var_show" = "999999" ] && tcp_var_show="-"
    [ "$tls_var_show" = "999999" ] && tls_var_show="-"
    [ "$ttfb_var_show" = "999999" ] && ttfb_var_show="-"

    if [ "$tcp_var_show/$tls_var_show/$ttfb_var_show" = "-/-/-" ]; then
      jitter_compact="-"
    else
      jitter_compact="${tcp_var_show}/${tls_var_show}/${ttfb_var_show}ms"
    fi

    case "${cdn_status:-未知}" in
      套CDN) cdn_label="套CDN" ;;
      可能套CDN) cdn_label="可能套" ;;
      未套CDN) cdn_label="未套" ;;
      *) cdn_label="未知" ;;
    esac

    table_print_row \
      "$domain" "$code" "$avg_tcp" "$avg_tls" "$avg_ttfb" "$avg_latency" "$jitter_compact" \
      "$tls13" "$x25519" "$h2" "$alpn_result" "$san_level" "$cert_ok" "$redirect" "$waf" "$type_label" "$stability" "${asn_type:-未知}" "$ip_consistency" "$cert_chain_status" "$header_naturalness" "$ocsp_stapling" "$cdn_label" "$score" "$result"
  done < "$sorted_file"

  table_print_rule
}

export_csv() {
  local sorted_file="$1"
  local out="$2"
  {
    echo '"domain","code","avg_tcp","avg_tls","avg_ttfb","avg_latency","jitter","tcp_jitter","tls_jitter","ttfb_jitter","tls13","x25519","h2","alpn_result","cert_ok","cert_chain_status","san_level","ocsp_stapling","page","header_naturalness","waf","redirect","ip_consistency","stability","score","result","issuer","final_url","title","content_type","size","remote_ip","asn","asn_type","cdn_status","cdn_name"'
    while IFS=$'\t' read -r domain code avg_tcp avg_tls avg_ttfb avg_latency jitter tcp_var tls_var ttfb_var tls13 x25519 h2 alpn_result cert_ok cert_chain_status san_level ocsp_stapling page header_naturalness waf redirect ip_consistency stability score result issuer final_url title ctype size remote_ip asn asn_type cdn_status cdn_name; do
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$domain")" "$(csv_escape "$code")" "$(csv_escape "$avg_tcp")" "$(csv_escape "$avg_tls")" "$(csv_escape "$avg_ttfb")" \
        "$(csv_escape "$avg_latency")" "$(csv_escape "$jitter")" "$(csv_escape "$(ms_or_dash "$tcp_var")")" "$(csv_escape "$(ms_or_dash "$tls_var")")" "$(csv_escape "$(ms_or_dash "$ttfb_var")")" \
        "$(csv_escape "$tls13")" "$(csv_escape "$x25519")" "$(csv_escape "$h2")" "$(csv_escape "$alpn_result")" "$(csv_escape "$cert_ok")" "$(csv_escape "$cert_chain_status")" \
        "$(csv_escape "$san_level")" "$(csv_escape "$ocsp_stapling")" "$(csv_escape "$page")" "$(csv_escape "$header_naturalness")" "$(csv_escape "$waf")" "$(csv_escape "$redirect")" \
        "$(csv_escape "$ip_consistency")" "$(csv_escape "$stability")" "$(csv_escape "$score")" "$(csv_escape "$result")" "$(csv_escape "$issuer")" "$(csv_escape "$final_url")" \
        "$(csv_escape "$title")" "$(csv_escape "$ctype")" "$(csv_escape "$size")" "$(csv_escape "$remote_ip")" \
        "$(csv_escape "${asn:--}")" "$(csv_escape "${asn_type:-未知}")" "$(csv_escape "${cdn_status:-未知}")" "$(csv_escape "${cdn_name:--}")"
    done < "$sorted_file"
  } > "$out"
  echo "CSV 已导出: $out"
}

export_jsonl() {
  local sorted_file="$1"
  local out="$2"
  : > "$out"
  while IFS=$'\t' read -r domain code avg_tcp avg_tls avg_ttfb avg_latency jitter tcp_var tls_var ttfb_var tls13 x25519 h2 alpn_result cert_ok cert_chain_status san_level ocsp_stapling page header_naturalness waf redirect ip_consistency stability score result issuer final_url title ctype size remote_ip asn asn_type cdn_status cdn_name; do
    printf '{"domain":"%s","code":"%s","avg_tcp":"%s","avg_tls":"%s","avg_ttfb":"%s","avg_latency":"%s","jitter":"%s","tcp_jitter":"%s","tls_jitter":"%s","ttfb_jitter":"%s","tls13":"%s","x25519":"%s","h2":"%s","alpn_result":"%s","cert_ok":"%s","cert_chain_status":"%s","san_level":"%s","ocsp_stapling":"%s","page":"%s","header_naturalness":"%s","waf":"%s","redirect":"%s","ip_consistency":"%s","stability":"%s","score":"%s","result":"%s","issuer":"%s","final_url":"%s","title":"%s","content_type":"%s","size":"%s","remote_ip":"%s","asn":"%s","asn_type":"%s","cdn_status":"%s","cdn_name":"%s"}\n' \
      "$(json_escape "$domain")" "$(json_escape "$code")" "$(json_escape "$avg_tcp")" "$(json_escape "$avg_tls")" "$(json_escape "$avg_ttfb")" \
      "$(json_escape "$avg_latency")" "$(json_escape "$jitter")" "$(json_escape "$(ms_or_dash "$tcp_var")")" "$(json_escape "$(ms_or_dash "$tls_var")")" "$(json_escape "$(ms_or_dash "$ttfb_var")")" \
      "$(json_escape "$tls13")" "$(json_escape "$x25519")" "$(json_escape "$h2")" "$(json_escape "$alpn_result")" "$(json_escape "$cert_ok")" "$(json_escape "$cert_chain_status")" \
      "$(json_escape "$san_level")" "$(json_escape "$ocsp_stapling")" "$(json_escape "$page")" "$(json_escape "$header_naturalness")" "$(json_escape "$waf")" "$(json_escape "$redirect")" \
      "$(json_escape "$ip_consistency")" "$(json_escape "$stability")" "$(json_escape "$score")" "$(json_escape "$result")" "$(json_escape "$issuer")" "$(json_escape "$final_url")" \
      "$(json_escape "$title")" "$(json_escape "$ctype")" "$(json_escape "$size")" "$(json_escape "$remote_ip")" \
      "$(json_escape "${asn:--}")" "$(json_escape "${asn_type:-未知}")" "$(json_escape "${cdn_status:-未知}")" "$(json_escape "${cdn_name:--}")" >> "$out"
  done < "$sorted_file"
  echo "JSONL 已导出: $out"
}

filter_results() {
  local in_file="$1"
  local out_file="$2"

  awk -F'\t' -v only_good="$ONLY_GOOD" -v min_score="$MIN_SCORE" '
  function ok_result(r) { return (r=="推荐" || r=="可用") }
  function ok_score(s) { if (min_score=="") return 1; return (s+0 >= min_score+0) }
  {
    keep=1
    if (only_good=="1" && !ok_result($26)) keep=0
    if (!ok_score($25)) keep=0
    if (keep) print $0
  }' "$in_file" > "$out_file"
}

dedup_domains() {
  awk '!seen[$0]++'
}

main() {
  local domains=()
  local tmp_dir result_file filtered_file sorted_file idx=0 out_file line

  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -f)
        shift
        [ $# -eq 0 ] && { echo "错误: -f 需要文件参数" >&2; usage; exit 1; }
        while IFS= read -r line || [ -n "$line" ]; do
          line="$(normalize_domain "$line")"
          [ -z "$line" ] && continue
          [[ "$line" =~ ^# ]] && continue
          domains+=("$line")
        done < "$1"
        ;;
      -o)
        shift
        [ $# -eq 0 ] && { echo "错误: -o 需要文件参数" >&2; usage; exit 1; }
        OUT_CSV="$1"
        ;;
      --json)
        shift
        [ $# -eq 0 ] && { echo "错误: --json 需要文件参数" >&2; usage; exit 1; }
        OUT_JSON="$1"
        ;;
      -j)
        shift
        [ $# -eq 0 ] && { echo "错误: -j 需要数值参数" >&2; usage; exit 1; }
        [[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "错误: -j 必须是正整数" >&2; exit 1; }
        JOBS="$1"
        ;;
      --timeout)
        shift
        [ $# -eq 0 ] && { echo "错误: --timeout 需要数值参数" >&2; usage; exit 1; }
        [[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "错误: --timeout 必须是正整数" >&2; exit 1; }
        TIMEOUT_SEC="$1"
        ;;
      --samples)
        shift
        [ $# -eq 0 ] && { echo "错误: --samples 需要数值参数" >&2; usage; exit 1; }
        [[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "错误: --samples 必须是正整数" >&2; exit 1; }
        SAMPLES="$1"
        ;;
      --only-good)
        ONLY_GOOD=1
        ;;
      --min-score)
        shift
        [ $# -eq 0 ] && { echo "错误: --min-score 需要数值参数" >&2; usage; exit 1; }
        [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || { echo "错误: --min-score 必须是数值" >&2; exit 1; }
        MIN_SCORE="$1"
        ;;
      --jitter)
        shift
        [ $# -eq 0 ] && { echo "错误: --jitter 需要数值参数" >&2; usage; exit 1; }
        [[ "$1" =~ ^[0-9]+$ ]] || { echo "错误: --jitter 必须是非负整数毫秒" >&2; exit 1; }
        JITTER_MS_MAX="$1"
        ;;
      --no-asn)
        ASN_ENABLED=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        domains+=("$(normalize_domain "$1")")
        ;;
    esac
    shift
  done

  [ "${#domains[@]}" -eq 0 ] && { echo "错误: 没有域名" >&2; exit 1; }

  mapfile -t domains < <(printf '%s\n' "${domains[@]}" | awk 'NF' | dedup_domains)
  [ "${#domains[@]}" -eq 0 ] && { echo "错误: 没有有效域名" >&2; exit 1; }

  warn_dependencies

  tmp_dir="$(mktemp -d)"
  TMP_ROOT="$tmp_dir"
  trap '[ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"' EXIT

  for domain in "${domains[@]}"; do
    idx=$((idx + 1))
    out_file="$tmp_dir/$idx.tsv"
    run_with_limit "$JOBS" env -u LC_ALL LANG="${LANG:-${LC_CTYPE:-C.UTF-8}}" LC_CTYPE="${LC_CTYPE:-${LANG:-C.UTF-8}}" TIMEOUT_SEC="$TIMEOUT_SEC" SAMPLES="$SAMPLES" TMP_ROOT="$tmp_dir" ASN_ENABLED="$ASN_ENABLED" ASN_TIMEOUT_SEC="$ASN_TIMEOUT_SEC" UTF8_BOOTSTRAP_DONE=1 bash "$0" --worker "$domain" > "$out_file"
  done
  wait

  result_file="$tmp_dir/all.tsv"
  cat "$tmp_dir"/*.tsv 2>/dev/null > "$result_file"

  filtered_file="$tmp_dir/filtered.tsv"
  filter_results "$result_file" "$filtered_file"

  sorted_file="$tmp_dir/sorted.tsv"
  awk -F'\t' '
  {
    hard_ok = ($22!="跨站跳转" && $11=="支持" && $12=="支持" && $13=="支持" && ($17=="精确匹配" || $17=="通配匹配")) ? 1 : 0
    san_rank = ($17=="精确匹配"?2:($17=="通配匹配"?1:0))
    rank = ($26=="推荐"?4:($26=="可用"?3:($26=="勉强"?2:1)))
    # v2.3 排序键: hard_ok > result(rank) > san_rank > score > tls_var > ttfb_var
    # 设计原则: 协议硬条件最优先, 然后按结论档位分组, 同档位内精确匹配优于通配匹配,
    #          同 SAN 等级内按分数排序, 最后用抖动做 tie-break
    print hard_ok "\t" rank "\t" san_rank "\t" $25 "\t" $9 "\t" $10 "\t" $0
  }' "$filtered_file" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5n -k6,6n | cut -f7- > "$sorted_file"

  print_table "$sorted_file"
  [ -n "$OUT_CSV" ] && export_csv "$sorted_file" "$OUT_CSV"
  [ -n "$OUT_JSON" ] && export_jsonl "$sorted_file" "$OUT_JSON"
}

if [ "${1:-}" = "--worker" ]; then
  shift
  worker_main "$1"
  exit 0
fi

main "$@"
