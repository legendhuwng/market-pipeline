# Market Pipeline

A near real-time market data pipeline built with Java Spring Boot, Kafka, RabbitMQ, MySQL, Redis, and Docker Compose.

## 1. Overview

This project simulates a stock market data processing pipeline from ingestion to analytics reporting.

It demonstrates how to:

- generate fake market trade events
- ingest data through REST API
- stream events with Kafka
- persist raw trade data
- orchestrate ETL jobs using RabbitMQ
- transform data into a warehouse-friendly schema
- expose analytics through a secure REST API
- optimize reads using Redis cache

This project is designed as a **microservice-based event-driven system**.

---

## 2. Architecture

### High-Level Flow

```text
Fake Generator
      ↓ HTTP
Ingest Service
      ↓ Kafka
Raw Consumer
      ↓ MySQL (RAW)
      ↓ RabbitMQ
ETL Worker
      ↓ MySQL (STAGING + DW)
      ↓ RabbitMQ
Report Service
      ↓ Redis Cache
      ↓ REST API
Client / Dashboard
```

---

## 3. Tech Stack

### Backend
- Java
- Spring Boot
- Spring Data JPA
- Spring Security
- Spring Kafka
- Spring AMQP

### Infrastructure
- Kafka
- RabbitMQ
- MySQL
- Redis
- Docker Compose

### Architecture / Design
- Microservices
- Event-Driven Architecture
- ETL Pipeline
- Near Real-Time Reporting
- Star Schema / Data Warehouse

---

## 4. Services

### 4.1 fake-generator
Generates fake stock trade events and sends them to the ingest-service via HTTP.

**Responsibilities**
- simulate market activity
- control event generation speed
- start / stop event flow

---

### 4.2 ingest-service
Receives incoming trade events via REST API and publishes them to Kafka.

**Responsibilities**
- validate incoming requests
- act as the ingestion entry point
- decouple producers from downstream consumers

---

### 4.3 raw-consumer
Consumes Kafka messages, stores raw data into MySQL, and publishes ETL jobs to RabbitMQ.

**Responsibilities**
- persist raw trade events
- group data into ETL-friendly buckets
- trigger downstream ETL processing

---

### 4.4 etl-worker
Consumes ETL jobs from RabbitMQ and transforms raw data into staging and warehouse layers.

**Responsibilities**
- aggregate raw data by minute
- populate staging tables
- build fact / dimension warehouse tables
- track ETL job execution
- publish cache invalidation events

---

### 4.5 report-service
Provides reporting APIs based on warehouse data with Redis caching and JWT authentication.

**Responsibilities**
- expose stock analytics endpoints
- protect APIs using JWT
- reduce DB load via Redis cache
- invalidate stale cache when ETL completes

---

## 5. Data Flow

### Step 1 — Fake Event Generation
`fake-generator` creates a random trade event such as:

```json
{
  "symbol": "VCB",
  "price": 93.4,
  "volume": 100,
  "eventTime": "2026-04-02T09:15:03"
}
```

---

### Step 2 — Event Ingestion
`ingest-service` receives the event via REST API:

```http
POST /api/trades
```

It validates the payload and publishes it to Kafka.

---

### Step 3 — Event Streaming
Kafka acts as the streaming backbone.

**Topic**
```text
market.trades
```

---

### Step 4 — Raw Persistence
`raw-consumer` consumes Kafka messages and stores them in the raw data layer.

**Raw table**
```text
raw_trade
```

---

### Step 5 — ETL Trigger
After saving raw data, `raw-consumer` publishes a staging ETL job to RabbitMQ.

**Queue**
```text
etl.staging
```

---

### Step 6 — ETL Transformation
`etl-worker` processes ETL jobs and transforms raw data into:

- staging layer
- data warehouse layer

Tables involved:
- `stg_trade_1m`
- `dim_time`
- `fact_market_1m`

---

### Step 7 — Cache Invalidation
After ETL finishes, the worker publishes a cache invalidation message.

**Queue**
```text
cache.invalidate
```

---

### Step 8 — Reporting API
`report-service` reads warehouse data and serves analytics through REST APIs.

It uses Redis to cache frequently requested results.

---

## 6. Why Kafka and RabbitMQ Together?

This project intentionally uses both.

### Kafka is used for:
- raw event streaming
- append-only event log
- high-throughput ingestion
- replayable event history

### RabbitMQ is used for:
- ETL task orchestration
- retry and delayed retry
- dead-letter queues
- command-style workflow

### Why not use only one?
Because:
- **trade events** behave like a **stream**
- **ETL jobs** behave like **tasks/commands**

Using both tools reflects a more realistic system design.

---

## 7. Data Model

### 7.1 RAW Layer

#### Table: `raw_trade`
Stores the original incoming trade events.

**Purpose**
- audit
- replay
- debugging
- source of truth

---

### 7.2 STAGING Layer

#### Table: `stg_trade_1m`
Stores minute-level aggregated trade data.

**Purpose**
- reduce repeated raw scans
- simplify ETL logic
- prepare data for analytics

---

### 7.3 DATA WAREHOUSE Layer

#### Dimension Table: `dim_time`
Stores normalized time dimensions.

#### Fact Table: `fact_market_1m`
Stores minute-level market metrics.

**Example measures**
- average price
- min price
- max price
- total volume
- trade count

---

## 8. Star Schema

The warehouse follows a basic **star schema**:

```text
           dim_time
               |
               |
        fact_market_1m
```

### Why this matters
It makes reporting and analytics easier than querying transactional raw data directly.

---

## 9. Retry / DLQ Mechanism

ETL jobs are processed through RabbitMQ with retry and DLQ support.

### Main queue
```text
etl.staging
```

### Retry queue
```text
etl.staging.retry
```

### Dead-letter queue
```text
etl.staging.dlq
```

### Flow
- Job fails once → goes to retry queue
- Retry delay expires → job returns to main queue
- Repeated failures → job moves to DLQ

### Benefits
- prevents message loss
- avoids infinite processing loops
- enables operator-driven reprocessing

---

## 10. Cache Strategy

The report service uses **Redis** with the **Cache-Aside pattern**.

### Read Flow
1. Build cache key
2. Check Redis
3. If hit → return cached response
4. If miss → query MySQL
5. Store result in Redis
6. Return response

### Cache Invalidation
After ETL updates the warehouse, `etl-worker` publishes a cache invalidation event.

`report-service` consumes it and removes stale keys.

This ensures analytics stay fresh.

---

## 11. Security

The report API is protected using **JWT authentication**.

### Authentication Flow
1. User logs in
2. Server returns JWT token
3. Client sends:
```http
Authorization: Bearer <token>
```
4. JWT filter validates access for protected endpoints

---

## 12. Observability

The ETL worker includes operational endpoints and metrics.

### Features
- ETL job tracking
- success / failure stats
- average processing duration
- DLQ visibility
- job reprocessing support

This makes the pipeline more maintainable and demo-friendly.

---

## 13. Key Business Flows

### Core pipeline
```text
FakeGeneratorService.run()
        ↓
TradeController.receiveTrade()
        ↓
KafkaProducerService.sendTradeEvent()
        ↓
RawTradeConsumer.consume()
        ↓
StagingJobPublisher.publish()
        ↓
StagingJobConsumer.onStagingJob()
        ↓
EtlService.process()
        ↓
EtlService.doProcess()
        ↓
CacheInvalidationPublisher.invalidate()
        ↓
CacheInvalidationConsumer.onInvalidate()
        ↓
ReportService.getStocks()
```

---

## 14. Strengths of the Project

- clear service separation
- event-driven architecture
- raw/staging/warehouse layering
- retry / DLQ support
- cache invalidation flow
- JWT-secured reporting API
- strong educational value for backend/data engineering interviews

---

## 15. Possible Improvements

### 15.1 Idempotency
ETL jobs should be protected against duplicate processing.

**Potential improvements**
- unique constraints
- idempotent upserts
- dedup keys

---

### 15.2 Outbox Pattern
Some DB-write + message-publish flows may not be fully atomic.

**Potential improvements**
- outbox table
- transactional event publishing

---

### 15.3 Production Monitoring
Current metrics are useful, but production systems would benefit from:
- Prometheus
- Grafana
- alerting
- tracing

---

### 15.4 Schema Evolution
Trade event payloads may evolve over time.

**Potential improvements**
- schema versioning
- schema registry
- backward compatibility rules

---

## 16. How to Run

### Start infrastructure and services
```bash
docker compose up -d
```

### Stop everything
```bash
docker compose down -v
```

---

## 17. Suggested Demo Flow

1. Start all services
2. Start fake-generator
3. Watch trades enter Kafka
4. Verify raw data stored in MySQL
5. Verify ETL jobs processed
6. Call report-service API
7. Observe Redis cache behavior
8. Stop generator / change speed / retry failed jobs

---

## 18. Ideal Use Cases for This Project

This project is suitable for demonstrating:

- backend engineering skills
- event-driven architecture
- data pipeline fundamentals
- Kafka / RabbitMQ integration
- ETL concepts
- Redis caching
- Spring Boot microservices

---

## 19. Interview Summary

This is not just a CRUD application.

It demonstrates:

- ingestion
- streaming
- persistence
- asynchronous processing
- ETL transformation
- data warehousing
- reporting
- caching
- API security

That makes it a strong portfolio project for backend and data-platform-oriented roles.

---

## 20. Author Notes

This project is a strong foundation for discussing:
- distributed systems basics
- message-driven design
- operational reliability
- analytics architecture
- scalability tradeoffs