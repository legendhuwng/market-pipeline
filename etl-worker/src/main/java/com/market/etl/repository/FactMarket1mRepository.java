package com.market.etl.repository;

import com.market.etl.entity.FactMarket1m;
import org.springframework.data.jpa.repository.JpaRepository;

public interface FactMarket1mRepository extends JpaRepository<FactMarket1m, Long> {
    boolean existsBySymbolAndTimeId(String symbol, Long timeId);
}
