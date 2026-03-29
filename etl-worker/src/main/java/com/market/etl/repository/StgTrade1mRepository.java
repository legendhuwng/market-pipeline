package com.market.etl.repository;

import com.market.etl.entity.StgTrade1m;
import org.springframework.data.jpa.repository.JpaRepository;
import java.time.LocalDateTime;
import java.util.Optional;

public interface StgTrade1mRepository extends JpaRepository<StgTrade1m, Long> {
    Optional<StgTrade1m> findBySymbolAndTimeBucket(String symbol, LocalDateTime timeBucket);
}
