package com.market.etl.entity;

import jakarta.persistence.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Data
@Entity
@Table(name = "raw_trade")
public class RawTrade {
    @Id
    @Column(name = "event_id")
    private String eventId;

    @Column(name = "symbol")
    private String symbol;

    @Column(name = "price")
    private BigDecimal price;

    @Column(name = "volume")
    private Long volume;

    @Column(name = "event_time")
    private LocalDateTime eventTime;
}
