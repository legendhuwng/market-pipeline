package com.market.ingest.controller;

import com.market.ingest.dto.TradeEventDto;
import com.market.ingest.kafka.KafkaProducerService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

@Slf4j
@RestController
@RequestMapping("/api")
@RequiredArgsConstructor
public class TradeController {

    private final KafkaProducerService kafkaProducerService;
    private final AtomicLong receivedCount = new AtomicLong(0);

    @PostMapping("/trades")
    public ResponseEntity<Map<String, Object>> receiveTrade(
            @Valid @RequestBody TradeEventDto event) {

        long count = receivedCount.incrementAndGet();
        log.debug("[Ingest] #{} received: symbol={} price={} vol={}",
            count, event.getSymbol(), event.getPrice(), event.getVolume());

        kafkaProducerService.sendTradeEvent(event);

        return ResponseEntity.status(HttpStatus.ACCEPTED).body(Map.of(
            "status", "accepted",
            "eventId", event.getEventId(),
            "receivedCount", count
        ));
    }

    // Health + stats
    @GetMapping("/health")
    public ResponseEntity<Map<String, Object>> health() {
        return ResponseEntity.ok(Map.of(
            "status", "UP",
            "receivedCount", receivedCount.get()
        ));
    }
}
