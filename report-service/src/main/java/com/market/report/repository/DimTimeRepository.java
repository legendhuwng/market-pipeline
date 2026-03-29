package com.market.report.repository;

import com.market.report.entity.DimTime;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.time.LocalDateTime;
import java.util.Optional;

public interface DimTimeRepository extends JpaRepository<DimTime, Long> {

    Optional<DimTime> findByTs(LocalDateTime ts);

    @Query("SELECT d FROM DimTime d WHERE d.ts >= :from ORDER BY d.ts ASC")
    Optional<DimTime> findFirstFrom(@Param("from") LocalDateTime from);

    @Query("SELECT d FROM DimTime d WHERE d.ts <= :to ORDER BY d.ts DESC")
    Optional<DimTime> findLastBefore(@Param("to") LocalDateTime to);
}
