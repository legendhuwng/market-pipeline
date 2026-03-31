#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  market-pipeline — STRESS TEST v2 (True Saturation Finder)
#  Chạy: chmod +x stress_test.sh && ./stress_test.sh
#  Yêu cầu: apache2-utils (sudo apt install apache2-utils)
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; GRAY='\033[0;90m'; NC='\033[0m'

INGEST_URL="http://localhost:8080"
GENERATOR_URL="http://localhost:8081"
REPORT_URL="http://localhost:8085"
ETL_URL="http://localhost:8084"
RABBIT_API="http://localhost:15672/api"
RABBIT_CRED="rabbit_user:rabbit123"
MYSQL="docker exec market-mysql mysql -umarket_user -pmarket123 -s -N"
REDIS="docker exec market-redis redis-cli -a redis123"

sep()  { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }
hdr()  { echo -e "\n${BOLD}${YELLOW}[$1]${NC}"; sep; }
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
err()  { echo -e "  ${RED}✘${NC} $1"; }
inf()  { echo -e "  ${CYAN}→${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
dim()  { echo -e "  ${GRAY}$1${NC}"; }

q_depth() {
  curl -s -u "$RABBIT_CRED" "$RABBIT_API/queues/%2F/$1" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages',0))" 2>/dev/null || echo 0
}

kafka_lag() {
  docker exec market-kafka kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --group raw-consumer-group --describe 2>/dev/null \
    | grep market.trades | awk '{sum+=$6} END{print sum+0}'
}

declare -A RESULT

# ── 0. PRE-FLIGHT ────────────────────────────────────────────
hdr "0. PRE-FLIGHT"

command -v ab &>/dev/null && { ok "ab found"; HAS_AB=1; } \
  || { warn "ab không có — cài: sudo apt install apache2-utils"; HAS_AB=0; }

TOKEN=$(curl -s -X POST "$REPORT_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -z "$TOKEN" ] && { err "Không lấy được JWT token"; exit 1; }
ok "JWT token OK"

curl -s -X POST "$GENERATOR_URL/generator/stop" > /dev/null
sleep 2; ok "Generator stopped"

PAYLOAD=$(mktemp /tmp/trade.XXXXXX.json)
echo '{"eventId":"PLACEHOLDER","symbol":"VCB","price":85.5,"volume":1000,"eventTime":"2026-04-01T10:00:00"}' > "$PAYLOAD"

# ═══════════════════════════════════════════════════════════════
# LAYER 1 — INGEST HTTP SATURATION
# Tăng concurrency đến khi error > 1% hoặc p99 > 1000ms
# ═══════════════════════════════════════════════════════════════
hdr "1. INGEST — HTTP Saturation (tăng đến điểm gãy)"
inf "1000 requests mỗi level. Dừng khi error > 1% hoặc p99 > 1000ms"
echo
printf "  ${BOLD}%-10s %-10s %-10s %-10s %-10s %-12s${NC}\n" \
  "c" "req/s" "p50(ms)" "p95(ms)" "p99(ms)" "status"
printf "  %-10s %-10s %-10s %-10s %-10s %-12s\n" \
  "---" "-----" "-------" "-------" "-------" "------"

INGEST_MAX_RPS=0; INGEST_SAT_C=0

for C in 1 5 10 20 50 100 200 500 1000; do
  if [ "$HAS_AB" -eq 1 ]; then
    OUT=$(ab -n 1000 -c $C -p "$PAYLOAD" -T "application/json" -r \
      "$INGEST_URL/api/trades" 2>/dev/null)
    RPS=$(echo "$OUT"    | grep "Requests per second" | awk '{printf "%.0f",$4}')
    P50=$(echo "$OUT"    | grep "^ *50%" | awk '{print $2}')
    P95=$(echo "$OUT"    | grep "^ *95%" | awk '{print $2}')
    P99=$(echo "$OUT"    | grep "^ *99%" | awk '{print $2}')
    NON2XX=$(echo "$OUT" | grep "Non-2xx" | awk '{print $NF}')
    FAILED=$(echo "$OUT" | grep "Failed requests" | awk '{print $NF}')
    ERRORS=$(( ${NON2XX:-0} + ${FAILED:-0} ))
  else
    START_T=$(date +%s%3N)
    for i in $(seq 1 1000); do
      curl -s -o /dev/null -X POST "$INGEST_URL/api/trades" \
        -H "Content-Type: application/json" \
        -d "{\"eventId\":\"s$C-$i-$RANDOM\",\"symbol\":\"VCB\",\"price\":85.5,\"volume\":1000,\"eventTime\":\"2026-04-01T10:00:00\"}" &
    done; wait
    END_T=$(date +%s%3N)
    EL=$(( END_T - START_T ))
    RPS=$(echo "scale=0; 1000*1000/$EL" | bc)
    P50="n/a"; P95="n/a"; P99=0; ERRORS=0
  fi

  STATUS="${GREEN}OK${NC}"
  if (( ${ERRORS:-0} > 10 )) || (( ${P99:-0} > 1000 )); then
    STATUS="${RED}SATURATED${NC}"
    [ "$INGEST_SAT_C" -eq 0 ] && INGEST_SAT_C=$C
  elif (( ${P99:-0} > 200 )); then
    STATUS="${YELLOW}DEGRADED${NC}"
  fi

  [ "${RPS:-0}" -gt "$INGEST_MAX_RPS" ] && INGEST_MAX_RPS=${RPS:-0}
  printf "  %-10s %-10s %-10s %-10s %-10s " \
    "c=$C" "${RPS:-?}" "${P50:-?}" "${P95:-?}" "${P99:-?}"
  echo -e "${STATUS}"

  [ "$INGEST_SAT_C" -gt 0 ] && break
  sleep 1
done

echo
RESULT[ingest]="${INGEST_MAX_RPS} req/s, sat@c=${INGEST_SAT_C:-">1000"}"
[ "$INGEST_SAT_C" -gt 0 ] \
  && warn "Saturation tại c=$INGEST_SAT_C" \
  || ok "Không thấy saturation đến c=1000"

# ═══════════════════════════════════════════════════════════════
# LAYER 2a — KAFKA PRODUCER MAX
# ═══════════════════════════════════════════════════════════════
hdr "2a. KAFKA PRODUCER — Max Throughput (50k messages)"

OUT=$(docker exec market-kafka \
  kafka-producer-perf-test \
  --topic market.trades \
  --num-records 50000 \
  --record-size 200 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:9092 acks=1 \
  2>&1 | tail -1)
echo "  $OUT"
echo

# Parse đúng: "25380.710660 records/sec" → lấy số nguyên trước dấu chấm
KAFKA_PROD_RPS=$(echo "$OUT" | grep -oP '\d+\.\d+ records/sec' | grep -oP '^\d+')
KAFKA_MB=$(echo "$OUT"       | grep -oP '[\d.]+ MB/sec'        | grep -oP '^[\d.]+')
KAFKA_P99=$(echo "$OUT"      | grep -oP '\d+ ms 99th'          | grep -oP '^\d+')
KAFKA_AVG=$(echo "$OUT"      | grep -oP '[\d.]+ ms avg'        | grep -oP '^[\d.]+')

inf "Producer max: ${KAFKA_PROD_RPS} msg/s | ${KAFKA_MB} MB/s"
inf "Latency: avg=${KAFKA_AVG}ms  p99=${KAFKA_P99}ms"
RESULT[kafka_prod]="${KAFKA_PROD_RPS} msg/s @ p99=${KAFKA_P99}ms"

# ═══════════════════════════════════════════════════════════════
# LAYER 2b — KAFKA CONSUMER THROUGHPUT (flood 30s liên tục)
# ═══════════════════════════════════════════════════════════════
hdr "2b. KAFKA CONSUMER — Throughput (flood 30s liên tục)"
inf "Flood @ 5000 msg/s trong 30s, đo consumer rows/s thực tế"

RAW_BEFORE=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)

# Flood background
docker exec -d market-kafka \
  kafka-producer-perf-test \
  --topic market.trades \
  --num-records 999999 \
  --record-size 200 \
  --throughput 5000 \
  --producer-props bootstrap.servers=localhost:9092 acks=0 \
  > /dev/null 2>&1 &
FLOOD_PID=$!

printf "  ${BOLD}%-8s %-12s %-12s %-15s${NC}\n" \
  "t(s)" "kafka_lag" "raw_rows" "rows/s"
printf "  %-8s %-12s %-12s %-15s\n" \
  "---" "---------" "--------" "------"

PREV_RAW=$RAW_BEFORE
MAX_CONSUME_RATE=0

for T in 5 10 15 20 25 30; do
  sleep 5
  LAG=$(kafka_lag)
  RAW_NOW=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
  DELTA=$(( RAW_NOW - PREV_RAW ))
  RATE=$(echo "scale=0; $DELTA / 5" | bc 2>/dev/null || echo 0)
  [ "${RATE:-0}" -gt "$MAX_CONSUME_RATE" ] && MAX_CONSUME_RATE=$RATE
  printf "  %-8s %-12s %-12s %-15s\n" \
    "t=${T}s" "${LAG:-?}" "${RAW_NOW}" "${RATE} rows/s"
  PREV_RAW=$RAW_NOW
done

kill $FLOOD_PID 2>/dev/null; wait $FLOOD_PID 2>/dev/null
FINAL_LAG=$(kafka_lag)

echo
inf "Consumer max throughput: ${MAX_CONSUME_RATE} rows/s"
inf "Kafka lag sau flood: ${FINAL_LAG}"
RESULT[kafka_consumer]="${MAX_CONSUME_RATE} rows/s (lag=${FINAL_LAG})"

# ═══════════════════════════════════════════════════════════════
# LAYER 3 — MYSQL THROUGHPUT
# ═══════════════════════════════════════════════════════════════
hdr "3. MYSQL — Insert & Select Throughput"

# Bulk insert 1000 rows
START_T=$(date +%s%3N)
docker exec market-mysql mysql -umarket_user -pmarket123 market_raw -e "
  INSERT INTO raw_trade (event_id, symbol, price, volume, event_time, created_at)
  WITH RECURSIVE gen(n) AS (
    SELECT 1 UNION ALL SELECT n+1 FROM gen WHERE n < 1000
  )
  SELECT
    CONCAT('bench-', n, '-', UNIX_TIMESTAMP()),
    ELT(1 + MOD(n,5), 'VCB','VNM','HPG','FPT','MSN'),
    80 + MOD(n,20), n * 100,
    DATE_SUB(NOW(), INTERVAL n SECOND), NOW()
  FROM gen;
" 2>/dev/null
END_T=$(date +%s%3N)
INSERT_MS=$(( END_T - START_T ))
INSERT_RPS=$(echo "scale=0; 1000 * 1000 / $INSERT_MS" | bc)
inf "Bulk insert 1000 rows: ${INSERT_MS}ms → ${INSERT_RPS} rows/s"
RESULT[mysql_insert]="${INSERT_RPS} rows/s"

# ETL-style SELECT (100 queries)
START_T=$(date +%s%3N)
for i in $(seq 1 100); do
  $MYSQL -e "SELECT * FROM market_raw.raw_trade \
    WHERE symbol='VCB' AND event_time > DATE_SUB(NOW(), INTERVAL 1 HOUR) \
    LIMIT 200;" > /dev/null 2>&1
done
END_T=$(date +%s%3N)
SEL_MS=$(( END_T - START_T ))
SEL_QPS=$(echo "scale=0; 100 * 1000 / $SEL_MS" | bc)
inf "ETL-style SELECT (indexed): ${SEL_QPS} queries/s"
RESULT[mysql_select]="${SEL_QPS} qps"

# ═══════════════════════════════════════════════════════════════
# LAYER 4 — RABBITMQ + ETL SATURATION
# Tăng batch: 50 → 100 → 200 → 500 jobs
# ═══════════════════════════════════════════════════════════════
hdr "4. RABBITMQ + ETL WORKER — Batch Saturation"
inf "Tăng batch size để tìm ETL max jobs/s"
echo
printf "  ${BOLD}%-12s %-12s %-12s %-12s %-10s${NC}\n" \
  "batch" "drain(ms)" "jobs/s" "avg_dur" "dlq"
printf "  %-12s %-12s %-12s %-12s %-10s\n" \
  "-----" "---------" "------" "-------" "---"

ALL_JOBS=$($MYSQL -e \
  "SELECT job_id FROM market_raw.job_execution WHERE status='SUCCESS';" 2>/dev/null)
TOTAL_AVAIL=$(echo "$ALL_JOBS" | grep -c .)
ETL_MAX_JPS=0

for BATCH in 50 100 200 500; do
  if [ "$BATCH" -gt "$TOTAL_AVAIL" ]; then
    dim "  skip batch=$BATCH (only $TOTAL_AVAIL jobs available)"
    continue
  fi

  # Publish batch jobs song song
  echo "$ALL_JOBS" | head -$BATCH | while read JID; do
    [ -z "$JID" ] && continue
    curl -s -X POST "$ETL_URL/jobs/reprocess/$JID" -o /dev/null &
  done; wait

  # Drain
  DRAIN_START=$(date +%s%3N)
  for i in $(seq 1 120); do
    Q=$(q_depth "etl.staging")
    [ "${Q:-1}" -eq 0 ] && break
    sleep 1
  done
  DRAIN_MS=$(( $(date +%s%3N) - DRAIN_START ))
  JPS=$(echo "scale=1; $BATCH * 1000 / $DRAIN_MS" | bc 2>/dev/null || echo "?")

  STATS=$(curl -s "$ETL_URL/jobs/stats" 2>/dev/null)
  AVG=$(echo "$STATS" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('avgDurationMs','?'))" 2>/dev/null)
  DLQ=$(q_depth "etl.staging.dlq")

  printf "  %-12s %-12s %-12s %-12s %-10s\n" \
    "$BATCH jobs" "${DRAIN_MS}ms" "${JPS}" "${AVG}" "${DLQ}"

  JPSN=$(echo "$JPS" | cut -d'.' -f1)
  [ "${JPSN:-0}" -gt "$ETL_MAX_JPS" ] && ETL_MAX_JPS=${JPSN:-0}
  sleep 2
done

echo
RESULT[etl_worker]="${ETL_MAX_JPS} jobs/s peak"
inf "ETL Worker peak: ${ETL_MAX_JPS} jobs/s"

# ═══════════════════════════════════════════════════════════════
# LAYER 5 — REPORT SERVICE SATURATION (đến điểm gãy)
# ═══════════════════════════════════════════════════════════════
hdr "5. REPORT SERVICE — Concurrency Saturation"
inf "Tăng c: 1→10→25→50→100→200→500. Dừng khi avg > 2000ms"
echo
printf "  ${BOLD}%-10s %-12s %-12s %-12s %-12s${NC}\n" \
  "c" "total(ms)" "avg(ms)" "rps" "status"
printf "  %-10s %-12s %-12s %-12s %-12s\n" \
  "---" "---------" "-------" "---" "------"

REPORT_MAX_RPS=0; REPORT_SAT_C=0; BASELINE_AVG=0

for C in 1 10 25 50 100 200 500; do
  START_T=$(date +%s%3N)
  for i in $(seq 1 $C); do
    curl -s -o /dev/null \
      "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
      -H "Authorization: Bearer $TOKEN" &
  done; wait
  TOTAL=$(( $(date +%s%3N) - START_T ))
  AVG=$(echo "scale=0; $TOTAL / $C" | bc)
  RPS=$(echo "scale=1; $C * 1000 / $TOTAL" | bc)
  [ "$C" -eq 1 ] && BASELINE_AVG=$AVG

  STATUS="OK"; COLOR="$GREEN"
  if (( AVG > 2000 )); then
    STATUS="SATURATED"; COLOR="$RED"
    [ "$REPORT_SAT_C" -eq 0 ] && REPORT_SAT_C=$C
  elif (( AVG > 500 )); then
    STATUS="DEGRADED"; COLOR="$YELLOW"
    [ "$REPORT_SAT_C" -eq 0 ] && REPORT_SAT_C=$C
  fi

  RPS_N=$(echo "$RPS" | cut -d'.' -f1)
  [ "${RPS_N:-0}" -gt "$REPORT_MAX_RPS" ] && REPORT_MAX_RPS=${RPS_N:-0}

  printf "  %-10s %-12s %-12s %-12s " "c=$C" "${TOTAL}ms" "${AVG}ms" "${RPS}"
  echo -e "${COLOR}${STATUS}${NC}"
  [ "$REPORT_SAT_C" -gt 0 ] && break
  sleep 1
done

echo
RESULT[report]="${REPORT_MAX_RPS} rps peak, sat@c=${REPORT_SAT_C:-">500"}"
[ "$REPORT_SAT_C" -gt 0 ] \
  && warn "Report saturates @ c=$REPORT_SAT_C" \
  || ok "Report stable đến c=500"

# ═══════════════════════════════════════════════════════════════
# LAYER 6 — REDIS CACHE UNDER LOAD
# ═══════════════════════════════════════════════════════════════
hdr "6. REDIS CACHE — Hit vs Miss Under 100 Concurrent"

$REDIS CONFIG RESETSTAT > /dev/null 2>&1

# Warm cache
SYMBOLS=$($MYSQL -e "SELECT DISTINCT symbol FROM market_dw.fact_market_1m;" 2>/dev/null)
for SYM in $SYMBOLS; do
  curl -s -o /dev/null "$REPORT_URL/api/stocks?symbol=$SYM&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN"
done
inf "Cache warmed ($(echo "$SYMBOLS" | wc -w) symbols)"

# 100 concurrent cache HIT
START_T=$(date +%s%3N)
for i in $(seq 1 100); do
  curl -s -o /dev/null "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN" &
done; wait
HIT_MS=$(( $(date +%s%3N) - START_T ))

# Bust cache
$REDIS KEYS "stock:*" 2>/dev/null | xargs -r $REDIS DEL > /dev/null 2>&1
sleep 1

# 100 concurrent cache MISS
START_T=$(date +%s%3N)
for i in $(seq 1 100); do
  curl -s -o /dev/null "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN" &
done; wait
MISS_MS=$(( $(date +%s%3N) - START_T ))

HIT_AVG=$(echo "scale=0; $HIT_MS/100"  | bc)
MISS_AVG=$(echo "scale=0; $MISS_MS/100" | bc)
inf "100 concurrent cache HIT : ${HIT_MS}ms total | avg ${HIT_AVG}ms/req"
inf "100 concurrent cache MISS: ${MISS_MS}ms total | avg ${MISS_AVG}ms/req"

HITS=$($REDIS INFO stats 2>/dev/null   | grep "^keyspace_hits:"   | cut -d: -f2 | tr -d '\r')
MISSES=$($REDIS INFO stats 2>/dev/null | grep "^keyspace_misses:" | cut -d: -f2 | tr -d '\r')
TOTAL_OPS=$(( ${HITS:-0} + ${MISSES:-0} ))
[ "$TOTAL_OPS" -gt 0 ] && \
  HIT_RATE=$(echo "scale=1; ${HITS:-0} * 100 / $TOTAL_OPS" | bc)
inf "Redis cumulative hit rate: ${HIT_RATE:-?}% (hits=${HITS} misses=${MISSES})"

if [ "${HIT_MS:-9999}" -lt "${MISS_MS:-0}" ]; then
  SPEEDUP=$(echo "scale=2; $MISS_MS / $HIT_MS" | bc 2>/dev/null || echo "?")
  ok "Cache speedup: ${SPEEDUP}x under 100 concurrent"
  RESULT[redis]="${SPEEDUP}x speedup, hit_rate=${HIT_RATE:-?}%"
else
  warn "Cache không nhanh hơn DB (dataset quá nhỏ)"
  RESULT[redis]="neutral, hit_rate=${HIT_RATE:-?}%"
fi

# ═══════════════════════════════════════════════════════════════
# LAYER 7 — END-TO-END PIPELINE (60s sustained)
# ═══════════════════════════════════════════════════════════════
hdr "7. END-TO-END PIPELINE — 60s Sustained Throughput"
inf "Generator @ 50ms → snapshot mỗi 10s → đo events/s và facts/s"

# Snapshot T=0
RAW_T0=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_T0=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)

curl -s -X POST "$GENERATOR_URL/generator/speed?ms=50" > /dev/null
curl -s -X POST "$GENERATOR_URL/generator/start" > /dev/null
inf "Generator started @ 50ms"

printf "  ${BOLD}%-8s %-12s %-12s %-12s %-10s${NC}\n" \
  "t(s)" "raw_total" "fact_total" "kafka_lag" "rabbit_q"
printf "  %-8s %-12s %-12s %-12s %-10s\n" \
  "---" "---------" "----------" "---------" "--------"

for T in 10 20 30 40 50 60; do
  sleep 10
  RAW_N=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
  FACT_N=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)
  LAG=$(kafka_lag)
  RQ=$(q_depth "etl.staging")
  printf "  %-8s %-12s %-12s %-12s %-10s\n" \
    "t=${T}s" "${RAW_N}" "${FACT_N}" "${LAG:-0}" "${RQ:-0}"
done

# Throttle back
curl -s -X POST "$GENERATOR_URL/generator/speed?ms=500" > /dev/null

RAW_T1=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_T1=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)
FINAL_LAG=$(kafka_lag)
FINAL_DLQ=$(q_depth "etl.staging.dlq")

RAW_DIFF=$(( RAW_T1 - RAW_T0 ))
FACT_DIFF=$(( FACT_T1 - FACT_T0 ))
RAW_RPS=$(echo "scale=1; $RAW_DIFF / 60" | bc 2>/dev/null || echo "?")
FACT_RPS=$(echo "scale=1; $FACT_DIFF / 60" | bc 2>/dev/null || echo "?")

echo
inf "Events ingested  : ${RAW_DIFF}  (~${RAW_RPS} events/s)"
inf "Facts created    : ${FACT_DIFF} (~${FACT_RPS} facts/s)"
inf "Kafka lag final  : ${FINAL_LAG:-0}"
inf "DLQ final        : ${FINAL_DLQ:-0}"
[ "${FINAL_DLQ:-0}" -eq 0 ] && ok "No data loss (DLQ=0)" \
  || err "DLQ=${FINAL_DLQ} — có job dropped"
RESULT[e2e]="${RAW_RPS} events/s ingest | ${FACT_RPS} facts/s ETL"

# ═══════════════════════════════════════════════════════════════
# LAYER 8 — RESOURCE USAGE
# ═══════════════════════════════════════════════════════════════
hdr "8. RESOURCE USAGE — Container Stats (sau stress)"
echo
printf "  ${BOLD}%-25s %-12s %-20s${NC}\n" "Container" "CPU%" "Memory"
printf "  %-25s %-12s %-20s\n" "---------" "----" "------"

for CTR in market-ingest market-raw-consumer market-etl market-report \
           market-generator market-kafka market-mysql market-redis market-rabbitmq; do
  STATS=$(docker stats --no-stream \
    --format "{{.CPUPerc}}\t{{.MemUsage}}" "$CTR" 2>/dev/null)
  CPU=$(echo "$STATS" | cut -f1)
  MEM=$(echo "$STATS" | cut -f2)
  [ -n "$CPU" ] && printf "  %-25s %-12s %-20s\n" "$CTR" "${CPU}" "${MEM}"
done

# ═══════════════════════════════════════════════════════════════
# SATURATION SUMMARY
# ═══════════════════════════════════════════════════════════════
hdr "SATURATION SUMMARY"
echo
printf "  ${BOLD}%-28s %-38s %-20s${NC}\n" "Layer" "Max Throughput" "Bottleneck"
sep
printf "  %-28s %-38s %-20s\n" "Ingest HTTP"       "${RESULT[ingest]:-?}"        "Tomcat threads"
printf "  %-28s %-38s %-20s\n" "Kafka producer"    "${RESULT[kafka_prod]:-?}"     "single broker"
printf "  %-28s %-38s %-20s\n" "Kafka consumer"    "${RESULT[kafka_consumer]:-?}" "batch-size=200"
printf "  %-28s %-38s %-20s\n" "MySQL insert"      "${RESULT[mysql_insert]:-?}"   "InnoDB flush"
printf "  %-28s %-38s %-20s\n" "MySQL select"      "${RESULT[mysql_select]:-?}"   "index scan"
printf "  %-28s %-38s %-20s\n" "ETL Worker"        "${RESULT[etl_worker]:-?}"     "2-5 consumers"
printf "  %-28s %-38s %-20s\n" "Report Service"    "${RESULT[report]:-?}"         "HikariCP pool=10"
printf "  %-28s %-38s %-20s\n" "Redis Cache"       "${RESULT[redis]:-?}"          "dataset size"
printf "  %-28s %-38s %-20s\n" "E2E Pipeline"      "${RESULT[e2e]:-?}"            "consumer drain"
sep
echo

rm -f "$PAYLOAD"
echo -e "${BOLD}Done. Runtime: ~8-10 phút${NC}"