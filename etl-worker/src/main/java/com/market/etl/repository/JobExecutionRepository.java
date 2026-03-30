package com.market.etl.repository;

import com.market.etl.entity.JobExecution;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;

public interface JobExecutionRepository extends JpaRepository<JobExecution, Long> {

    Optional<JobExecution> findByJobId(String jobId);

    Page<JobExecution> findByStatusOrderByCreatedAtDesc(String status, Pageable pageable);

    List<JobExecution> findByStatusOrderByCreatedAtDesc(String status);

    @Query("SELECT COUNT(j) FROM JobExecution j WHERE j.status = :status")
    long countByStatus(@Param("status") String status);

    @Query("SELECT AVG(j.durationMs) FROM JobExecution j WHERE j.status = 'SUCCESS'")
    Double avgDurationMs();
}
