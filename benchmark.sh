#!/bin/bash
# ═══════════════════════════════════════════════════════
#  market-pipeline — BENCHMARK SCRIPT
#  Chạy: chmod +x benchmark.sh && ./benchmark.sh
# ═══════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INGEST_URL="http://localhost:8080"
GENERATOR_URL="http://localhost:8081"
REPORT_URL="http://localhost:8085"
ETL_URL="http://localhost:8084"

sep() { echo -e "${CYAN}──────────────────────────────────────────────${NC}"; }
hdr() { echo -e "\n${BOLD}${YELLOW}▶ $1${NC}"; sep; }
ok()  { echo -e "  ${GREEN}✔${NC} $1"; }
err() { echo -e "  ${RED}✘${NC} $1"; }
inf() { echo -e "  ${CYAN}→${NC} $1"; }

# ── 0. Pre-flight ────────────────────────────────────────
hdr "0. Pre-flight check"
TOKEN=$(curl -s -X POST "$REPORT_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  err "Không lấy được JWT token — report-service chưa chạy?"
  exit 1
fi
ok "JWT token OK"

DB_COUNTS=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_raw.raw_trade;
   SELECT COUNT(*) FROM market_staging.stg_trade_1m;
   SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)
read RAW STG FACT <<< $DB_COUNTS
inf "Baseline — raw:$RAW  stg:$STG  fact:$FACT"

# ── 1. INGEST THROUGHPUT ────────────────────────────────
hdr "1. Ingest Service — throughput (100 requests)"

send_trade() {
  curl -s -o /dev/null -w "%{http_code} %{time_total}" \
    -X POST "$INGEST_URL/api/trades" \
    -H "Content-Type: application/json" \
    -d "{\"eventId\":\"bm-$RANDOM-$1\",\"symbol\":\"VCB\",\"price\":85.5,\"volume\":1000,\"eventTime\":\"2026-04-01T10:00:00\"}"
}

START=$(date +%s%3N)
SUCCESS=0; FAIL=0
for i in $(seq 1 100); do
  RESP=$(send_trade $i)
  CODE=$(echo $RESP | cut -d' ' -f1)
  [ "$CODE" = "200" ] || [ "$CODE" = "202" ] && ((SUCCESS++)) || ((FAIL++))
done
END=$(date +%s%3N)
ELAPSED=$(( END - START ))
RPS=$(echo "scale=1; 100 * 1000 / $ELAPSED" | bc)

ok "100 requests done in ${ELAPSED}ms"
inf "Success: $SUCCESS | Failed: $FAIL"
inf "Throughput: ~${RPS} req/s"
[ "$FAIL" -eq 0 ] && ok "Error rate: 0%" || err "Error rate: ${FAIL}%"

# ── 2. INGEST LATENCY p50/p95/p99 ───────────────────────
hdr "2. Ingest Service — latency (50 samples)"

LATENCIES=()
for i in $(seq 1 50); do
  T=$(curl -s -o /dev/null -w "%{time_total}" \
    -X POST "$INGEST_URL/api/trades" \
    -H "Content-Type: application/json" \
    -d "{\"eventId\":\"lat-$i\",\"symbol\":\"VNM\",\"price\":68.2,\"volume\":500,\"eventTime\":\"2026-04-01T10:00:00\"}")
  MS=$(echo "$T * 1000" | bc | cut -d'.' -f1)
  LATENCIES+=($MS)
done

SORTED=($(printf '%s\n' "${LATENCIES[@]}" | sort -n))
P50=${SORTED[24]}
P95=${SORTED[47]}
P99=${SORTED[49]}
AVG=$(echo "${LATENCIES[@]}" | tr ' ' '\n' | awk '{s+=$1}END{printf "%.0f", s/NR}')

inf "p50: ${P50}ms | p95: ${P95}ms | p99: ${P99}ms | avg: ${AVG}ms"
[ "$P99" -lt 200 ] && ok "p99 < 200ms ✔" || err "p99 ${P99}ms — quá chậm"

# ── 3. KAFKA LAG ─────────────────────────────────────────
hdr "3. Kafka — consumer lag"

LAG=$(docker exec market-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group raw-consumer-group \
  --describe 2>/dev/null | grep market.trades | awk '{sum+=$6} END{print sum+0}')

inf "raw-consumer-group lag: ${LAG} messages"
[ "$LAG" -lt 100 ] && ok "Lag OK (< 100)" || err "Lag cao: $LAG — consumer bị chậm?"

# ── 4. GENERATOR SPEED TEST ──────────────────────────────
hdr "4. Fake Generator — stress test (10s @ 100ms interval)"

BEFORE=$(curl -s "$GENERATOR_URL/generator/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sentCount',0))" 2>/dev/null)

# Tăng tốc → chạy 10s → đo → giảm lại
curl -s -X POST "$GENERATOR_URL/generator/speed?ms=100" > /dev/null
sleep 10
AFTER=$(curl -s "$GENERATOR_URL/generator/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sentCount',0))" 2>/dev/null)
curl -s -X POST "$GENERATOR_URL/generator/speed?ms=500" > /dev/null

DIFF=$(( AFTER - BEFORE ))
inf "Events generated in 10s: $DIFF (target ~100)"
[ "$DIFF" -ge 80 ] && ok "Generator throughput OK" || err "Generator chậm hơn expected"

# ── 5. RAW CONSUMER BATCH THROUGHPUT ────────────────────
hdr "5. Raw Consumer — DB insert speed"

sleep 5  # chờ consumer flush

RAW_AFTER=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
INSERTED=$(( RAW_AFTER - RAW ))
inf "New rows inserted vào raw_trade: $INSERTED"
[ "$INSERTED" -gt 0 ] && ok "Consumer đang hoạt động" || err "Không có row mới — consumer bị stuck?"

# ── 6. ETL WORKER PERFORMANCE ────────────────────────────
hdr "6. ETL Worker — job stats"

STATS=$(curl -s "$ETL_URL/jobs/stats")
TOTAL=$(echo $STATS | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null)
SUCCESS_JOBS=$(echo $STATS | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',0))" 2>/dev/null)
FAILED_JOBS=$(echo $STATS | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failed',0))" 2>/dev/null)
RATE=$(echo $STATS | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('successRate','0%'))" 2>/dev/null)
AVG_MS=$(echo $STATS | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('avgDurationMs','0ms'))" 2>/dev/null)
DLQ=$(echo $STATS | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dlqMessages',0))" 2>/dev/null)

inf "Total jobs: $TOTAL | Success: $SUCCESS_JOBS | Failed: $FAILED_JOBS"
inf "Success rate: $RATE | Avg duration: $AVG_MS"
inf "DLQ messages: $DLQ"

[ "$FAILED_JOBS" -eq 0 ] && ok "No failed jobs" || err "$FAILED_JOBS jobs failed"
[ "$DLQ" -eq 0 ] && ok "DLQ empty" || err "DLQ has $DLQ messages — cần reprocess"

AVG_NUM=$(echo $AVG_MS | tr -d 'ms' | cut -d'.' -f1)
[ "${AVG_NUM:-999}" -lt 50 ] && ok "ETL avg < 50ms" || inf "ETL avg: $AVG_MS"

# ── 7. REPORT API — CACHE HIT/MISS ──────────────────────
hdr "7. Report Service — Redis cache benchmark (10 requests)"

TIMES=()
for i in $(seq 1 10); do
  T=$(curl -s -o /dev/null -w "%{time_total}" \
    "http://localhost:8085/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN")
  MS=$(echo "$T * 1000" | bc | cut -d'.' -f1)
  TIMES+=($MS)
done

FIRST=${TIMES[0]}
REST_AVG=$(echo "${TIMES[@]:1}" | tr ' ' '\n' | awk '{s+=$1}END{printf "%.0f", s/NR}')

inf "Request 1 (DB query): ${FIRST}ms"
inf "Request 2-10 avg (cache hit): ${REST_AVG}ms"

SPEEDUP=$(echo "scale=1; $FIRST / $REST_AVG" | bc 2>/dev/null || echo "N/A")
inf "Cache speedup: ~${SPEEDUP}x"
[ "$REST_AVG" -lt "$FIRST" ] && ok "Cache hit nhanh hơn DB" || err "Cache không có hiệu quả?"

# ── 8. REPORT API — FILTER BENCHMARK ────────────────────
hdr "8. Report Service — filter queries"

run_query() {
  local label=$1; local url=$2
  local T=$(curl -s -o /dev/null -w "%{time_total}" "$url" \
    -H "Authorization: Bearer $TOKEN")
  local MS=$(echo "$T * 1000" | bc | cut -d'.' -f1)
  inf "$label: ${MS}ms"
}

# Force cache miss bằng cách query với filter
run_query "No filter (all)"         "$REPORT_URL/api/stocks?page=0&size=20"
run_query "Filter symbol=VCB"       "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20"
run_query "Filter symbol=HPG"       "$REPORT_URL/api/stocks?symbol=HPG&page=0&size=20"
run_query "Filter minPrice=80"      "$REPORT_URL/api/stocks?minPrice=80&page=0&size=20"
run_query "Filter date range"       "$REPORT_URL/api/stocks?from=2026-03-31T18:00:00&to=2026-03-31T19:00:00&page=0&size=20"
run_query "Pagination page=1"       "$REPORT_URL/api/stocks?page=1&size=10"

# ── 9. RABBITMQ QUEUE DEPTH ─────────────────────────────
hdr "9. RabbitMQ — queue health"

check_queue() {
  local q=$1
  local DATA=$(curl -s -u rabbit_user:rabbit123 \
    "http://localhost:15672/api/queues/%2F/$q" 2>/dev/null)
  local MSGS=$(echo $DATA | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null)
  local RATE=$(echo $DATA | python3 -c "import sys,json; d=json.load(sys.stdin); print(round(d.get('message_stats',{}).get('deliver_get_details',{}).get('rate',0),1))" 2>/dev/null)
  echo -e "  ${CYAN}→${NC} $q: ${MSGS} msgs | consume rate: ${RATE:-0}/s"
}

check_queue "etl.staging"
check_queue "etl.staging.retry"
check_queue "etl.staging.dlq"
check_queue "cache.invalidate"

# ── 10. DATABASE ROW COUNTS ─────────────────────────────
hdr "10. Database — data pipeline integrity"

docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
"SELECT 'raw_trade      ' as layer, COUNT(*) as rows, '-' as note FROM market_raw.raw_trade
 UNION ALL
 SELECT 'stg_trade_1m   ', COUNT(*), CONCAT(COUNT(DISTINCT symbol), ' symbols') FROM market_staging.stg_trade_1m
 UNION ALL
 SELECT 'fact_market_1m ', COUNT(*), CONCAT(COUNT(DISTINCT symbol), ' symbols') FROM market_dw.fact_market_1m
 UNION ALL
 SELECT 'job_execution  ', COUNT(*), CONCAT(SUM(status='SUCCESS'),'/',COUNT(*),' success') FROM market_raw.job_execution;" \
2>/dev/null | while IFS=$'\t' read layer rows note; do
  inf "$layer  rows=$rows  ($note)"
done

STG_NOW=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_staging.stg_trade_1m;" 2>/dev/null)
FACT_NOW=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)

[ "$STG_NOW" -eq "$FACT_NOW" ] && ok "stg == fact (ETL sync hoàn chỉnh)" \
  || inf "stg=$STG_NOW fact=$FACT_NOW (có thể đang ETL)"

# ── 11. CONCURRENT LOAD TEST ────────────────────────────
hdr "11. Concurrent load — 20 parallel requests"

START=$(date +%s%3N)
for i in $(seq 1 20); do
  curl -s -o /dev/null \
    "http://localhost:8085/api/stocks?symbol=VCB&page=0&size=10" \
    -H "Authorization: Bearer $TOKEN" &
done
wait
END=$(date +%s%3N)
ELAPSED=$(( END - START ))

inf "20 concurrent requests completed in ${ELAPSED}ms"
[ "$ELAPSED" -lt 2000 ] && ok "Concurrent OK (< 2s)" || err "Slow: ${ELAPSED}ms"

# ── SUMMARY ─────────────────────────────────────────────
hdr "SUMMARY"
echo -e "  Ingest throughput : ~${RPS} req/s"
echo -e "  Ingest p99 latency: ${P99}ms"
echo -e "  Kafka lag         : ${LAG} msgs"
echo -e "  ETL success rate  : ${RATE}"
echo -e "  ETL avg duration  : ${AVG_MS}"
echo -e "  Cache speedup     : ~${SPEEDUP}x"
echo -e "  DLQ messages      : ${DLQ}"
sep
echo -e "${BOLD}Done.${NC}"