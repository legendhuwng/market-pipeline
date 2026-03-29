package com.market.consumer.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
@Entity
@Builder
@NoArgsConstructor
@AllArgsConstructor
@Table(name = "raw_trade", schema = "market_raw")
public class RawTrade {

    @Id
    @Column(name = "event_id", length = 36)
    private String eventId;

    @Column(name = "symbol", nullable = false, length = 10)
    private String symbol;

    @Column(name = "price", nullable = false, precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "volume", nullable = false)
    private Long volume;

    @Column(name = "event_time", nullable = false)
    private LocalDateTime eventTime;

    @Column(name = "created_at")
    private LocalDateTime createdAt;
}
