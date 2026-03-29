package com.market.etl.rabbitmq;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Service;

import java.util.Map;

@Slf4j
@Service
@RequiredArgsConstructor
public class CacheInvalidationPublisher {

    private final RabbitTemplate rabbitTemplate;

    public void invalidate(String symbol) {
        try {
            rabbitTemplate.convertAndSend(
                "cache.invalidate",
                Map.of("symbol", symbol)
            );
            log.debug("[ETL] Cache invalidation sent for symbol={}", symbol);
        } catch (Exception e) {
            log.warn("[ETL] Cache invalidation failed for {}: {}", symbol, e.getMessage());
        }
    }
}
