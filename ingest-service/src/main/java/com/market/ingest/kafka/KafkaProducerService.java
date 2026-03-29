package com.market.ingest.kafka;

import com.market.ingest.dto.TradeEventDto;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Service;

import java.util.concurrent.CompletableFuture;

@Slf4j
@Service
@RequiredArgsConstructor
public class KafkaProducerService {

    private final KafkaTemplate<String, TradeEventDto> kafkaTemplate;

    @Value("${kafka.topic.trades}")
    private String tradesTopic;

    public void sendTradeEvent(TradeEventDto event) {
        // Key = symbol → cùng symbol vào cùng partition → đảm bảo ordering
        CompletableFuture<SendResult<String, TradeEventDto>> future =
            kafkaTemplate.send(tradesTopic, event.getSymbol(), event);

        future.whenComplete((result, ex) -> {
            if (ex != null) {
                log.error("[Ingest] Kafka send FAILED eventId={} symbol={} err={}",
                    event.getEventId(), event.getSymbol(), ex.getMessage());
            } else {
                log.debug("[Ingest] Kafka OK eventId={} symbol={} partition={} offset={}",
                    event.getEventId(),
                    event.getSymbol(),
                    result.getRecordMetadata().partition(),
                    result.getRecordMetadata().offset());
            }
        });
    }
}
