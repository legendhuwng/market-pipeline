package com.market.report.repository;

import com.market.report.entity.FactMarket1m;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.math.BigDecimal;
import java.util.List;

public interface FactMarketRepository extends JpaRepository<FactMarket1m, Long> {

    @Query("""
        SELECT f FROM FactMarket1m f
        JOIN DimTime d ON f.timeId = d.timeId
        WHERE (:symbol IS NULL OR f.symbol = :symbol)
        AND (:fromId IS NULL OR d.timeId >= :fromId)
        AND (:toId IS NULL OR d.timeId <= :toId)
        AND (:minPrice IS NULL OR f.avgPrice >= :minPrice)
        AND (:maxPrice IS NULL OR f.avgPrice <= :maxPrice)
        ORDER BY d.timeId DESC
        """)
    Page<FactMarket1m> findWithFilter(
        @Param("symbol")   String symbol,
        @Param("fromId")   Long fromId,
        @Param("toId")     Long toId,
        @Param("minPrice") BigDecimal minPrice,
        @Param("maxPrice") BigDecimal maxPrice,
        Pageable pageable
    );

    @Query("SELECT DISTINCT f.symbol FROM FactMarket1m f ORDER BY f.symbol")
    List<String> findAllSymbols();
}
