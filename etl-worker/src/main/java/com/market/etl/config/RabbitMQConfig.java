package com.market.etl.config;

import org.springframework.amqp.core.*;
import org.springframework.amqp.rabbit.config.SimpleRabbitListenerContainerFactory;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RabbitMQConfig {

    // ── Main queue ────────────────────────────────────────
    @Bean
    public Queue stagingQueue() {
        return QueueBuilder.durable("etl.staging")
            .withArgument("x-dead-letter-exchange", "")
            .withArgument("x-dead-letter-routing-key", "etl.staging.dlq")
            .build();
    }

    // ── Retry queue – TTL 10s rồi re-enqueue vào main ────
    @Bean
    public Queue stagingRetryQueue() {
        return QueueBuilder.durable("etl.staging.retry")
            .withArgument("x-message-ttl", 10000)                  // chờ 10 giây
            .withArgument("x-dead-letter-exchange", "")
            .withArgument("x-dead-letter-routing-key", "etl.staging") // → về main queue
            .build();
    }

    // ── DLQ – message nằm đây sau khi hết retry ──────────
    @Bean
    public Queue stagingDlq() {
        return QueueBuilder.durable("etl.staging.dlq").build();
    }

    // ── Cache invalidation queue ──────────────────────────
    @Bean
    public Queue cacheInvalidateQueue() {
        return QueueBuilder.durable("cache.invalidate").build();
    }

    // ── Converter & Template ──────────────────────────────
    @Bean
    @SuppressWarnings("deprecation")
    public Jackson2JsonMessageConverter messageConverter() {
        return new Jackson2JsonMessageConverter();
    }

    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory cf) {
        RabbitTemplate t = new RabbitTemplate(cf);
        t.setMessageConverter(messageConverter());
        return t;
    }

    // ── Listener factory ──────────────────────────────────
    @Bean
    @SuppressWarnings("deprecation")
    public SimpleRabbitListenerContainerFactory rabbitListenerContainerFactory(
            ConnectionFactory cf) {
        SimpleRabbitListenerContainerFactory factory = new SimpleRabbitListenerContainerFactory();
        factory.setConnectionFactory(cf);
        factory.setMessageConverter(messageConverter());
        factory.setConcurrentConsumers(2);
        factory.setMaxConcurrentConsumers(5);
        factory.setDefaultRequeueRejected(false); // fail → DLQ, không requeue vô hạn
        return factory;
    }
}
