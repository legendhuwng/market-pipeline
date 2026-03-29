package com.market.consumer.kafka;

import com.market.consumer.entity.RawTrade;
import com.market.consumer.model.StagingJobMessage;
import com.market.consumer.model.TradeEventMessage;
import com.market.consumer.rabbitmq.StagingJobPublisher;
import com.market.consumer.repository.RawTradeRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.*;

@Slf4j
@Service
@RequiredArgsConstructor
public class RawTradeConsumer {

    private final RawTradeRepository rawTradeRepository;
    private final StagingJobPublisher stagingJobPublisher;

    private static final DateTimeFormatter FMT = DateTimeFormatter.ISO_LOCAL_DATE_TIME;

    @KafkaListener(
        topics = "${kafka.topic.trades}",
        groupId = "raw-consumer-group",
        containerFactory = "kafkaListenerContainerFactory"
    )
    @Transactional
    public void consume(List<TradeEventMessage> events) {
        if (events == null || events.isEmpty()) return;

        log.info("[Consumer] Received batch of {} events", events.size());

        // 1. Build entity list
        List<RawTrade> trades = new ArrayList<>();
        for (TradeEventMessage e : events) {
            try {
                LocalDateTime eventTime = LocalDateTime.parse(e.getEventTime(), FMT);
                trades.add(RawTrade.builder()
                    .eventId(e.getEventId())
                    .symbol(e.getSymbol())
                    .price(e.getPrice())
                    .volume(e.getVolume())
                    .eventTime(eventTime)
                    .createdAt(LocalDateTime.now())
                    .build());
            } catch (Exception ex) {
                log.warn("[Consumer] Skip bad event {}: {}", e.getEventId(), ex.getMessage());
            }
        }

        // 2. Batch insert – ignore duplicate eventId
        if (!trades.isEmpty()) {
            rawTradeRepository.saveAll(trades);
            log.info("[Consumer] Saved {} records to raw_trade", trades.size());
        }

        // 3. Group by (symbol, minute) → push staging jobs
        Set<String> pushed = new HashSet<>();
        for (TradeEventMessage e : events) {
            try {
                LocalDateTime t = LocalDateTime.parse(e.getEventTime(), FMT);
                // Truncate to minute bucket
                LocalDateTime bucket = t.truncatedTo(ChronoUnit.MINUTES);
                String key = e.getSymbol() + "|" + bucket;

                if (pushed.add(key)) { // chỉ push 1 job per (symbol, minute) per batch
                    StagingJobMessage job = StagingJobMessage.builder()
                        .jobId(UUID.randomUUID().toString())
                        .type("BUILD_STAGING_1M")
                        .symbol(e.getSymbol())
                        .timeBucket(bucket.toString())
                        .build();
                    stagingJobPublisher.publish(job);
                }
            } catch (Exception ex) {
                log.warn("[Consumer] Skip staging job for {}: {}", e.getEventId(), ex.getMessage());
            }
        }

        log.info("[Consumer] Pushed {} staging jobs to RabbitMQ", pushed.size());
    }
}
