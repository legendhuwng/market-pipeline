package com.market.etl.service;

import com.market.etl.entity.JobExecution;
import com.market.etl.model.StagingJobMessage;
import com.market.etl.repository.JobExecutionRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;

@Slf4j
@Service
@RequiredArgsConstructor
public class JobTrackingService {

    private final JobExecutionRepository jobRepo;

    // Dùng REQUIRES_NEW để tracking không bị rollback cùng ETL transaction
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void markRunning(StagingJobMessage job, int retryCount) {
        JobExecution execution = jobRepo.findByJobId(job.getJobId())
            .orElse(JobExecution.builder()
                .jobId(job.getJobId())
                .jobType(job.getType())
                .symbol(job.getSymbol())
                .timeBucket(LocalDateTime.parse(job.getTimeBucket()))
                .createdAt(LocalDateTime.now())
                .build());

        execution.setStatus("RUNNING");
        execution.setRetryCount(retryCount);
        execution.setUpdatedAt(LocalDateTime.now());
        jobRepo.save(execution);
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void markSuccess(String jobId, long durationMs) {
        jobRepo.findByJobId(jobId).ifPresent(e -> {
            e.setStatus("SUCCESS");
            e.setDurationMs(durationMs);
            e.setErrorMsg(null);
            e.setUpdatedAt(LocalDateTime.now());
            jobRepo.save(e);
            log.debug("[Track] SUCCESS job={} duration={}ms", jobId, durationMs);
        });
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void markFailed(String jobId, String errorMsg) {
        jobRepo.findByJobId(jobId).ifPresent(e -> {
            e.setStatus("FAILED");
            e.setErrorMsg(errorMsg != null && errorMsg.length() > 500
                ? errorMsg.substring(0, 500) : errorMsg);
            e.setUpdatedAt(LocalDateTime.now());
            jobRepo.save(e);
            log.warn("[Track] FAILED job={} err={}", jobId, errorMsg);
        });
    }
}
