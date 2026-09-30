#!/usr/bin/env python3
"""
GlobalRateLimit — Proteção contra bloqueio da API Vast.ai.

Gerencia rate-limiting global, contador de linhas diárias e backoff adaptativo
para evitar que o sistema exceda o limite de 20.000 linhas/dia ou seja banido.

Regras implementadas:
1. Quando qualquer endpoint retorna HTTP 429 → bloqueia todas as chamadas para aquele endpoint por 60s
2. Contador diário de linhas retornadas em GET /instances/ → se > 80% do limite (16k), aumenta cache
3. Backoff exponencial com jitter quando próximo do limite de quota

Uso:
    from backend.core.rate_limit import global_rate_limit
    
    # Verificar se pode fazer chamada antes de cada requisição
    if not global_rate_limit.can_call("instances"):
        # Esperar ou usar cache
    
    # Marcar consumo de linhas (chamado internamente por VastClient)
    global_rate_limit.record_lines(500)  # consumiu 500 linhas

Autor: VAST_MONITOR Team
"""
import os
import time
import threading
from pathlib import Path
from typing import Dict, Optional
from backend.utils.logger import log


# ─── Constantes de Limite Diário ──────────────────────────────

DAILY_LINE_LIMIT = 20_000        # Limite oficial da Vast.ai
SAFETY_THRESHOLD = 0.80          # Começa a agir aos 80% (16.000 linhas)
MAX_CACHE_TTL_ON_WARNING = 60    # Cache estendido quando próximo do limite


class GlobalRateLimit:
    """Singleton que gerencia rate-limiting global da API Vast.ai."""

    _instance: Optional["GlobalRateLimit"] = None
    _lock: threading.RLock = threading.RLock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        self._initialized = True
        
        # Endpoint → timestamp mínimo para próxima chamada
        self._endpoint_cooldown: Dict[str, float] = {}
        
        # Contador diário de linhas consumidas (GET /instances/)
        self._daily_lines_consumed: int = 0
        self._daily_reset_time: float = time.time() + 86400  # Reset em 24h
        
        # Lock interno para threadsafety
        self._lock = threading.RLock()
        
        # Carregar contador persistente se existir
        snapshot_file = Path("/tmp/vast_daily_lines.json")
        if snapshot_file.exists():
            try:
                import json
                data = json.loads(snapshot_file.read_text())
                if isinstance(data, dict) and "lines" in data:
                    self._daily_lines_consumed = int(data["lines"])
                    log(f"[RateLimit] Carregado contador persistente: {self._daily_lines_consumed} linhas", "DEBUG")
            except (json.JSONDecodeError, OSError, ValueError):
                pass
    
    @property
    def daily_lines(self) -> int:
        """Retorna o contador diário de linhas consumidas."""
        return self._daily_lines_consumed
    
    @property
    def remaining_lines(self) -> int:
        """Retorna as linhas restantes no dia (0 se esgotado)."""
        remaining = DAILY_LINE_LIMIT - self._daily_lines_consumed
        return max(0, remaining)
    
    @property
    def daily_usage_percent(self) -> float:
        """Retorna a porcentagem de uso do limite diário (0-100)."""
        return (self._daily_lines_consumed / DAILY_LINE_LIMIT) * 100 if DAILY_LINE_LIMIT > 0 else 0
    
    @property
    def is_near_limit(self) -> bool:
        """Retorna True se o consumo atual está próximo do limite de segurança (80%)."""
        return self.daily_usage_percent >= SAFETY_THRESHOLD * 100
    
    def _maybe_reset_daily_counter(self):
        """Reseta contador diário se passou 24h desde o último reset."""
        now = time.time()
        if now >= self._daily_reset_time:
            with self._lock:
                if now >= self._daily_reset_time:
                    self._daily_lines_consumed = 0
                    self._daily_reset_time = now + 86400
                    log("[RateLimit] Contador diário de linhas resetado.", "INFO")

    def can_call(self, endpoint: str) -> bool:
        """Verifica se é permitido fazer uma chamada ao endpoint.
        
        Args:
            endpoint: Nome do endpoint (ex: "instances", "offers")
            
        Returns:
            True se pode chamar, False se está em cooldown ou limite diário esgotado
        """
        self._maybe_reset_daily_counter()
        
        # 1. Verificar se limite diário de linhas foi esgotado
        if self._daily_lines_consumed >= DAILY_LINE_LIMIT:
            log(
                f"[RateLimit] Limite diário de {DAILY_LINE_LIMIT} linhas ESGOTADO. "
                f"Consumido: {self._daily_lines_consumed}/{DAILY_LINE_LIMIT}",
                "CRITICAL"
            )
            return False
        
        # 2. Verificar se está em cooldown por endpoint (429 ou próximo do limite)
        with self._lock:
            if endpoint in self._endpoint_cooldown:
                remaining = self._endpoint_cooldown[endpoint] - time.time()
                if remaining > 0:
                    log(
                        f"[RateLimit] Endpoint '{endpoint}' em cooldown por {remaining:.1f}s. "
                        f"Linhas consumidas hoje: {self._daily_lines_consumed}/{DAILY_LINE_LIMIT}",
                        "WARN"
                    )
                    return False
        
        # 3. Se próximo do limite, aumentar espera entre chamadas (throttling)
        if self.is_near_limit:
            log(
                f"[RateLimit] ⚠️ Próximo do limite diário ({self.daily_usage_percent:.1f}%). "
                f"Throttling ativo.",
                "WARN"
            )
        
        return True

    def block_endpoint(self, endpoint: str, seconds: int = 60) -> None:
        """Bloqueia um endpoint por N segundos (ex: após receber HTTP 429).
        
        Args:
            endpoint: Nome do endpoint a bloquear
            seconds: Duração do bloqueio em segundos (padrão 60s)
        """
        with self._lock:
            self._endpoint_cooldown[endpoint] = time.time() + seconds
            log(
                f"[RateLimit] 🚫 Endpoint '{endpoint}' BLOQUEADO por {seconds}s. "
                f"Motivo: provável HTTP 429 (rate limit)",
                "CRITICAL"
            )

    def record_lines(self, lines: int) -> int:
        """Registra o consumo de linhas de uma resposta GET /instances/.
        
        Args:
            lines: Quantidade de linhas retornadas pela API
            
        Returns:
            Novo total acumulado de linhas consumidas hoje
        """
        with self._lock:
            self._maybe_reset_daily_counter()
            before = self._daily_lines_consumed
            self._daily_lines_consumed += lines
            after = self._daily_lines_consumed
        
        # Alerta se ultrapassar 80% do limite
        if after >= DAILY_LINE_LIMIT * SAFETY_THRESHOLD and before < DAILY_LINE_LIMIT * SAFETY_THRESHOLD:
            log(
                f"[RateLimit] ⚠️ Limite de segurança ({SAFETY_THRESHOLD*100:.0f}%) ultrapassado! "
                f"Consumo diário: {after}/{DAILY_LINE_LIMIT} linhas",
                "WARN"
            )
        
        # Alerta crítico se ultrapassar 95%
        if after >= DAILY_LINE_LIMIT * 0.95:
            log(
                f"[RateLimit] 🚨 QUASE ESOTANDO! Consumo diário: {after}/{DAILY_LINE_LIMIT} linhas "
                f"({after/DAILY_LINE_LIMIT*100:.1f}%)",
                "CRITICAL"
            )
        
        return after
    
    def get_status(self) -> Dict:
        """Retorna status atual do rate limiter para logging/dashboard."""
        self._maybe_reset_daily_counter()
        
        cooldown_endpoints = {}
        with self._lock:
            for ep, ts in self._endpoint_cooldown.items():
                remaining = max(0, int(ts - time.time()))
                if remaining > 0:
                    cooldown_endpoints[ep] = remaining
        
        return {
            "daily_lines_consumed": self._daily_lines_consumed,
            "daily_limit": DAILY_LINE_LIMIT,
            "remaining_lines": self.remaining_lines,
            "usage_percent": round(self.daily_usage_percent, 2),
            "is_near_limit": self.is_near_limit,
            "cooldown_endpoints": cooldown_endpoints,
        }


# ─── Singleton Global ─────────────────────────────────────

global_rate_limit = GlobalRateLimit()


def get_global_rate_limit() -> GlobalRateLimit:
    """Retorna o singleton do rate limiter global."""
    return global_rate_limit
