-- Tạo thêm database cho staging và DW
CREATE DATABASE IF NOT EXISTS market_staging;
CREATE DATABASE IF NOT EXISTS market_dw;

-- Cấp quyền cho user
GRANT ALL PRIVILEGES ON market_raw.*     TO 'market_user'@'%';
GRANT ALL PRIVILEGES ON market_staging.* TO 'market_user'@'%';
GRANT ALL PRIVILEGES ON market_dw.*      TO 'market_user'@'%';
FLUSH PRIVILEGES;

-- ── RAW LAYER ──────────────────────────────────────────
USE market_raw;

CREATE TABLE IF NOT EXISTS raw_trade (
    event_id    VARCHAR(36)    NOT NULL,
    symbol      VARCHAR(10)    NOT NULL,
    price       DECIMAL(18,4)  NOT NULL,
    volume      BIGINT         NOT NULL,
    event_time  DATETIME(3)    NOT NULL,
    created_at  DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (event_id),
    INDEX idx_symbol_time (symbol, event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── STAGING LAYER ──────────────────────────────────────
USE market_staging;

CREATE TABLE IF NOT EXISTS stg_trade_1m (
    id          BIGINT         NOT NULL AUTO_INCREMENT,
    symbol      VARCHAR(10)    NOT NULL,
    time_bucket DATETIME       NOT NULL,
    open_price  DECIMAL(18,4)  NOT NULL,
    close_price DECIMAL(18,4)  NOT NULL,
    high_price  DECIMAL(18,4)  NOT NULL,
    low_price   DECIMAL(18,4)  NOT NULL,
    total_volume BIGINT        NOT NULL,
    event_count INT            NOT NULL,
    created_at  DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_symbol_bucket (symbol, time_bucket)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── DATA WAREHOUSE ─────────────────────────────────────
USE market_dw;

CREATE TABLE IF NOT EXISTS dim_symbol (
    symbol       VARCHAR(10)  NOT NULL,
    company_name VARCHAR(200) NOT NULL DEFAULT '',
    sector       VARCHAR(100) NOT NULL DEFAULT '',
    exchange     VARCHAR(50)  NOT NULL DEFAULT 'HOSE',
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (symbol)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS dim_time (
    time_id   BIGINT   NOT NULL AUTO_INCREMENT,
    ts        DATETIME NOT NULL,
    minute_of_hour TINYINT NOT NULL,
    hour_of_day    TINYINT NOT NULL,
    day_of_month   TINYINT NOT NULL,
    month_of_year  TINYINT NOT NULL,
    year           SMALLINT NOT NULL,
    PRIMARY KEY (time_id),
    UNIQUE KEY uq_ts (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS fact_market_1m (
    id           BIGINT         NOT NULL AUTO_INCREMENT,
    symbol       VARCHAR(10)    NOT NULL,
    time_id      BIGINT         NOT NULL,
    avg_price    DECIMAL(18,4)  NOT NULL,
    max_price    DECIMAL(18,4)  NOT NULL,
    min_price    DECIMAL(18,4)  NOT NULL,
    open_price   DECIMAL(18,4)  NOT NULL,
    close_price  DECIMAL(18,4)  NOT NULL,
    total_volume BIGINT         NOT NULL,
    trade_count  INT            NOT NULL,
    created_at   DATETIME(3)    NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uq_symbol_time (symbol, time_id),
    INDEX idx_symbol_timeid (symbol, time_id),
    FOREIGN KEY (symbol)  REFERENCES dim_symbol(symbol),
    FOREIGN KEY (time_id) REFERENCES dim_time(time_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Seed một vài symbol mẫu
INSERT IGNORE INTO dim_symbol (symbol, company_name, sector, exchange) VALUES
('VCB',  'Vietcombank',       'Banking',    'HOSE'),
('VNM',  'Vinamilk',          'Consumer',   'HOSE'),
('HPG',  'Hoa Phat Group',    'Steel',      'HOSE'),
('FPT',  'FPT Corporation',   'Technology', 'HOSE'),
('MSN',  'Masan Group',       'Consumer',   'HOSE');