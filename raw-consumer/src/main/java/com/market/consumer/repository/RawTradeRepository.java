package com.market.consumer.repository;

import com.market.consumer.entity.RawTrade;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface RawTradeRepository extends JpaRepository<RawTrade, String> {
}
