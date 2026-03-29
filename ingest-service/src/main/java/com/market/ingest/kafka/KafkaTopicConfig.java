package com.market.ingest.kafka;

import org.apache.kafka.clients.admin.NewTopic;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.TopicBuilder;

@Configuration
public class KafkaTopicConfig {

    @Value("${kafka.topic.trades}")
    private String tradesTopic;

    @Bean
    public NewTopic tradesTopic() {
        return TopicBuilder.name(tradesTopic)
            .partitions(3)   // 3 partition – mỗi symbol vào 1 partition riêng
            .replicas(1)     // dev env: 1 replica là đủ
            .build();
    }
}
