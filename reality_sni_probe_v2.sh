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

  candidates+=("C.UTF-8" "en_US.UTF-8" "UTF-8")

  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if locale -a 2>/dev/null | grep -Eiq "^${candidate//./[.]$}$"; then
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
# REALITY SNI probe - pro v2
# Focus: evaluate whether a domain is suitable as REALITY SNI
# =========================================================

JOBS=4
TIMEOUT_SEC=10
SAMPLES=3
OUT_CSV=""
OUT_JSON=""
ONLY_GOOD=0
MIN_SCORE=""
TMP_ROOT=""

have_cmd() { command -v "$1" >/dev/null 2>&1; }

safe_timeout() {
  local secs="$1"
  shift

  if have_cmd timeout; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
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
  -j NUM          并发数，默认 4
  --timeout NUM   单次请求超时，默认 10
  --samples NUM   采样次数，默认 3
  --only-good     仅输出 推荐/可用
  --min-score N   仅输出分数 >= N
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
  local max_time="${TIMEOUT_SEC:-10}"
  local data t_connect t_appconnect t_starttransfer http_ver code ctype size eff

  if ! have_cmd curl; then
    echo "缺失|缺失|缺失||缺失|缺失|0|-|-"
    return
  fi

  data="$(curl -L -o "$body_file" -s \
    -w $'%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{http_version}\t%{response_code}\t%{content_type}\t%{size_download}\t%{url_effective}' \
    --connect-timeout 4 --max-time "$max_time" \
    "https://${domain}" 2>/dev/null)"

  IFS=$'\t' read -r t_connect t_appconnect t_starttransfer http_ver code ctype size eff <<< "$data"

  local tcp_ms tls_ms ttfb_ms body title_line title
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

  body="$(cat "$body_file" 2>/dev/null || true)"
  rm -f "$body_file" 2>/dev/null || true

  title_line="$(echo "$body" | tr '\n' ' ' | sed -n 's/.*<title[^>]*>\(.*\)<\/title>.*/\1/p' | head -n1)"
  title="$(echo "$title_line" | sed 's/[[:space:]]\+/ /g' | cut -c1-100)"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$tcp_ms" "$tls_ms" "$ttfb_ms" "$http_ver" "$code" "${ctype:--}" "${size:-0}" "${eff:--}" "${title:--}"
}

fetch_tls_bundle() {
  local domain="$1"
  local max_time="${TIMEOUT_SEC:-10}"
  local sclient certpem

  if ! have_cmd openssl; then
    echo "NO_OPENSSL"
    return
  fi

  sclient="$(safe_timeout "$max_time" openssl s_client -connect "${domain}:443" -servername "$domain" -showcerts < /dev/null 2>&1)"
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
    echo "不支持"
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
  if date -d "$enddate" +%s >/dev/null 2>&1; then
    end_epoch="$(date -d "$enddate" +%s)"
    now_epoch="$(date +%s)"
    days=$(( (end_epoch - now_epoch) / 86400 ))
    echo "$days"
  else
    echo ""
  fi
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
  local san_line san_block item host suffix left

  [ -z "$cert_text" ] && { echo "失败"; return; }
  san_line="$(echo "$cert_text" | awk '/X509v3 Subject Alternative Name/{getline; print}')"
  [ -z "$san_line" ] && { echo "无SAN"; return; }

  san_block="$(echo "$san_line" | sed 's/^[[:space:]]*//')"
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

  local tls_num ttfb_num
  tls_num="$(num_or_big "$tls_ms")"
  ttfb_num="$(num_or_big "$ttfb_ms")"

  if [ "$cert_ok" != "正常" ] || [ "$san_level" = "不匹配" ] || [ "$san_level" = "失败" ]; then
    echo "不建议"
    return
  fi

  if [[ "$expiry_days" =~ ^-?[0-9]+$ ]] && [ "$expiry_days" -lt 14 ]; then
    echo "不建议"
    return
  fi

  if [ "$tls13" != "支持" ] || [ "$x25519" != "支持" ]; then
    echo "勉强"
    return
  fi

  if [ "$waf" = "疑似挑战" ]; then
    echo "勉强"
    return
  fi

  if [[ "$code" =~ ^(200|301|302)$ ]] &&
     [ "$page" != "错误页" ] &&
     [ "$redirect" != "跨站跳转" ] &&
     [ "$h2" = "支持" ] &&
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
  local cert_ok="$4"
  local san_level="$5"
  local code="$6"
  local waf="$7"
  local page="$8"
  local redirect="$9"
  local tls_ms="${10}"
  local ttfb_ms="${11}"
  local expiry_days="${12}"
  local result="${13}"
  local stability="${14}"
  local tls_var="${15}"
  local ttfb_var="${16}"
  local tcp_ms="${17}"
  local tcp_var="${18}"

  local score=0
  local tcp_num tls_num ttfb_num tcp_var_num tls_var_num ttfb_var_num
  tcp_num="$(num_or_big "$tcp_ms")"
  tls_num="$(num_or_big "$tls_ms")"
  ttfb_num="$(num_or_big "$ttfb_ms")"
  tcp_var_num="$(num_or_big "$tcp_var")"
  tls_var_num="$(num_or_big "$tls_var")"
  ttfb_var_num="$(num_or_big "$ttfb_var")"

  # 第一层：安全性 / 证书匹配 / 协议安全能力（主权重）
  case "$result" in
    推荐) score=$((score + 16)) ;;
    可用) score=$((score + 9)) ;;
    勉强) score=$((score + 2)) ;;
    不建议) score=$((score - 8)) ;;
  esac

  case "$san_level" in
    精确匹配) score=$((score + 28)) ;;
    通配匹配) score=$((score + 20)) ;;
    无SAN) score=$((score - 16)) ;;
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

  if [[ "$expiry_days" =~ ^-?[0-9]+$ ]]; then
    if [ "$expiry_days" -ge 365 ]; then
      score=$((score + 10))
    elif [ "$expiry_days" -ge 180 ]; then
      score=$((score + 8))
    elif [ "$expiry_days" -ge 120 ]; then
      score=$((score + 6))
    elif [ "$expiry_days" -ge 90 ]; then
      score=$((score + 4))
    elif [ "$expiry_days" -ge 60 ]; then
      score=$((score + 2))
    elif [ "$expiry_days" -ge 30 ]; then
      score=$((score + 0))
    elif [ "$expiry_days" -ge 14 ]; then
      score=$((score - 6))
    elif [ "$expiry_days" -ge 7 ]; then
      score=$((score - 14))
    elif [ "$expiry_days" -ge 0 ]; then
      score=$((score - 24))
    else
      score=$((score - 30))
    fi
  fi

  # 第二层：站点自然性与可用性（次权重）
  case "$code" in
    200) score=$((score + 10)) ;;
    301|302) score=$((score + 7)) ;;
    403) score=$((score + 2)) ;;
    404) score=$((score - 5)) ;;
    405) score=$((score - 6)) ;;
    *) score=$((score - 10)) ;;
  esac

  case "$page" in
    像正常网站) score=$((score + 12)) ;;
    HTML但特征弱) score=$((score + 6)) ;;
    非HTML响应) score=$((score - 3)) ;;
    错误页) score=$((score - 9)) ;;
  esac

  case "$redirect" in
    无跳转/同域) score=$((score + 7)) ;;
    主子域自然跳转) score=$((score + 4)) ;;
    跨站跳转) score=$((score - 10)) ;;
  esac

  case "$waf" in
    正常) score=$((score + 5)) ;;
    疑似拦截) score=$((score - 6)) ;;
    疑似挑战) score=$((score - 14)) ;;
  esac

  case "$h2" in
    支持) score=$((score + 4)) ;;
    *) score=$((score - 2)) ;;
  esac

  # 第三层：性能与稳定性（补充细化项）
  case "$stability" in
    稳定) score=$((score + 7)) ;;
    一般) score=$((score + 1)) ;;
    波动大) score=$((score - 10)) ;;
  esac

  [ "$tls_num" -le 20 ] && score=$((score + 8)) || \
  [ "$tls_num" -le 30 ] && score=$((score + 7)) || \
  [ "$tls_num" -le 40 ] && score=$((score + 6)) || \
  [ "$tls_num" -le 55 ] && score=$((score + 5)) || \
  [ "$tls_num" -le 70 ] && score=$((score + 4)) || \
  [ "$tls_num" -le 90 ] && score=$((score + 3)) || \
  [ "$tls_num" -le 120 ] && score=$((score + 2)) || \
  [ "$tls_num" -le 160 ] && score=$((score + 0)) || \
  [ "$tls_num" -le 220 ] && score=$((score - 2)) || \
  [ "$tls_num" -le 300 ] && score=$((score - 4)) || \
  score=$((score - 6))

  [ "$ttfb_num" -le 120 ] && score=$((score + 9)) || \
  [ "$ttfb_num" -le 180 ] && score=$((score + 8)) || \
  [ "$ttfb_num" -le 240 ] && score=$((score + 7)) || \
  [ "$ttfb_num" -le 320 ] && score=$((score + 6)) || \
  [ "$ttfb_num" -le 420 ] && score=$((score + 5)) || \
  [ "$ttfb_num" -le 550 ] && score=$((score + 4)) || \
  [ "$ttfb_num" -le 700 ] && score=$((score + 3)) || \
  [ "$ttfb_num" -le 900 ] && score=$((score + 1)) || \
  [ "$ttfb_num" -le 1200 ] && score=$((score - 1)) || \
  [ "$ttfb_num" -le 1600 ] && score=$((score - 3)) || \
  score=$((score - 6))

  [ "$tcp_num" -le 15 ] && score=$((score + 6)) || \
  [ "$tcp_num" -le 25 ] && score=$((score + 5)) || \
  [ "$tcp_num" -le 35 ] && score=$((score + 4)) || \
  [ "$tcp_num" -le 50 ] && score=$((score + 3)) || \
  [ "$tcp_num" -le 70 ] && score=$((score + 2)) || \
  [ "$tcp_num" -le 100 ] && score=$((score + 1)) || \
  [ "$tcp_num" -le 140 ] && score=$((score + 0)) || \
  [ "$tcp_num" -le 200 ] && score=$((score - 2)) || \
  [ "$tcp_num" -le 280 ] && score=$((score - 4)) || \
  score=$((score - 6))

  [ "$tcp_var_num" -le 5 ] && score=$((score + 4)) || \
  [ "$tcp_var_num" -le 10 ] && score=$((score + 3)) || \
  [ "$tcp_var_num" -le 20 ] && score=$((score + 2)) || \
  [ "$tcp_var_num" -le 35 ] && score=$((score + 1)) || \
  [ "$tcp_var_num" -le 55 ] && score=$((score + 0)) || \
  [ "$tcp_var_num" -le 80 ] && score=$((score - 2)) || \
  [ "$tcp_var_num" -le 120 ] && score=$((score - 4)) || \
  score=$((score - 6))

  [ "$tls_var_num" -le 5 ] && score=$((score + 5)) || \
  [ "$tls_var_num" -le 10 ] && score=$((score + 4)) || \
  [ "$tls_var_num" -le 18 ] && score=$((score + 3)) || \
  [ "$tls_var_num" -le 28 ] && score=$((score + 2)) || \
  [ "$tls_var_num" -le 40 ] && score=$((score + 1)) || \
  [ "$tls_var_num" -le 60 ] && score=$((score + 0)) || \
  [ "$tls_var_num" -le 90 ] && score=$((score - 2)) || \
  [ "$tls_var_num" -le 130 ] && score=$((score - 4)) || \
  score=$((score - 6))

  [ "$ttfb_var_num" -le 20 ] && score=$((score + 6)) || \
  [ "$ttfb_var_num" -le 40 ] && score=$((score + 5)) || \
  [ "$ttfb_var_num" -le 70 ] && score=$((score + 4)) || \
  [ "$ttfb_var_num" -le 110 ] && score=$((score + 3)) || \
  [ "$ttfb_var_num" -le 160 ] && score=$((score + 2)) || \
  [ "$ttfb_var_num" -le 230 ] && score=$((score + 1)) || \
  [ "$ttfb_var_num" -le 320 ] && score=$((score - 1)) || \
  [ "$ttfb_var_num" -le 450 ] && score=$((score - 3)) || \
  [ "$ttfb_var_num" -le 650 ] && score=$((score - 5)) || \
  score=$((score - 7))

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
  local best_code="" best_http_ver="" best_ctype="" best_size="" best_final_url="" best_title=""

  for row in "${sample_rows[@]}"; do
    local tcp_ms tls_ms ttfb_ms http_ver code ctype size final_url title
    tcp_ms="$(echo "$row" | cut -d'|' -f1)"
    tls_ms="$(echo "$row" | cut -d'|' -f2)"
    ttfb_ms="$(echo "$row" | cut -d'|' -f3)"
    http_ver="$(echo "$row" | cut -d'|' -f4)"
    code="$(echo "$row" | cut -d'|' -f5)"
    ctype="$(echo "$row" | cut -d'|' -f6)"
    size="$(echo "$row" | cut -d'|' -f7)"
    final_url="$(echo "$row" | cut -d'|' -f8)"
    title="$(echo "$row" | cut -d'|' -f9)"

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
  stability="$(stability_level "$ok_count" "$SAMPLES" "$tls_var" "$ttfb_var")"

  if [ -n "$avg_ttfb" ]; then
    avg_latency="${avg_ttfb}ms"
  else
    avg_latency="-"
  fi

  if [ "$tcp_var" -lt 999999 ] || [ "$tls_var" -lt 999999 ] || [ "$ttfb_var" -lt 999999 ]; then
    jitter="TCP:${tcp_var:-?}ms/TLS:${tls_var:-?}ms/TTFB:${ttfb_var:-?}ms"
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
  }

  local bundle sclient cert_pem cert_text tls13 x25519 h2 cert_ok san_level expiry_raw expiry_days issuer redirect waf page result score expiry_show

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

  case "$best_http_ver" in
    2|2.0) h2="支持" ;;
    *) h2="$(check_h2 "$domain")" ;;
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

  local avg_tcp_show avg_tls_show avg_ttfb_show tls_for_judge ttfb_for_judge
  [ -n "$avg_tcp" ] && avg_tcp_show="${avg_tcp}ms" || avg_tcp_show="-"
  [ -n "$avg_tls" ] && avg_tls_show="${avg_tls}ms" || avg_tls_show="-"
  [ -n "$avg_ttfb" ] && avg_ttfb_show="${avg_ttfb}ms" || avg_ttfb_show="-"
  tls_for_judge="$avg_tls_show"
  ttfb_for_judge="$avg_ttfb_show"

  result="$(judge_sni "$tls13" "$x25519" "$h2" "$cert_ok" "$san_level" "$best_code" "$waf" "$page" "$redirect" "$tls_for_judge" "$ttfb_for_judge" "$expiry_days" "$stability")"
  score="$(calc_sni_score "$tls13" "$x25519" "$h2" "$cert_ok" "$san_level" "$best_code" "$waf" "$page" "$redirect" "$tls_for_judge" "$ttfb_for_judge" "$expiry_days" "$result" "$stability" "$tls_var" "$ttfb_var" "$avg_tcp" "$tcp_var")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" "$best_code" "$avg_tcp_show" "$avg_tls_show" "$avg_ttfb_show" \
    "$avg_latency" "$jitter" "$tcp_var" "$tls_var" "$ttfb_var" \
    "$tls13" "$x25519" "$h2" "$cert_ok" "$san_level" "$page" "$waf" "$redirect" "$stability" "$score" "$result" "$issuer" "$best_final_url" "$best_title" "$best_ctype" "$best_size"
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
  "$@" &
}

TABLE_WIDTHS=(30 4 8 8 8 8 16 6 6 6 4 8 12 8 14 6 5 6)
TABLE_HEADERS=("域名" "码" "TCP建连" "TLS握手" "TTFB" "平均延迟" "抖动T/TLS/F" "TLS13" "X25519" "H2" "证书" "SAN" "页面" "WAF" "跳转" "稳定性" "评分" "结论")

table_display_width() {
  local s="${1:-}"
  local i ch width=0

  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == [[:print:]] && "$ch" != [[:space:]] ]]; then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done

  echo "$width"
}

table_fit_text() {
  local s="${1:-}"
  local width="$2"
  local current_width limit i ch char_width out=""

  current_width="$(table_display_width "$s")"
  if [ "$current_width" -le "$width" ]; then
    printf '%s' "$s"
    return
  fi

  limit=$((width - 3))
  if [ "$limit" -le 0 ]; then
    printf '%.*s' "$width" "..."
    return
  fi

  current_width=0
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == [[:print:]] && "$ch" != [[:space:]] ]]; then
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
  local total=0 width

  for width in "${TABLE_WIDTHS[@]}"; do
    total=$((total + width))
  done
  total=$((total + (${#TABLE_WIDTHS[@]} - 1) * 3))

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

  echo "REALITY SNI 专业评估 v2"
  table_print_row "${TABLE_HEADERS[@]}"
  table_print_rule

  while IFS=$'\t' read -r domain code avg_tcp avg_tls avg_ttfb avg_latency jitter tcp_var tls_var ttfb_var tls13 x25519 h2 cert_ok san_level page waf redirect stability score result issuer final_url title ctype size; do
    local type_label="-"
    local tcp_var_show="$tcp_var"
    local tls_var_show="$tls_var"
    local ttfb_var_show="$ttfb_var"
    local jitter_compact

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

    table_print_row \
      "$domain" "$code" "$avg_tcp" "$avg_tls" "$avg_ttfb" "$avg_latency" "$jitter_compact" \
      "$tls13" "$x25519" "$h2" "$cert_ok" "$san_level" "$page" "$waf" "$redirect" "$stability" "$score" "$result"
  done < "$sorted_file"

  table_print_rule
}

export_csv() {
  local sorted_file="$1"
  local out="$2"
  {
    echo '"domain","code","avg_tcp","avg_tls","avg_ttfb","avg_latency","jitter","tcp_jitter","tls_jitter","ttfb_jitter","tls13","x25519","h2","cert_ok","san_level","page","waf","redirect","stability","score","result","issuer","final_url","title","content_type","size"'
    while IFS=$'\t' read -r domain code avg_tcp avg_tls avg_ttfb avg_latency jitter tcp_var tls_var ttfb_var tls13 x25519 h2 cert_ok san_level page waf redirect stability score result issuer final_url title ctype size; do
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$domain")" "$(csv_escape "$code")" "$(csv_escape "$avg_tcp")" "$(csv_escape "$avg_tls")" "$(csv_escape "$avg_ttfb")" \
        "$(csv_escape "$avg_latency")" "$(csv_escape "$jitter")" "$(csv_escape "${tcp_var}ms")" "$(csv_escape "${tls_var}ms")" "$(csv_escape "${ttfb_var}ms")" \
        "$(csv_escape "$tls13")" "$(csv_escape "$x25519")" "$(csv_escape "$h2")" "$(csv_escape "$cert_ok")" "$(csv_escape "$san_level")" \
        "$(csv_escape "$page")" "$(csv_escape "$waf")" "$(csv_escape "$redirect")" "$(csv_escape "$stability")" "$(csv_escape "$score")" \
        "$(csv_escape "$result")" "$(csv_escape "$issuer")" "$(csv_escape "$final_url")" "$(csv_escape "$title")" "$(csv_escape "$ctype")" "$(csv_escape "$size")"
    done < "$sorted_file"
  } > "$out"
  echo "CSV 已导出: $out"
}

export_jsonl() {
  local sorted_file="$1"
  local out="$2"
  : > "$out"
  while IFS=$'\t' read -r domain code avg_tcp avg_tls avg_ttfb avg_latency jitter tcp_var tls_var ttfb_var tls13 x25519 h2 cert_ok san_level page waf redirect stability score result issuer final_url title ctype size; do
    printf '{"domain":"%s","code":"%s","avg_tcp":"%s","avg_tls":"%s","avg_ttfb":"%s","avg_latency":"%s","jitter":"%s","tcp_jitter":"%s","tls_jitter":"%s","ttfb_jitter":"%s","tls13":"%s","x25519":"%s","h2":"%s","cert_ok":"%s","san_level":"%s","page":"%s","waf":"%s","redirect":"%s","stability":"%s","score":"%s","result":"%s","issuer":"%s","final_url":"%s","title":"%s","content_type":"%s","size":"%s"}\n' \
      "$(json_escape "$domain")" "$(json_escape "$code")" "$(json_escape "$avg_tcp")" "$(json_escape "$avg_tls")" "$(json_escape "$avg_ttfb")" \
      "$(json_escape "$avg_latency")" "$(json_escape "$jitter")" "$(json_escape "${tcp_var}ms")" "$(json_escape "${tls_var}ms")" "$(json_escape "${ttfb_var}ms")" \
      "$(json_escape "$tls13")" "$(json_escape "$x25519")" "$(json_escape "$h2")" "$(json_escape "$cert_ok")" "$(json_escape "$san_level")" \
      "$(json_escape "$page")" "$(json_escape "$waf")" "$(json_escape "$redirect")" "$(json_escape "$stability")" "$(json_escape "$score")" \
      "$(json_escape "$result")" "$(json_escape "$issuer")" "$(json_escape "$final_url")" "$(json_escape "$title")" "$(json_escape "$ctype")" "$(json_escape "$size")" >> "$out"
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
    if (only_good=="1" && !ok_result($21)) keep=0
    if (!ok_score($20)) keep=0
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

  tmp_dir="$(mktemp -d)"
  TMP_ROOT="$tmp_dir"
  trap '[ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"' EXIT

  for domain in "${domains[@]}"; do
    idx=$((idx + 1))
    out_file="$tmp_dir/$idx.tsv"
    run_with_limit "$JOBS" env -u LC_ALL LANG="${LANG:-${LC_CTYPE:-C.UTF-8}}" LC_CTYPE="${LC_CTYPE:-${LANG:-C.UTF-8}}" TIMEOUT_SEC="$TIMEOUT_SEC" SAMPLES="$SAMPLES" TMP_ROOT="$tmp_dir" UTF8_BOOTSTRAP_DONE=1 bash "$0" --worker "$domain" > "$out_file"
  done
  wait

  result_file="$tmp_dir/all.tsv"
  cat "$tmp_dir"/*.tsv 2>/dev/null > "$result_file"

  filtered_file="$tmp_dir/filtered.tsv"
  filter_results "$result_file" "$filtered_file"

  sorted_file="$tmp_dir/sorted.tsv"
  awk -F'\t' '
  {
    rank = ($21=="推荐"?4:($21=="可用"?3:($21=="勉强"?2:1)))
    print rank "\t" $20 "\t" $9 "\t" $10 "\t" $0
  }' "$filtered_file" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3n -k4,4n | cut -f5- > "$sorted_file"

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
