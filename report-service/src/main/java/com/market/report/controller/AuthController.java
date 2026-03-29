package com.market.report.controller;

import com.market.report.dto.LoginRequest;
import com.market.report.dto.LoginResponse;
import com.market.report.security.JwtUtil;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
@RequestMapping("/auth")
@RequiredArgsConstructor
public class AuthController {

    private final JwtUtil            jwtUtil;
    private final UserDetailsService userDetailsService;
    private final PasswordEncoder    passwordEncoder;

    @PostMapping("/login")
    public ResponseEntity<LoginResponse> login(@Valid @RequestBody LoginRequest req) {
        UserDetails user = userDetailsService.loadUserByUsername(req.getUsername());
        if (!passwordEncoder.matches(req.getPassword(), user.getPassword())) {
            throw new BadCredentialsException("Invalid credentials");
        }
        String role = user.getAuthorities().iterator().next()
            .getAuthority().replace("ROLE_", "");
        String token = jwtUtil.generate(req.getUsername(), role);
        log.info("[Auth] Login success: {}", req.getUsername());
        return ResponseEntity.ok(new LoginResponse(token, req.getUsername(), role));
    }
}
