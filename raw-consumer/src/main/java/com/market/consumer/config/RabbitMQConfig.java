package com.market.consumer.config;

import org.springframework.amqp.core.*;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RabbitMQConfig {

    public static final String STAGING_QUEUE    = "etl.staging";
    public static final String STAGING_DLQ      = "etl.staging.dlq";
    public static final String STAGING_EXCHANGE = "etl.staging.exchange";

    @Bean
    public Queue stagingQueue() {
        return QueueBuilder.durable(STAGING_QUEUE)
            .withArgument("x-dead-letter-exchange", "")
            .withArgument("x-dead-letter-routing-key", STAGING_DLQ)
            .build();
    }

    @Bean
    public Queue stagingDlq() {
        return QueueBuilder.durable(STAGING_DLQ).build();
    }

    @Bean
    public DirectExchange stagingExchange() {
        return new DirectExchange(STAGING_EXCHANGE);
    }

    @Bean
    public Binding stagingBinding(Queue stagingQueue, DirectExchange stagingExchange) {
        return BindingBuilder.bind(stagingQueue).to(stagingExchange).with(STAGING_QUEUE);
    }

    @Bean
    public Jackson2JsonMessageConverter messageConverter() {
        return new Jackson2JsonMessageConverter();
    }

    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory) {
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(messageConverter());
        return template;
    }
}
