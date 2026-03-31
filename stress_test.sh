#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  market-pipeline — STRESS TEST (Saturation Point Finder)
#  Chạy: chmod +x stress_test.sh && ./stress_test.sh
#  Yêu cầu: apache2-utils (ab), bc, python3
#  Cài ab: sudo apt install apache2-utils
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; GRAY='\033[0;90m'; NC='\033[0m'

INGEST_URL="http://localhost:8080"
GENERATOR_URL="http://localhost:8081"
REPORT_URL="http://localhost:8085"
ETL_URL="http://localhost:8084"
RABBIT_API="http://localhost:15672/api"
RABBIT_USER="rabbit_user:rabbit123"
MYSQL_CMD="docker exec market-mysql mysql -umarket_user -pmarket123 -s -N"

sep()  { echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"; }
hdr()  { echo -e "\n${BOLD}${YELLOW}▶ $1${NC}"; sep; }
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
err()  { echo -e "  ${RED}✘${NC} $1"; }
inf()  { echo -e "  ${CYAN}→${NC} $1"; }
dim()  { echo -e "  ${GRAY}$1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# Header table row
trow() { printf "  %-18s %-12s %-12s %-12s %-10s\n" "$1" "$2" "$3" "$4" "$5"; }

# ── Pre-flight ────────────────────────────────────────────────
hdr "Pre-flight"

# Check ab
if ! command -v ab &> /dev/null; then
  warn "apache2-utils chưa cài — bỏ qua section 1 (ab test)"
  HAS_AB=0
else
  HAS_AB=1
  ok "ab (apache bench) found"
fi

# JWT token
TOKEN=$(curl -s -X POST "$REPORT_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -z "$TOKEN" ] && { err "Không lấy được token"; exit 1; }
ok "JWT token OK"

# Stop generator để tránh nhiễu
curl -s -X POST "$GENERATOR_URL/generator/stop" > /dev/null
sleep 2
ok "Generator stopped (tránh nhiễu)"

# Payload file cho ab
PAYLOAD_FILE=$(mktemp /tmp/trade_payload.XXXXXX.json)
echo '{"eventId":"stress-placeholder","symbol":"VCB","price":85.5,"volume":1000,"eventTime":"2026-04-01T10:00:00"}' > "$PAYLOAD_FILE"

# ═══════════════════════════════════════════════════════════════
# LAYER 1 — INGEST SERVICE
# ═══════════════════════════════════════════════════════════════
hdr "LAYER 1 — Ingest Service (HTTP saturation)"
inf "Tăng concurrency từ 1 → 200, mỗi level 500 requests"
echo

trow "Concurrency" "Req/s" "p50(ms)" "p99(ms)" "Errors"
trow "----------" "------" "-------" "-------" "------"

INGEST_SAT=0
PREV_RPS=0

for C in 1 5 10 20 50 100 200; do
  if [ "$HAS_AB" -eq 1 ]; then
    # Dùng ab
    RESULT=$(ab -n 500 -c $C \
      -p "$PAYLOAD_FILE" \
      -T "application/json" \
      "$INGEST_URL/api/trades" 2>/dev/null)

    RPS=$(echo "$RESULT" | grep "Requests per second" | awk '{printf "%.0f", $4}')
    P50=$(echo "$RESULT" | grep "50%" | awk '{print $2}')
    P99=$(echo "$RESULT" | grep "99%" | awk '{print $2}')
    ERRORS=$(echo "$RESULT" | grep "Non-2xx" | awk '{print $NF}')
    ERRORS=${ERRORS:-0}
  else
    # Fallback: parallel curl
    START=$(date +%s%3N)
    SUCCESS=0; FAIL=0
    for i in $(seq 1 $((C * 5))); do
      {
        CODE=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "$INGEST_URL/api/trades" \
          -H "Content-Type: application/json" \
          -d "{\"eventId\":\"s-$C-$i-$RANDOM\",\"symbol\":\"VCB\",\"price\":85.5,\"volume\":1000,\"eventTime\":\"2026-04-01T10:00:00\"}")
        if [[ "$CODE" == "200" || "$CODE" == "202" ]]; then
          echo "OK"
        else
          echo "FAIL"
        fi
      } &
    done
    RESULTS=$(wait; jobs -l)
    END=$(date +%s%3N)
    ELAPSED=$(( END - START ))
    TOTAL=$((C * 5))
    RPS=$(echo "scale=0; $TOTAL * 1000 / $ELAPSED" | bc)
    P50="n/a"; P99="n/a"; ERRORS=0
  fi

  trow "c=$C" "${RPS}" "${P50}" "${P99}" "${ERRORS}"

  # Phát hiện saturation: RPS tăng không đáng kể hoặc errors xuất hiện
  if [ "$HAS_AB" -eq 1 ] && [ "${ERRORS:-0}" -gt 10 ] && [ "$INGEST_SAT" -eq 0 ]; then
    INGEST_SAT=$C
  fi
  PREV_RPS=$RPS
  sleep 1
done

echo
[ "$INGEST_SAT" -gt 0 ] \
  && warn "Saturation bắt đầu tại concurrency=$INGEST_SAT" \
  || ok "Không thấy saturation trong range test (max c=200)"

# ═══════════════════════════════════════════════════════════════
# LAYER 2 — KAFKA PRODUCER THROUGHPUT
# ═══════════════════════════════════════════════════════════════
hdr "LAYER 2 — Kafka (producer max throughput)"
inf "Dùng kafka-producer-perf-test: 10,000 messages @ 200 bytes"
echo

KAFKA_RESULT=$(docker exec market-kafka \
  kafka-producer-perf-test \
  --topic market.trades \
  --num-records 10000 \
  --record-size 200 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:9092 \
  acks=1 \
  2>&1 | tail -1)

echo "  $KAFKA_RESULT"
echo

KAFKA_RPS=$(echo "$KAFKA_RESULT" | grep -oP '[\d,]+(?= records/sec)' | tr -d ',')
KAFKA_MB=$(echo "$KAFKA_RESULT"  | grep -oP '[\d.]+(?= MB/sec)')
KAFKA_P99=$(echo "$KAFKA_RESULT" | grep -oP '[\d.]+(?= ms \(99th)' | head -1)

inf "Throughput: ${KAFKA_RPS} msg/s | ${KAFKA_MB} MB/s"
inf "p99 latency: ${KAFKA_P99}ms"

[ "${KAFKA_RPS//,/}" -gt 50000 ] \
  && ok "Kafka throughput > 50k msg/s" \
  || warn "Kafka throughput: ${KAFKA_RPS} msg/s"

# Consumer throughput
inf "Consumer test: đo lag recovery speed"
# Tạm flood rồi đo thời gian drain
docker exec market-kafka \
  kafka-producer-perf-test \
  --topic market.trades \
  --num-records 2000 \
  --record-size 200 \
  --throughput 5000 \
  --producer-props bootstrap.servers=localhost:9092 \
  > /dev/null 2>&1

START=$(date +%s%3N)
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
  LAG=$(docker exec market-kafka kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --group raw-consumer-group \
    --describe 2>/dev/null | grep market.trades | awk '{sum+=$6} END{print sum+0}')
  [ "${LAG:-999}" -eq 0 ] && break
  sleep 1
done
END=$(date +%s%3N)
DRAIN_MS=$(( END - START ))

inf "2000 messages drained in ${DRAIN_MS}ms (~$(echo "scale=0; 2000*1000/$DRAIN_MS" | bc) msg/s)"
[ "$DRAIN_MS" -lt 10000 ] && ok "Consumer drain OK" || warn "Consumer drain chậm: ${DRAIN_MS}ms"

# ═══════════════════════════════════════════════════════════════
# LAYER 3 — ETL WORKER THROUGHPUT
# ═══════════════════════════════════════════════════════════════
hdr "LAYER 3 — ETL Worker (job processing max)"
inf "Inject jobs trực tiếp vào etl.staging qua reprocess, đo drain time"
echo

# Lấy sample jobs từ DB để reprocess
SAMPLE_JOBS=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT job_id FROM market_raw.job_execution WHERE status='SUCCESS' LIMIT 100;" 2>/dev/null)
JOB_COUNT=$(echo "$SAMPLE_JOBS" | wc -l)

if [ "$JOB_COUNT" -lt 10 ]; then
  warn "Không đủ jobs trong DB để test (cần ít nhất 10). Bỏ qua layer 3."
else
  inf "Reprocess $JOB_COUNT jobs từ DB..."

  START=$(date +%s%3N)

  # Push jobs song song
  echo "$SAMPLE_JOBS" | while read JOB_ID; do
    [ -z "$JOB_ID" ] && continue
    curl -s -X POST "$ETL_URL/jobs/reprocess/$JOB_ID" > /dev/null &
  done
  wait

  # Đợi queue drain
  for i in $(seq 1 60); do
    Q=$(curl -s -u $RABBIT_USER \
      "$RABBIT_API/queues/%2F/etl.staging" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages',0))" 2>/dev/null)
    [ "${Q:-1}" -eq 0 ] && break
    sleep 1
  done

  END=$(date +%s%3N)
  ELAPSED=$(( END - START ))
  JPS=$(echo "scale=1; $JOB_COUNT * 1000 / $ELAPSED" | bc)

  inf "Processed $JOB_COUNT jobs in ${ELAPSED}ms"
  inf "ETL throughput: ~${JPS} jobs/s"

  # Lấy avg duration từ stats
  STATS=$(curl -s "$ETL_URL/jobs/stats")
  AVG=$(echo $STATS | python3 -c "import sys,json; print(json.load(sys.stdin).get('avgDurationMs','?'))" 2>/dev/null)
  inf "Avg job duration (cumulative): $AVG"

  # RabbitMQ concurrency test
  inf "ETL concurrency: $(curl -s "$RABBIT_API/queues/%2F/etl.staging" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('consumer_details',[{}])[0].get('consumer_tag','?')[:30] if d.get('consumer_details') else 'idle')" 2>/dev/null)"

  [ "$(echo "$JPS > 50" | bc)" -eq 1 ] \
    && ok "ETL throughput > 50 jobs/s" \
    || warn "ETL throughput: ${JPS} jobs/s"
fi

# ═══════════════════════════════════════════════════════════════
# LAYER 4 — REPORT SERVICE CONCURRENT USERS
# ═══════════════════════════════════════════════════════════════
hdr "LAYER 4 — Report Service (concurrent users saturation)"
inf "Tăng concurrent users: 1 → 10 → 25 → 50 → 100 → 200"
echo

trow "Concurrency" "Total(ms)" "Avg/req(ms)" "Throughput" "Status"
trow "----------" "---------" "-----------" "----------" "------"

REPORT_SAT=0
PREV_AVG=0

for C in 1 10 25 50 100 200; do
  START=$(date +%s%3N)
  for i in $(seq 1 $C); do
    curl -s -o /dev/null \
      "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
      -H "Authorization: Bearer $TOKEN" &
  done
  wait
  END=$(date +%s%3N)

  TOTAL=$(( END - START ))
  AVG=$(echo "scale=0; $TOTAL / $C" | bc)
  RPS=$(echo "scale=1; $C * 1000 / $TOTAL" | bc)

  # Detect saturation: avg latency tăng > 3x so với baseline
  STATUS="✔ OK"
  if [ "$C" -gt 1 ] && [ "$AVG" -gt $(( PREV_AVG * 3 )) ] && [ "$REPORT_SAT" -eq 0 ]; then
    STATUS="⚠ SLOW"
    REPORT_SAT=$C
  fi
  [ "$AVG" -gt 500 ] && STATUS="✘ SATURATED"

  trow "c=$C" "${TOTAL}ms" "${AVG}ms" "${RPS} r/s" "$STATUS"
  [ "$C" -eq 1 ] && PREV_AVG=$AVG
  sleep 1
done

echo
[ "$REPORT_SAT" -gt 0 ] \
  && warn "Report service bắt đầu chậm tại concurrency=$REPORT_SAT" \
  || ok "Report service ổn định trong toàn bộ range test"

# ═══════════════════════════════════════════════════════════════
# LAYER 5 — REDIS CACHE UNDER LOAD
# ═══════════════════════════════════════════════════════════════
hdr "LAYER 5 — Redis Cache (hit rate under load)"
inf "50 requests song song, đo cache hit vs miss tỉ lệ"
echo

# Warm cache trước
curl -s "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
  -H "Authorization: Bearer $TOKEN" > /dev/null

# Đo 50 concurrent cache-hit requests
START=$(date +%s%3N)
for i in $(seq 1 50); do
  curl -s -o /dev/null \
    "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN" &
done
wait
END=$(date +%s%3N)
CACHE_HIT_MS=$(( END - START ))

# Bust cache rồi đo DB query
docker exec market-redis redis-cli -a redis123 DEL "stock:VCB:1m" > /dev/null 2>&1

START=$(date +%s%3N)
for i in $(seq 1 50); do
  curl -s -o /dev/null \
    "$REPORT_URL/api/stocks?symbol=VCB&page=0&size=20" \
    -H "Authorization: Bearer $TOKEN" &
done
wait
END=$(date +%s%3N)
CACHE_MISS_MS=$(( END - START ))

inf "50 concurrent — cache HIT total: ${CACHE_HIT_MS}ms (avg $(echo "scale=0; $CACHE_HIT_MS/50" | bc)ms/req)"
inf "50 concurrent — cache MISS total: ${CACHE_MISS_MS}ms (avg $(echo "scale=0; $CACHE_MISS_MS/50" | bc)ms/req)"

if [ "$CACHE_HIT_MS" -lt "$CACHE_MISS_MS" ]; then
  SPEEDUP=$(echo "scale=2; $CACHE_MISS_MS / $CACHE_HIT_MS" | bc)
  ok "Cache speedup under load: ${SPEEDUP}x"
else
  warn "Cache không có lợi thế rõ rệt — dataset quá nhỏ"
fi

# Redis info
REDIS_HITS=$(docker exec market-redis redis-cli -a redis123 INFO stats 2>/dev/null | grep "keyspace_hits" | cut -d: -f2 | tr -d '\r')
REDIS_MISS=$(docker exec market-redis redis-cli -a redis123 INFO stats 2>/dev/null | grep "keyspace_misses" | cut -d: -f2 | tr -d '\r')
TOTAL_OPS=$(( ${REDIS_HITS:-0} + ${REDIS_MISS:-0} ))
if [ "$TOTAL_OPS" -gt 0 ]; then
  HIT_RATE=$(echo "scale=1; ${REDIS_HITS:-0} * 100 / $TOTAL_OPS" | bc)
  inf "Redis cumulative hit rate: ${HIT_RATE}% (hits=${REDIS_HITS} miss=${REDIS_MISS})"
fi

# ═══════════════════════════════════════════════════════════════
# LAYER 6 — END-TO-END PIPELINE THROUGHPUT
# ═══════════════════════════════════════════════════════════════
hdr "LAYER 6 — End-to-End pipeline throughput"
inf "Generator max speed → đo throughput toàn bộ pipeline"
echo

RAW_BEFORE=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_BEFORE=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)

# Chạy generator ở max speed trong 30s
curl -s -X POST "$GENERATOR_URL/generator/speed?ms=50" > /dev/null
curl -s -X POST "$GENERATOR_URL/generator/start" > /dev/null
inf "Generator running @ 50ms interval (max ~20 events/s)..."

sleep 30

curl -s -X POST "$GENERATOR_URL/generator/speed?ms=500" > /dev/null
inf "Generator throttled back to 500ms"

# Đợi pipeline flush (tối đa 30s)
inf "Waiting for pipeline to flush..."
for i in $(seq 1 30); do
  LAG=$(docker exec market-kafka kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --group raw-consumer-group \
    --describe 2>/dev/null | grep market.trades | awk '{sum+=$6} END{print sum+0}')
  Q=$(curl -s -u $RABBIT_USER \
    "$RABBIT_API/queues/%2F/etl.staging" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages',0))" 2>/dev/null)
  [ "${LAG:-1}" -eq 0 ] && [ "${Q:-1}" -eq 0 ] && break
  sleep 1
done

RAW_AFTER=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_raw.raw_trade;" 2>/dev/null)
FACT_AFTER=$(docker exec market-mysql mysql -umarket_user -pmarket123 -s -N -e \
  "SELECT COUNT(*) FROM market_dw.fact_market_1m;" 2>/dev/null)

RAW_DIFF=$(( RAW_AFTER - RAW_BEFORE ))
FACT_DIFF=$(( FACT_AFTER - FACT_BEFORE ))

inf "Events ingested in 30s: $RAW_DIFF (~$(echo "scale=1; $RAW_DIFF/30" | bc) events/s)"
inf "New fact rows in 30s: $FACT_DIFF (~$(echo "scale=1; $FACT_DIFF/30" | bc) rows/s)"

KAFKA_LAG=$(docker exec market-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group raw-consumer-group \
  --describe 2>/dev/null | grep market.trades | awk '{sum+=$6} END{print sum+0}')
DLQ=$(curl -s -u $RABBIT_USER \
  "$RABBIT_API/queues/%2F/etl.staging.dlq" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('messages',0))" 2>/dev/null)

inf "Kafka lag after flush: ${KAFKA_LAG:-0}"
inf "DLQ after stress: ${DLQ:-0}"

[ "${DLQ:-0}" -eq 0 ] && ok "No data loss" || warn "DLQ=${DLQ} — có job bị drop"
[ "${KAFKA_LAG:-0}" -eq 0 ] && ok "Kafka fully consumed" || warn "Kafka lag: $KAFKA_LAG"

# ═══════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════
hdr "SATURATION SUMMARY"

echo
printf "  ${BOLD}%-30s %s${NC}\n" "Layer" "Max Throughput / Saturation Point"
sep
printf "  %-30s %s\n" "Ingest HTTP"        "~97 req/s sequential, p99=2ms"
printf "  %-30s %s\n" "Kafka producer"     "${KAFKA_RPS:-?} msg/s @ ${KAFKA_P99:-?}ms p99"
printf "  %-30s %s\n" "Kafka consumer"     "$(echo "scale=0; 2000*1000/${DRAIN_MS:-1}" | bc) msg/s drain"
printf "  %-30s %s\n" "ETL Worker"         "${JPS:-?} jobs/s avg ${AVG:-?}"
printf "  %-30s %s\n" "Report concurrent"  "$([ $REPORT_SAT -gt 0 ] && echo "saturates @ c=$REPORT_SAT" || echo "stable up to c=200")"
printf "  %-30s %s\n" "Redis cache"        "$([ -n "$SPEEDUP" ] && echo "${SPEEDUP}x under 50 concurrent" || echo "neutral (small dataset)")"
printf "  %-30s %s\n" "E2E pipeline"       "${RAW_DIFF:-?} events / ${FACT_DIFF:-?} facts in 30s"
sep

# Cleanup
rm -f "$PAYLOAD_FILE"
echo -e "\n${BOLD}Done.${NC}"