#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# lib.sh  –  Shared config + helpers cho toàn bộ load test suite
# Source file này vào mỗi script:  source "$(dirname "$0")/lib.sh"
# ─────────────────────────────────────────────────────────────

# ── Endpoints (khớp với application.yml) ─────────────────────
INGEST_URL="http://localhost:8080"
CONSUMER_URL="http://localhost:8082"
ETL_URL="http://localhost:8084"
REPORT_URL="http://localhost:8085"
RABBIT_API="http://localhost:15672/api"
RABBIT_USER="rabbit_user"
RABBIT_PASS="rabbit123"
REDIS_PASS="redis123"
KAFKA_CONTAINER="market-kafka"
MYSQL_CONTAINER="market-mysql"
MYSQL_USER="market_user"
MYSQL_PASS="market123"

# ── Màu sắc terminal ──────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Symbols + base price (khớp với FakeGeneratorService.java) ─
SYMBOLS=("VCB" "VNM" "HPG" "FPT" "MSN" "TCB" "BID" "CTG" "VIC" "GAS")
declare -A BASE_PRICE=([VCB]=85 [VNM]=68 [HPG]=27 [FPT]=120
                       [MSN]=55 [TCB]=32 [BID]=44 [CTG]=31 [VIC]=42 [GAS]=78)

# ── Logging ───────────────────────────────────────────────────
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"; }
info() { echo -e "${CYAN}$*${NC}"; }
sep()  { echo -e "${BOLD}$(printf '─%.0s' {1..60})${NC}"; }
h1()   { echo ""; sep; echo -e "${BOLD}  $*${NC}"; sep; }

# ── UUID v4 (bash thuần) ──────────────────────────────────────
gen_uuid() {
  local N B C='89ab'
  for (( N=0; N < 16; N++ )); do
    B=$(( RANDOM % 256 ))
    case $N in
      6) printf '4%x'  $(( B % 16 )) ;;
      8) printf '%c%x' "${C:$(( RANDOM % 4 )):1}" $(( B % 16 )) ;;
      3|5|7|9) printf '%02x-' $B ;;
      *) printf '%02x' $B ;;
    esac
  done
  echo
}

# ── Random trade event JSON ───────────────────────────────────
random_trade() {
  local sym="${SYMBOLS[$(( RANDOM % ${#SYMBOLS[@]} ))]}"
  local base="${BASE_PRICE[$sym]}"
  # price = base ± 1%
  local cents=$(( base * 100 + RANDOM % ( base * 2 ) - base ))
  local price
  printf -v price "%.2f" "$(echo "scale=4; $cents / 100" | bc)"
  local vol=$(( ( RANDOM % 200 + 1 ) * 100 ))
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  local id
  id=$(gen_uuid)
  printf '{"eventId":"%s","symbol":"%s","price":%s,"volume":%d,"eventTime":"%s"}' \
    "$id" "$sym" "$price" "$vol" "$ts"
}

# ── Lấy JWT token cho Report Service ─────────────────────────
get_token() {
  local user="${1:-user}" pass="${2:-user123}"
  curl -sf -X POST "${REPORT_URL}/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4
}

# ── RabbitMQ queue info (ready / unacked / total / rate_in) ───
rabbit_queue() {
  local q="$1"
  curl -sf -u "${RABBIT_USER}:${RABBIT_PASS}" \
    "${RABBIT_API}/queues/%2F/${q}" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
ms=d.get('message_stats',{})
print('{:<25} ready={:<6} unacked={:<6} total={:<6} in={:.1f}/s out={:.1f}/s'.format(
  d.get('name','?'),
  d.get('messages_ready',0),
  d.get('messages_unacked',0),
  d.get('messages',0),
  ms.get('publish_details',{}).get('rate',0),
  ms.get('deliver_get_details',{}).get('rate',0),
))" 2>/dev/null || echo "  ${q}: (unavailable)"
}

# ── ETL job stats ─────────────────────────────────────────────
etl_stats() {
  curl -sf "${ETL_URL}/jobs/stats" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('total={total} success={success} failed={failed} running={running} dlq={dlqMessages} | rate={successRate} avg={avgDurationMs}'.format(**d)
)" 2>/dev/null || echo "ETL stats unavailable"
}

# ── Kafka consumer lag ────────────────────────────────────────
kafka_lag() {
  docker exec "${KAFKA_CONTAINER}" \
    kafka-consumer-groups --bootstrap-server localhost:9092 \
    --describe --group raw-consumer-group 2>/dev/null \
  | awk 'NR>1 && $6 ~ /^[0-9]+$/ {printf "  partition=%-3s  lag=%-6s  offset=%s\n", $3, $6, $4}' \
  || echo "  (kafka lag unavailable)"
}

# ── Redis hit ratio ───────────────────────────────────────────
redis_stats() {
  docker exec market-redis \
    redis-cli -a "${REDIS_PASS}" --no-auth-warning info stats 2>/dev/null \
  | python3 -c "
import sys
d={}
for l in sys.stdin:
    l=l.strip()
    if ':' in l: k,v=l.split(':',1); d[k]=v
hits=int(d.get('keyspace_hits',0)); misses=int(d.get('keyspace_misses',0))
ops=d.get('instantaneous_ops_per_sec','?')
ratio=hits/(hits+misses)*100 if hits+misses>0 else 0
print(f'hits={hits} misses={misses} hit_ratio={ratio:.1f}% ops/s={ops}')
" 2>/dev/null || echo "Redis stats unavailable"
}

# ── MySQL row count ───────────────────────────────────────────
mysql_count() {
  local db="$1" tbl="$2"
  docker exec "${MYSQL_CONTAINER}" \
    mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -N -e \
    "SELECT COUNT(*) FROM ${db}.${tbl};" 2>/dev/null || echo "?"
}

# ── Ghi kết quả ra file CSV ───────────────────────────────────
# Dùng: csv_append <file> <col1> <col2> ...
csv_append() {
  local file="$1"; shift
  echo "$(date '+%H:%M:%S'),$*" >> "$file"
}

# ── In bảng kết quả cuối ──────────────────────────────────────
print_table() {
  # Đọc CSV và in dạng bảng
  local file="$1"
  if [[ ! -f "$file" ]]; then echo "No data"; return; fi
  column -t -s',' "$file"
}
