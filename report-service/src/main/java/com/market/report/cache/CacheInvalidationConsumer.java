package com.market.report.cache;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

import java.util.Map;

@Slf4j
@Component
@RequiredArgsConstructor
public class CacheInvalidationConsumer {

    private final CacheService cacheService;

    @RabbitListener(queues = "cache.invalidate")
    public void onInvalidate(Map<String, String> event) {
        String symbol = event.get("symbol");
        if (symbol != null) {
            String key = cacheService.buildKey(symbol);
            cacheService.delete(key);
            log.info("[Cache] Invalidated symbol={}", symbol);
        } else {
            // Invalidate tất cả
            cacheService.deleteByPattern("*");
            log.info("[Cache] Invalidated all keys");
        }
    }
}
