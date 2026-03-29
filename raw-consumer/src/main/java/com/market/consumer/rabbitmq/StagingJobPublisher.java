package com.market.consumer.rabbitmq;

import com.market.consumer.config.RabbitMQConfig;
import com.market.consumer.model.StagingJobMessage;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Service;

@Slf4j
@Service
@RequiredArgsConstructor
public class StagingJobPublisher {

    private final RabbitTemplate rabbitTemplate;

    public void publish(StagingJobMessage job) {
        rabbitTemplate.convertAndSend(
            RabbitMQConfig.STAGING_EXCHANGE,
            RabbitMQConfig.STAGING_QUEUE,
            job
        );
        log.debug("[Publisher] Sent staging job: symbol={} bucket={}",
            job.getSymbol(), job.getTimeBucket());
    }
}
