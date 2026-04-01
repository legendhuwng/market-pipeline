#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  market-pipeline — MAX LOAD TEST
#  Mục tiêu: tìm điểm VỠ thật sự của từng layer
#  Chạy: chmod +x max_load_test.sh && ./max_load_test.sh
#  Yêu cầu: apache2-utils (sudo apt install apache2-utils)
#  Thời gian: ~20 phút
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

sep()   { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }
hdr()   { echo -e "\n${BOLD}${YELLOW}▶ $1${NC}"; sep; }
ok()    { echo -e "  ${GREEN}✔${NC} $1"; }
err()   { echo -e "  ${RED}✘${NC} $1"; }
inf()   { echo -e "  ${CYAN}→${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
brk()   { echo -e "  ${RED}💥 BREAKING POINT:${NC} $1"; }
peak()  { echo -e "  ${GREEN}🏆 PEAK:${NC} $1"; }

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
declare -A BREAK_AT

# ══════════════════════════════════════════════════════════════
# 0. PRE-FLIGHT
# ══════════════════════════════════════════════════════════════
hdr "0. PRE-FLIGHT"

command -v ab &>/dev/null && { ok "ab found"; HAS_AB=1; } \
  || { err "ab chưa cài — sudo apt install apache2-utils"; exit 1; }

TOKEN=$(curl -s -X POST "$REPORT_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -z "$TOKEN" ] && { err "Không lấy được JWT token"; exit 1; }
ok "JWT token OK"

curl -s -X POST "$GENERATOR_URL/generator/stop" > /dev/null
sleep 2; ok "Generator stopped"

# Kiểm tra Kafka lag
LAG=$(kafka_lag)
if [ "${LAG:-0}" -gt 1000 ]; then
  warn "Kafka lag ${LAG} — cần reset trước"
  inf "Chạy: docker compose stop raw-consumer && sleep 35 && kafka reset && docker compose start raw-consumer"
  exit 1
fi
ok "Kafka lag sạch (${LAG:-0})"

PAYLOAD=$(mktemp /tmp/trade.XXXXXX.json)
echo '{"eventId":"maxload-placeholder","symbol":"VCB","price":85.5,"volume":1000,"eventTime":"2026-04-01T10:00:00"}' > "$PAYLOAD"

# Warm up JVM
inf "Warming up JVM (50 requests)..."
ab -n 50 -c 5 -p "$PAYLOAD" -T "application/json" \
  "$INGEST_URL/api/trades" > /dev/null 2>&1
sleep 3; ok "JVM warmed"

# ══════════════════════════════════════════════════════════════
# LAYER 1 — INGEST: TÌM ĐIỂM VỠ THẬT SỰ
# Tăng concurrency đến khi p99 > 1000ms hoặc error > 1%
# Dùng 2000 requests mỗi level để đo chính xác hơn
# ══════════════════════════════════════════════════════════════
hdr "1. INGEST MAX — HTTP Breaking Point"
inf "2000 requests/level. Tăng đến khi p99 > 1000ms hoặc Failed > 20"
echo
printf "  ${BOLD}%-10s %-10s %-10s %-10s %-10s %-10s %-12s${NC}\n" \
  "c" "req/s" "p50" "p95" "p99" "failed" "status"
printf "  %-10s %-10s %-10s %-10s %-10s %-10s %-12s\n" \
  "---" "-----" "---" "---" "---" "------" "------"

INGEST_PEAK_RPS=0; INGEST_PEAK_C=0; INGEST_BREAK_C=0

for C in 1 5 10 20 50 100 200 300 500 750 1000; do
  OUT=$(ab -n 2000 -c $C -p "$PAYLOAD" -T "application/json" -r \
    "$INGEST_URL/api/trades" 2>/dev/null)
  RPS=$(echo "$OUT"    | grep "Requests per second" | awk '{printf "%.0f",$4}')
  P50=$(echo "$OUT"    | grep "^ *50%" | awk '{print $2}')
  P95=$(echo "$OUT"    | grep "^ *95%" | awk '{print $2}')
  P99=$(echo "$OUT"    | grep "^ *99%" | awk '{print $2}')
  FAILED=$(echo "$OUT" | grep "Failed requests" | awk '{print $NF}')
  FAILED=${FAILED:-0}

  STATUS="${GREEN}OK${NC}"; STOP=0
  if (( ${FAILED:-0} > 20 )) || (( ${P99:-0} > 2000 )); then
    STATUS="${RED}BROKEN${NC}"; STOP=1
    [ "$INGEST_BREAK_C" -eq 0 ] && INGEST_BREAK_C=$C
  elif (( ${P99:-0} > 1000 )); then
    STATUS="${YELLOW}DEGRADED${NC}"
    [ "$INGEST_BREAK_C" -eq 0 ] && INGEST_BREAK_C=$C
  fi

  [ "${RPS:-0}" -gt "$INGEST_PEAK_RPS" ] && {
    INGEST_PEAK_RPS=${RPS:-0}
    INGEST_PEAK_C=$C
  }

  printf "  %-10s %-10s %-10s %-10s %-10s %-10s " \
    "c=$C" "${RPS:-?}" "${P50:-?}ms" "${P95:-?}ms" "${P99:-?}ms" "${FAILED}"
  echo -e "${STATUS}"
  [ "$STOP" -eq 1 ] && break
  sleep 1
done

echo
RESULT[ingest]="${INGEST_PEAK_RPS} req/s @ c=${INGEST_PEAK_C}"
BREAK_AT[ingest]="c=${INGEST_BREAK_C:-">1000"}"
peak "Ingest: ${INGEST_PEAK_RPS} req/s @ c=${INGEST_PEAK_C}"
brk "Ingest: c=${INGEST_BREAK_C:-">1000"}"

# ══════════════════════════════════════════════════════════════
# LAYER 2 — KAFKA CONSUMER MAX THROUGHPUT
# Dùng Generator tăng dần tốc độ, đo rows/s thực tế
# ══════════════════════════════════════════════════════════════
hdr "2. KAFKA CONSUMER MAX — Tăng dần generator speed"
inf "Tăng interval: 500ms → 100ms → 50ms → 20ms → 10ms → 5ms"
echo
printf "  ${BOLD}%-12s %-12s %-12s %-12s %-12s${NC}\n" \
  "interval" "gen/s" "consume/s" "lag" "status"
printf "  %-12s %-12s %-12s %-12s %-12s\n" \
  "--------" "-----" "---------" "---" "------"

CONSUMER_PEAK=0; CONSUMER_BREAK_MS=0

for MS in 500 200 100 50 20 10 5; do
  curl -s -X POST "$GENERATOR_URL/generator/speed?ms=$MS" > /dev/null
  curl -s -X POST "$GENERATOR_URL/generator/start" > /dev/null
  sleep 15  # ổn định

  RAW_A=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
  sleep 10
  RAW_B=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)

  GEN_STATUS=$(curl -s "$GENERATOR_URL/generator/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sentCount',0))" 2>/dev/null)
  LAG=$(kafka_lag)
  CONSUME_RPS=$(echo "scale=0; ($RAW_B - $RAW_A) / 10" | bc 2>/dev/null || echo 0)
  GEN_RPS=$(echo "scale=0; 1000 / $MS" | bc 2>/dev/null || echo "?")

  STATUS="${GREEN}keeping up${NC}"
  [ "${LAG:-0}" -gt 500 ] && STATUS="${YELLOW}falling behind${NC}"
  [ "${LAG:-0}" -gt 5000 ] && {
    STATUS="${RED}OVERWHELMED${NC}"
    [ "$CONSUMER_BREAK_MS" -eq 0 ] && CONSUMER_BREAK_MS=$MS
  }

  [ "${CONSUME_RPS:-0}" -gt "$CONSUMER_PEAK" ] && CONSUMER_PEAK=${CONSUME_RPS:-0}

  printf "  %-12s %-12s %-12s %-12s " \
    "${MS}ms" "~${GEN_RPS}/s" "${CONSUME_RPS}/s" "${LAG:-0}"
  echo -e "${STATUS}"

  curl -s -X POST "$GENERATOR_URL/generator/stop" > /dev/null
  sleep 3
done

echo
RESULT[consumer]="${CONSUMER_PEAK} rows/s"
BREAK_AT[consumer]="${CONSUMER_BREAK_MS:-"không vỡ"}ms interval"
peak "Consumer: ${CONSUMER_PEAK} rows/s"
[ "$CONSUMER_BREAK_MS" -gt 0 ] \
  && brk "Consumer overwhelmed @ ${CONSUMER_BREAK_MS}ms interval" \
  || ok "Consumer theo kịp tất cả tốc độ"

# ══════════════════════════════════════════════════════════════
# LAYER 3 — MYSQL MAX INSERT
# Tăng dần batch size để tìm throughput ceiling
# ══════════════════════════════════════════════════════════════
hdr "3. MYSQL MAX — Insert Throughput Ceiling"
inf "Tăng batch: 100 → 500 → 1000 → 5000 → 10000 rows"
echo
printf "  ${BOLD}%-12s %-12s %-12s${NC}\n" "batch" "time(ms)" "rows/s"
printf "  %-12s %-12s %-12s\n" "-----" "--------" "------"

MYSQL_PEAK=0

for N in 100 500 1000 5000 10000; do
  START_T=$(date +%s%3N)
  docker exec market-mysql mysql -umarket_user -pmarket123 market_raw -e "
    INSERT INTO raw_trade (event_id, symbol, price, volume, event_time, created_at)
    WITH RECURSIVE gen(n) AS (
      SELECT 1 UNION ALL SELECT n+1 FROM gen WHERE n < $N
    )
    SELECT
      CONCAT('maxload-', n, '-', UNIX_TIMESTAMP(), '-', RAND()),
      ELT(1 + MOD(n,10), 'VCB','VNM','HPG','FPT','MSN','TCB','BID','CTG','VIC','GAS'),
      80 + MOD(n,20), n * 100,
      DATE_SUB(NOW(), INTERVAL MOD(n,3600) SECOND), NOW()
    FROM gen;
  " 2>/dev/null
  END_T=$(date +%s%3N)
  MS=$(( END_T - START_T ))
  RPS=$(echo "scale=0; $N * 1000 / $MS" | bc 2>/dev/null || echo "?")
  [ "${RPS:-0}" -gt "$MYSQL_PEAK" ] && MYSQL_PEAK=${RPS:-0}
  printf "  %-12s %-12s %-12s\n" "$N rows" "${MS}ms" "${RPS} rows/s"
done

echo
RESULT[mysql_insert]="${MYSQL_PEAK} rows/s"
peak "MySQL insert: ${MYSQL_PEAK} rows/s"

# SELECT concurrent
inf "Concurrent SELECT test (1→5→10→20 parallel queries)..."
echo
printf "  ${BOLD}%-12s %-12s %-12s${NC}\n" "parallel" "time(ms)" "qps"
printf "  %-12s %-12s %-12s\n" "--------" "--------" "---"

MYSQL_SEL_PEAK=0

for P in 1 5 10 20; do
  START_T=$(date +%s%3N)
  for i in $(seq 1 $P); do
    docker exec market-mysql mysql -umarket_user -pmarket123 -s -N market_raw -e "
      SET @i=0; REPEAT
        SELECT COUNT(*) INTO @c FROM raw_trade
        WHERE symbol='VCB' AND event_time > DATE_SUB(NOW(), INTERVAL 1 HOUR);
        SET @i=@i+1;
      UNTIL @i>=20 END REPEAT;
    " > /dev/null 2>&1 &
  done; wait
  END_T=$(date +%s%3N)
  MS=$(( END_T - START_T ))
  TOTAL=$(( P * 20 ))
  QPS=$(echo "scale=0; $TOTAL * 1000 / $MS" | bc 2>/dev/null || echo "?")
  [ "${QPS:-0}" -gt "$MYSQL_SEL_PEAK" ] && MYSQL_SEL_PEAK=${QPS:-0}
  printf "  %-12s %-12s %-12s\n" "${P}x20q" "${MS}ms" "${QPS} qps"
done

RESULT[mysql_select]="${MYSQL_SEL_PEAK} qps"
peak "MySQL select: ${MYSQL_SEL_PEAK} qps"

# ══════════════════════════════════════════════════════════════
# LAYER 4 — ETL WORKER MAX
# Push jobs liên tục, đo throughput và tìm điểm DLQ xuất hiện
# ══════════════════════════════════════════════════════════════
hdr "4. ETL WORKER MAX — Job Throughput Ceiling"
inf "Push jobs liên tục, tăng batch để tìm max và điểm DLQ"
echo
printf "  ${BOLD}%-12s %-12s %-12s %-12s %-10s${NC}\n" \
  "batch" "drain(ms)" "jobs/s" "avg_dur" "dlq"
printf "  %-12s %-12s %-12s %-12s %-10s\n" \
  "-----" "---------" "------" "-------" "---"

ALL_JOBS=$($MYSQL -e \
  "SELECT DISTINCT job_id FROM market_raw.job_execution
   WHERE status='SUCCESS' ORDER BY created_at DESC;" 2>/dev/null)
TOTAL_AVAIL=$(echo "$ALL_JOBS" | grep -c .)
ETL_PEAK=0; ETL_BREAK=0

inf "Available jobs: $TOTAL_AVAIL"
echo

for BATCH in 50 100 200 500 1000; do
  if [ "$BATCH" -gt "$TOTAL_AVAIL" ]; then
    dim "  skip batch=$BATCH (only $TOTAL_AVAIL available)"
    continue
  fi

  echo "$ALL_JOBS" | head -$BATCH | while read JID; do
    [ -z "$JID" ] && continue
    curl -s -X POST "$ETL_URL/jobs/reprocess/$JID" -o /dev/null &
  done; wait

  DRAIN_START=$(date +%s%3N)
  for i in $(seq 1 120); do
    Q=$(q_depth "etl.staging")
    [ "${Q:-1}" -eq 0 ] && break
    sleep 1
  done
  DRAIN_MS=$(( $(date +%s%3N) - DRAIN_START ))
  JPS=$(echo "scale=1; $BATCH * 1000 / $DRAIN_MS" | bc 2>/dev/null || echo "?")
  AVG=$(curl -s "$ETL_URL/jobs/stats" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('avgDurationMs','?'))" 2>/dev/null)
  DLQ=$(q_depth "etl.staging.dlq")

  JPSN=$(echo "$JPS" | cut -d'.' -f1)
  [ "${JPSN:-0}" -gt "$ETL_PEAK" ] && ETL_PEAK=${JPSN:-0}
  [ "${DLQ:-0}" -gt 0 ] && [ "$ETL_BREAK" -eq 0 ] && ETL_BREAK=$BATCH

  STATUS=""
  [ "${DLQ:-0}" -gt 0 ] && STATUS=" ${RED}← DLQ!${NC}"

  printf "  %-12s %-12s %-12s %-12s %-10s" \
    "$BATCH jobs" "${DRAIN_MS}ms" "${JPS}" "${AVG}" "${DLQ}"
  echo -e "${STATUS}"
  sleep 2
done

echo
RESULT[etl]="${ETL_PEAK} jobs/s"
BREAK_AT[etl]="${ETL_BREAK:-"no DLQ"} jobs batch"
peak "ETL: ${ETL_PEAK} jobs/s"
[ "$ETL_BREAK" -gt 0 ] \
  && brk "ETL DLQ tại batch=${ETL_BREAK}" \
  || ok "ETL không có DLQ trong toàn bộ range"

# ══════════════════════════════════════════════════════════════
# LAYER 5 — REPORT SERVICE MAX CONCURRENT
# Tăng đến khi avg > 5000ms hoặc timeout
# ══════════════════════════════════════════════════════════════
hdr "5. REPORT SERVICE MAX — Concurrent Breaking Point"
inf "Tăng c: 1→25→50→100→200→500→1000. Đo đến khi vỡ"
echo
printf "  ${BOLD}%-10s %-12s %-12s %-12s %-12s${NC}\n" \
  "c" "total(ms)" "avg(ms)" "rps" "status"
printf "  %-10s %-12s %-12s %-12s %-12s\n" \
  "---" "---------" "-------" "---" "------"

REPORT_PEAK_RPS=0; REPORT_PEAK_C=0; REPORT_BREAK_C=0

for C in 1 25 50 100 200 500 1000; do
  START_T=$(date +%s%3N)
  for i in $(seq 1 $C); do
    curl -s -o /dev/null \
      "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
      -H "Authorization: Bearer $TOKEN" &
  done; wait
  TOTAL=$(( $(date +%s%3N) - START_T ))
  AVG=$(echo "scale=0; $TOTAL / $C" | bc)
  RPS=$(echo "scale=1; $C * 1000 / $TOTAL" | bc)

  STATUS="${GREEN}OK${NC}"; STOP=0
  if (( AVG > 5000 )); then
    STATUS="${RED}BROKEN${NC}"; STOP=1
    [ "$REPORT_BREAK_C" -eq 0 ] && REPORT_BREAK_C=$C
  elif (( AVG > 2000 )); then
    STATUS="${YELLOW}DEGRADED${NC}"
    [ "$REPORT_BREAK_C" -eq 0 ] && REPORT_BREAK_C=$C
  fi

  RPS_N=$(echo "$RPS" | cut -d'.' -f1)
  [ "${RPS_N:-0}" -gt "$REPORT_PEAK_RPS" ] && {
    REPORT_PEAK_RPS=${RPS_N:-0}
    REPORT_PEAK_C=$C
  }

  printf "  %-10s %-12s %-12s %-12s " "c=$C" "${TOTAL}ms" "${AVG}ms" "${RPS}"
  echo -e "${STATUS}"
  [ "$STOP" -eq 1 ] && break
  sleep 1
done

echo
RESULT[report]="${REPORT_PEAK_RPS} rps @ c=${REPORT_PEAK_C}"
BREAK_AT[report]="c=${REPORT_BREAK_C:-">1000"}"
peak "Report: ${REPORT_PEAK_RPS} rps @ c=${REPORT_PEAK_C}"
brk "Report: c=${REPORT_BREAK_C:-">1000"}"

# ══════════════════════════════════════════════════════════════
# LAYER 6 — REDIS MAX HIT RATE UNDER LOAD
# Tăng concurrent đến khi Redis bị bottleneck
# ══════════════════════════════════════════════════════════════
hdr "6. REDIS MAX — Cache Throughput Under Load"
inf "Tăng concurrent cache requests: 10→50→100→200→500"

$REDIS CONFIG RESETSTAT > /dev/null 2>&1

# Warm
SYMBOLS=$($MYSQL -e "SELECT DISTINCT symbol FROM market_dw.fact_market_1m;" 2>/dev/null)
for SYM in $SYMBOLS; do
  curl -s -o /dev/null "$REPORT_URL/api/stocks?symbol=$SYM&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN"
done
inf "Cache warmed"
echo
printf "  ${BOLD}%-10s %-12s %-12s %-12s${NC}\n" \
  "c" "hit(ms)" "avg/req" "rps"
printf "  %-10s %-12s %-12s %-12s\n" \
  "---" "-------" "-------" "---"

REDIS_PEAK=0

for C in 10 50 100 200 500; do
  START_T=$(date +%s%3N)
  for i in $(seq 1 $C); do
    curl -s -o /dev/null \
      "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
      -H "Authorization: Bearer $TOKEN" &
  done; wait
  MS=$(( $(date +%s%3N) - START_T ))
  AVG=$(echo "scale=0; $MS/$C" | bc)
  RPS=$(echo "scale=1; $C*1000/$MS" | bc)
  RPS_N=$(echo "$RPS" | cut -d'.' -f1)
  [ "${RPS_N:-0}" -gt "$REDIS_PEAK" ] && REDIS_PEAK=${RPS_N:-0}
  printf "  %-10s %-12s %-12s %-12s\n" "c=$C" "${MS}ms" "${AVG}ms" "${RPS}"
done

HITS=$($REDIS INFO stats 2>/dev/null | grep "^keyspace_hits:" | cut -d: -f2 | tr -d '\r')
MISSES=$($REDIS INFO stats 2>/dev/null | grep "^keyspace_misses:" | cut -d: -f2 | tr -d '\r')
TOTAL_OPS=$(( ${HITS:-0} + ${MISSES:-0} ))
[ "$TOTAL_OPS" -gt 0 ] && \
  HIT_RATE=$(echo "scale=1; ${HITS:-0} * 100 / $TOTAL_OPS" | bc)

echo
inf "Hit rate: ${HIT_RATE:-?}% (hits=${HITS} misses=${MISSES})"
RESULT[redis]="${REDIS_PEAK} rps, hit_rate=${HIT_RATE:-?}%"
peak "Redis: ${REDIS_PEAK} rps @ hit_rate ${HIT_RATE:-?}%"

# ══════════════════════════════════════════════════════════════
# LAYER 7 — END-TO-END MAX SUSTAINED LOAD
# Chạy generator max speed 120s liên tục, đo toàn pipeline
# ══════════════════════════════════════════════════════════════
hdr "7. END-TO-END MAX — 120s Full Pipeline Stress"
inf "Generator @ 10ms (100 events/s) x 120s — đo toàn bộ pipeline"

RAW_T0=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_T0=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)

curl -s -X POST "$GENERATOR_URL/generator/speed?ms=10" > /dev/null
curl -s -X POST "$GENERATOR_URL/generator/start" > /dev/null
sleep 3  # ổn định

RAW_T0=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_T0=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)
inf "Baseline: raw=${RAW_T0} fact=${FACT_T0}"

printf "  ${BOLD}%-8s %-12s %-12s %-12s %-10s %-10s${NC}\n" \
  "t(s)" "raw" "fact" "lag" "rabbit" "cpu_con%"
printf "  %-8s %-12s %-12s %-12s %-10s %-10s\n" \
  "---" "---" "----" "---" "------" "--------"

MAX_LAG=0; MIN_FACT_RATE=999; MAX_RAW_RATE=0
PREV_RAW=$RAW_T0; PREV_FACT=$FACT_T0

for T in 15 30 45 60 75 90 105 120; do
  sleep 15
  RAW_N=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
  FACT_N=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)
  LAG=$(kafka_lag)
  RQ=$(q_depth "etl.staging")
  CPU=$(docker stats --no-stream \
    --format "{{.CPUPerc}}" market-raw-consumer 2>/dev/null | tr -d '%')

  RAW_RATE=$(echo "scale=0; ($RAW_N - $PREV_RAW) / 15" | bc 2>/dev/null || echo 0)
  FACT_RATE=$(echo "scale=1; ($FACT_N - $PREV_FACT) / 15" | bc 2>/dev/null || echo 0)

  [ "${LAG:-0}" -gt "$MAX_LAG" ] && MAX_LAG=${LAG:-0}
  [ "${RAW_RATE:-0}" -gt "$MAX_RAW_RATE" ] && MAX_RAW_RATE=${RAW_RATE:-0}

  printf "  %-8s %-12s %-12s %-12s %-10s %-10s\n" \
    "t=${T}s" "${RAW_N}" "${FACT_N}" "${LAG:-0}" "${RQ:-0}" "${CPU:-?}%"

  PREV_RAW=$RAW_N; PREV_FACT=$FACT_N
done

curl -s -X POST "$GENERATOR_URL/generator/speed?ms=500" > /dev/null

RAW_T1=$($MYSQL -e "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_T1=$($MYSQL -e "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)
FINAL_LAG=$(kafka_lag)
FINAL_DLQ=$(q_depth "etl.staging.dlq")

RAW_DIFF=$(( RAW_T1 - RAW_T0 ))
FACT_DIFF=$(( FACT_T1 - FACT_T0 ))
RAW_RPS=$(echo "scale=1; $RAW_DIFF / 120" | bc 2>/dev/null || echo "?")
FACT_RPS=$(echo "scale=1; $FACT_DIFF / 120" | bc 2>/dev/null || echo "?")

echo
inf "Total ingested : ${RAW_DIFF} events (~${RAW_RPS}/s)"
inf "Total facts    : ${FACT_DIFF} (~${FACT_RPS}/s)"
inf "Max Kafka lag  : ${MAX_LAG}"
inf "Final lag      : ${FINAL_LAG:-0}"
inf "DLQ final      : ${FINAL_DLQ:-0}"

[ "${FINAL_DLQ:-0}" -eq 0 ] \
  && ok "No data loss (DLQ=0)" \
  || err "DLQ=${FINAL_DLQ} — có data loss"
[ "${FINAL_LAG:-0}" -lt 1000 ] \
  && ok "Pipeline drains trong 120s" \
  || warn "Lag còn ${FINAL_LAG} — pipeline chưa drain hết"

RESULT[e2e]="${RAW_RPS} events/s | ${FACT_RPS} facts/s | max_lag=${MAX_LAG}"

# ══════════════════════════════════════════════════════════════
# LAYER 8 — RESOURCE USAGE AT MAX LOAD
# ══════════════════════════════════════════════════════════════
hdr "8. RESOURCE USAGE — After Max Load"
echo
printf "  ${BOLD}%-25s %-12s %-20s %-15s${NC}\n" \
  "Container" "CPU%" "Memory" "Status"
printf "  %-25s %-12s %-20s %-15s\n" \
  "---------" "----" "------" "------"

for CTR in market-ingest market-raw-consumer market-etl market-report \
           market-generator market-kafka market-mysql market-redis market-rabbitmq; do
  STATS=$(docker stats --no-stream \
    --format "{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" "$CTR" 2>/dev/null)
  CPU=$(echo "$STATS" | cut -f1)
  MEM=$(echo "$STATS" | cut -f2)
  MEM_PCT=$(echo "$STATS" | cut -f3)

  # Flag high CPU
  CPU_NUM=$(echo "${CPU:-0}" | tr -d '%')
  NOTE=""
  (( $(echo "$CPU_NUM > 150" | bc -l 2>/dev/null || echo 0) )) && NOTE="${RED}HIGH CPU${NC}"
  (( $(echo "$CPU_NUM > 80" | bc -l 2>/dev/null || echo 0) )) && \
    (( $(echo "$CPU_NUM <= 150" | bc -l 2>/dev/null || echo 0) )) && NOTE="${YELLOW}BUSY${NC}"
  [ -z "$NOTE" ] && NOTE="${GREEN}OK${NC}"

  [ -n "$CPU" ] && {
    printf "  %-25s %-12s %-20s " "$CTR" "${CPU}" "${MEM}"
    echo -e "${NOTE}"
  }
done

# ══════════════════════════════════════════════════════════════
# FINAL BREAKING POINT SUMMARY
# ══════════════════════════════════════════════════════════════
hdr "MAX LOAD SUMMARY — Breaking Points"
echo
printf "  ${BOLD}%-22s %-30s %-25s %-20s${NC}\n" \
  "Layer" "Peak Throughput" "Breaking Point" "Bottleneck"
sep
printf "  %-22s %-30s %-25s %-20s\n" \
  "Ingest HTTP" \
  "${RESULT[ingest]:-?}" \
  "${BREAK_AT[ingest]:-?}" \
  "Tomcat threads"

printf "  %-22s %-30s %-25s %-20s\n" \
  "Kafka consumer" \
  "${RESULT[consumer]:-?}" \
  "${BREAK_AT[consumer]:-?}" \
  "Single consumer thread"

printf "  %-22s %-30s %-25s %-20s\n" \
  "MySQL insert" \
  "${RESULT[mysql_insert]:-?}" \
  "N/A" \
  "InnoDB redo log"

printf "  %-22s %-30s %-25s %-20s\n" \
  "MySQL select" \
  "${RESULT[mysql_select]:-?}" \
  "N/A" \
  "Connection pool"

printf "  %-22s %-30s %-25s %-20s\n" \
  "ETL Worker" \
  "${RESULT[etl]:-?}" \
  "${BREAK_AT[etl]:-?}" \
  "RabbitMQ consumers"

printf "  %-22s %-30s %-25s %-20s\n" \
  "Report Service" \
  "${RESULT[report]:-?}" \
  "${BREAK_AT[report]:-?}" \
  "HikariCP pool=10"

printf "  %-22s %-30s %-25s %-20s\n" \
  "Redis Cache" \
  "${RESULT[redis]:-?}" \
  "N/A" \
  "Dataset size"

printf "  %-22s %-30s %-25s %-20s\n" \
  "E2E Pipeline" \
  "${RESULT[e2e]:-?}" \
  "Consumer drain" \
  "Raw consumer"
sep
echo
echo -e "${BOLD}Weakest link:${NC} Kafka consumer (${RESULT[consumer]:-?}) — single thread, no ErrorHandlingDeserializer"
echo -e "${BOLD}Strongest:${NC}    Kafka producer (~50-67k msg/s) và ETL Worker (${RESULT[etl]:-?})"
echo

rm -f "$PAYLOAD"
echo -e "${BOLD}Done. Runtime: ~20 phút${NC}"