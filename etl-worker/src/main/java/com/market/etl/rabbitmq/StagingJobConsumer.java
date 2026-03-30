package com.market.etl.rabbitmq;

import com.market.etl.model.StagingJobMessage;
import com.market.etl.service.EtlService;
import com.market.etl.service.JobTrackingService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.slf4j.MDC;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class StagingJobConsumer {

    private final EtlService         etlService;
    private final JobTrackingService trackingService;
    private final RabbitTemplate     rabbitTemplate;

    @Value("${etl.max-retries:3}")
    private int maxRetries;

    @RabbitListener(queues = "etl.staging")
    public void onStagingJob(StagingJobMessage job, Message message) {
        Integer retryCount = (Integer) message.getMessageProperties()
            .getHeaders().getOrDefault("x-retry-count", 0);

        // Set MDC fields → tự động xuất hiện trong mọi log của thread này
        MDC.put("jobId",      job.getJobId());
        MDC.put("symbol",     job.getSymbol());
        MDC.put("timeBucket", job.getTimeBucket());
        MDC.put("retryCount", String.valueOf(retryCount));

        try {
            trackingService.markRunning(job, retryCount);

            long duration = etlService.process(job);
            trackingService.markSuccess(job.getJobId(), duration);

            MDC.put("status",   "SUCCESS");
            MDC.put("duration", String.valueOf(duration));
            log.info("[ETL] Job completed");

        } catch (Exception e) {
            MDC.put("status", "FAILED");
            MDC.put("error",  e.getMessage());
            log.warn("[ETL] Job failed retry={}/{}", retryCount, maxRetries);

            if (retryCount < maxRetries) {
                rabbitTemplate.convertAndSend("etl.staging.retry", job, msg -> {
                    msg.getMessageProperties().getHeaders()
                        .put("x-retry-count", retryCount + 1);
                    return msg;
                });
            } else {
                log.error("[ETL] Max retries exceeded → DLQ");
                trackingService.markFailed(job.getJobId(), e.getMessage());
                throw new RuntimeException("Max retries exceeded", e);
            }
        } finally {
            MDC.clear(); // Luôn clear để không leak sang request khác
        }
    }
}
