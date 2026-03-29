package com.market.report.cache;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.util.Optional;
import java.util.Set;

@Slf4j
@Service
@RequiredArgsConstructor
public class CacheService {

    private final RedisTemplate<String, Object> redisTemplate;

    @Value("${cache.ttl-seconds:60}")
    private long ttlSeconds;

    private static final String PREFIX = "stock:";

    public String buildKey(String symbol) {
        return PREFIX + symbol + ":1m";
    }

    public void put(String key, Object value) {
        try {
            redisTemplate.opsForValue().set(key, value, Duration.ofSeconds(ttlSeconds));
            log.debug("[Cache] SET key={} ttl={}s", key, ttlSeconds);
        } catch (Exception e) {
            log.warn("[Cache] SET failed key={}: {}", key, e.getMessage());
        }
    }

    public Optional<Object> get(String key) {
        try {
            Object val = redisTemplate.opsForValue().get(key);
            if (val != null) {
                log.debug("[Cache] HIT key={}", key);
                return Optional.of(val);
            }
            log.debug("[Cache] MISS key={}", key);
        } catch (Exception e) {
            log.warn("[Cache] GET failed key={}: {}", key, e.getMessage());
        }
        return Optional.empty();
    }

    public void delete(String key) {
        try {
            redisTemplate.delete(key);
            log.info("[Cache] DELETE key={}", key);
        } catch (Exception e) {
            log.warn("[Cache] DELETE failed key={}: {}", key, e.getMessage());
        }
    }

    public void deleteByPattern(String pattern) {
        try {
            Set<String> keys = redisTemplate.keys(PREFIX + pattern);
            if (keys != null && !keys.isEmpty()) {
                redisTemplate.delete(keys);
                log.info("[Cache] DELETE {} keys matching pattern={}", keys.size(), pattern);
            }
        } catch (Exception e) {
            log.warn("[Cache] DELETE pattern failed: {}", e.getMessage());
        }
    }
}
