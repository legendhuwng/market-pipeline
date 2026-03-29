package com.market.etl.repository;

import com.market.etl.entity.RawTrade;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.time.LocalDateTime;
import java.util.List;

public interface RawTradeRepository extends JpaRepository<RawTrade, String> {

    @Query("SELECT r FROM RawTrade r WHERE r.symbol = :symbol " +
           "AND r.eventTime >= :from AND r.eventTime < :to " +
           "ORDER BY r.eventTime ASC")
    List<RawTrade> findBySymbolAndMinute(
        @Param("symbol") String symbol,
        @Param("from") LocalDateTime from,
        @Param("to") LocalDateTime to
    );
}
