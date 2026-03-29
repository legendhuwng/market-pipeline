package com.market.generator.service;

import com.market.generator.config.GeneratorConfig;
import com.market.generator.model.TradeEvent;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestTemplate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

@Slf4j
@Service
@RequiredArgsConstructor
public class FakeGeneratorService implements Runnable {

    private final GeneratorConfig config;
    private final RestTemplate    restTemplate;

    private static final Map<String, Double> BASE_PRICES = Map.of(
        "VCB", 85.5,  "VNM", 68.2,  "HPG", 27.8,
        "FPT", 120.3, "MSN", 55.6,  "TCB", 32.1,
        "BID", 44.8,  "CTG", 31.5,  "VIC", 42.0,
        "GAS", 78.9
    );

    @Value("${symbols.list}")
    private String symbolsRaw;

    private final Random        random    = new Random();
    private final AtomicBoolean running   = new AtomicBoolean(true);
    private final AtomicLong    sentCount = new AtomicLong(0);
    private volatile boolean    started   = false;

    // Dùng thread riêng thay vì @Scheduled để control interval runtime
    @Override
    public void run() {
        log.info("[Generator] Thread started");
        while (true) {
            try {
                if (running.get() && config.isEnabled()) {
                    TradeEvent event = buildRandomEvent();
                    try {
                        restTemplate.postForEntity(config.getIngestUrl(), event, Void.class);
                        long count = sentCount.incrementAndGet();
                        if (count % 100 == 0) {
                            log.info("[Generator] Sent {} events. Last: {} @ {}",
                                count, event.getSymbol(), event.getPrice());
                        }
                    } catch (Exception e) {
                        log.warn("[Generator] Ingest unreachable: {}", e.getMessage());
                    }
                }
                Thread.sleep(config.getIntervalMs());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    private TradeEvent buildRandomEvent() {
        List<String> symbols = List.of(symbolsRaw.split(","));
        String symbol = symbols.get(random.nextInt(symbols.size()));
        double base   = BASE_PRICES.getOrDefault(symbol, 50.0);
        double change = (random.nextDouble() - 0.5) * 2.0;
        BigDecimal price = BigDecimal.valueOf(base * (1 + change / 100))
            .setScale(2, RoundingMode.HALF_UP);
        long volume = 100L * (random.nextInt(200) + 1);
        return TradeEvent.builder()
            .eventId(UUID.randomUUID().toString())
            .symbol(symbol)
            .price(price)
            .volume(volume)
            .eventTime(LocalDateTime.now())
            .build();
    }

    public void start()  { running.set(true);  log.info("[Generator] STARTED"); }
    public void stop()   { running.set(false); log.info("[Generator] STOPPED"); }
    public boolean isRunning() { return running.get(); }
    public long getSentCount() { return sentCount.get(); }

    public void setIntervalMs(long ms) {
        config.setIntervalMs(ms);
        log.info("[Generator] Interval changed to {}ms", ms);
    }
}
