package com.market.etl.repository;

import com.market.etl.entity.DimTime;
import org.springframework.data.jpa.repository.JpaRepository;
import java.time.LocalDateTime;
import java.util.Optional;

public interface DimTimeRepository extends JpaRepository<DimTime, Long> {
    Optional<DimTime> findByTs(LocalDateTime ts);
}
