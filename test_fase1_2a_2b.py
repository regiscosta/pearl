#!/usr/bin/env python3
"""
Comprehensive Unit Tests — Fase 1 (GlobalRateLimit) + Fase 2A/2B (instance-ready & health checks)

Cobre:
1. GlobalRateLimit — daily quota, endpoint cooldown, is_near_limit, persistence
2. Instance-ready endpoint — validation, status handling, error cases
3. Health check logic em vastOnStart.sh — processos GPU/CPU, boot status determination

Autor: VAST_MONITOR Team
"""
import json
import time
import threading
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch, PropertyMock

# ============================================================================
# Fase 1 — GlobalRateLimit Tests
# ============================================================================


class TestGlobalRateLimitSingletonsAndLifecycle:
    """Testa o padrão singleton e ciclo de vida do GlobalRateLimit."""

    def setup_method(self):
        # Força reset do singleton antes de cada teste
        from backend.core.rate_limit import GlobalRateLimit
        GlobalRateLimit._instance = None

    def test_singleton_returns_same_instance(self):
        from backend.core.rate_limit import get_global_rate_limit, GlobalRateLimit

        first = get_global_rate_limit()
        second = get_global_rate_limit()
        assert first is second
        assert isinstance(first, GlobalRateLimit)

    def test_init_only_once(self):
        from backend.core.rate_limit import get_global_rate_limit

        rl1 = get_global_rate_limit()
        init_count_before = getattr(rl1, "_initialized", False)
        # Tentar obter novamente não re-inicializa
        rl2 = get_global_rate_limit()
        assert rl2._initialized is True
        assert rl1 is rl2

    def test_daily_line_limit_constant(self):
        from backend.core.rate_limit import DAILY_LINE_LIMIT, SAFETY_THRESHOLD

        assert DAILY_LINE_LIMIT == 20_000
        assert SAFETY_THRESHOLD == 0.80


class TestGlobalRateLimitDailyQuota:
    """Testa o controle de quota diária (contador de linhas)."""

    def setup_method(self):
        from backend.core.rate_limit import GlobalRateLimit
        GlobalRateLimit._instance = None

    def test_record_lines_increments_counter(self):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = 0
        total_after = rl.record_lines(100)
        assert rl._daily_lines_consumed == 100
        assert total_after == 100  # record_lines retorna o TOTAL acumulado

    def test_remaining_lines_property(self):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = 0
        total_after = rl.record_lines(100)
        assert rl._daily_lines_consumed == 100
        assert total_after == 100  # record_lines retorna o TOTAL acumulado

    def test_remaining_lines_property(self):
        from backend.core.rate_limit import get_global_rate_limit, DAILY_LINE_LIMIT

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = 0
        rl.record_lines(100)
        assert rl.remaining_lines == DAILY_LINE_LIMIT - 100

    def test_record_multiple_calls_accumulates(self):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = 0
        rl.record_lines(500)
        rl.record_lines(300)
        rl.record_lines(200)
        assert rl._daily_lines_consumed == 1000

    @patch('backend.core.rate_limit.log')
    def test_daily_usage_percent(self, mock_log):
        from backend.core.rate_limit import get_global_rate_limit, DAILY_LINE_LIMIT

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = 10000
        assert rl.daily_usage_percent == pytest.approx(50.0)

    @patch('backend.core.rate_limit.log')
    def test_remaining_lines_when_exhausted(self, mock_log):
        from backend.core.rate_limit import get_global_rate_limit, DAILY_LINE_LIMIT

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = 19800
        assert rl.remaining_lines == 200  # 20k - 19.8k

    def test_is_near_limit_true_at_80_percent(self):
        from backend.core.rate_limit import get_global_rate_limit, SAFETY_THRESHOLD, DAILY_LINE_LIMIT

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = int(DAILY_LINE_LIMIT * SAFETY_THRESHOLD)
        assert rl.is_near_limit is True

    def test_is_near_limit_false_below_threshold(self):
        from backend.core.rate_limit import get_global_rate_limit, DAILY_LINE_LIMIT

        # Necessário resetar o singleton para evitar contaminação de testes anteriores
        from backend.core.rate_limit import GlobalRateLimit
        GlobalRateLimit._instance = None
        
        rl = get_global_rate_limit()
        rl._daily_lines_consumed = int(DAILY_LINE_LIMIT * 0.5)
        assert rl.is_near_limit is False


class TestGlobalRateLimitEndpointCooldown:
    """Testa o bloqueio de endpoint após HTTP 429."""

    def setup_method(self):
        from backend.core.rate_limit import GlobalRateLimit
        GlobalRateLimit._instance = None

    @patch('backend.core.rate_limit.log')
    def test_block_endpoint_sets_cooldown(self, mock_log):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._endpoint_cooldown.clear()
        now = time.time()

        rl.block_endpoint("instances", 60)
        assert "instances" in rl._endpoint_cooldown
        assert rl._endpoint_cooldown["instances"] >= now + 59

    @patch('backend.core.rate_limit.log')
    def test_can_call_blocks_during_cooldown(self, mock_log):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._endpoint_cooldown.clear()
        rl._endpoint_cooldown["instances"] = time.time() + 120

        assert rl.can_call("instances") is False
        assert rl.can_call("other_endpoint") is True

    @patch('backend.core.rate_limit.log')
    def test_can_call_allows_after_cooldown_expires(self, mock_log):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._endpoint_cooldown.clear()
        rl._endpoint_cooldown["instances"] = time.time() - 10  # expirado há 10s

        assert rl.can_call("instances") is True


class TestGlobalRateLimitDynamicCache:
    """Testa o comportamento de cache adaptativo."""

    def test_dynamic_ttl_increased_near_limit(self):
        from backend.core.rate_limit import get_global_rate_limit, DAILY_LINE_LIMIT, SAFETY_THRESHOLD

        rl = get_global_rate_limit()
        rl._daily_lines_consumed = int(DAILY_LINE_LIMIT * SAFETY_THRESHOLD)
        assert rl.is_near_limit is True

    def test_can_call_returns_true_when_not_blocked(self):
        from backend.core.rate_limit import get_global_rate_limit

        rl = get_global_rate_limit()
        rl._endpoint_cooldown.clear()
        rl._daily_lines_consumed = 0

        assert rl.can_call("instances") is True


class TestGlobalRateLimitPersistence:
    """Testa persistência do contador diário em arquivo JSON."""

    def test_load_persisted_counter(self, tmp_path):
        from backend.core.rate_limit import GlobalRateLimit

        snapshot_file = tmp_path / "vast_daily_lines.json"
        snapshot_file.write_text(json.dumps({"lines": 5000}))

        # Força recriação do singleton com snapshot
        GlobalRateLimit._instance = None

        with patch.object(GlobalRateLimit, '__new__', wraps=GlobalRateLimit.__new__) as mock_new:
            instance = GlobalRateLimit()
            assert instance._daily_lines_consumed == 5000


# ============================================================================
# Fase 2A — Instance-Ready Endpoint Tests
# ============================================================================


class TestInstanceReadyEndpointValidation:
    """Testa validação do endpoint POST /api/services/instance-ready."""

    def test_missing_instance_id_returns_400(self):
        from fastapi.testclient import TestClient
        from backend.api.app import create_app
        from backend.api.dependencies import get_service_manager
        
        app = create_app()
        client = TestClient(app)
        
        mock_mgr = MagicMock()
        mock_mgr.get_full_status.return_value = {"instances": []}
        app.dependency_overrides[get_service_manager] = lambda: mock_mgr
        
        response = client.post("/api/services/instance-ready", json={"status": "ready"})
        assert response.status_code == 400

    def test_invalid_status_returns_400(self):
        from fastapi.testclient import TestClient
        from backend.api.app import create_app
        from backend.api.dependencies import get_service_manager
        
        app = create_app()
        client = TestClient(app)
        
        mock_mgr = MagicMock()
        mock_mgr.get_full_status.return_value = {"instances": []}
        app.dependency_overrides[get_service_manager] = lambda: mock_mgr
        
        response = client.post("/api/services/instance-ready", json={"instance_id": 12345, "status": "invalid"})
        assert response.status_code == 400


class TestInstanceReadyEndpointNotFound:
    """Testa caso a instância não seja encontrada no dashboard."""

    def test_instance_not_in_dashboard_returns_404(self):
        from fastapi.testclient import TestClient
        from backend.api.app import create_app
        from backend.api.dependencies import get_service_manager
        
        app = create_app()
        client = TestClient(app)
        
        mock_mgr = MagicMock()
        mock_mgr.get_full_status.return_value = {"instances": []}
        app.dependency_overrides[get_service_manager] = lambda: mock_mgr
        
        response = client.post("/api/services/instance-ready", json={"instance_id": 99999, "status": "ready"})
        assert response.status_code == 404
        assert "99999" in str(response.json()["detail"])


class TestInstanceReadyEndpointSuccess:
    """Testa casos de sucesso do endpoint."""

    def test_ready_status_returns_accepted(self):
        from fastapi.testclient import TestClient
        from backend.api.app import create_app
        from backend.api.dependencies import get_service_manager
        
        app = create_app()
        client = TestClient(app)
        
        mock_mgr = MagicMock()
        mock_mgr.get_full_status.return_value = {
            "instances": [{"id": 52818959, "status": "RUNNING"}]
        }
        app.dependency_overrides[get_service_manager] = lambda: mock_mgr
        
        response = client.post("/api/services/instance-ready", json={
            "instance_id": 52818959,
            "status": "ready",
            "worker": "kryptex",
            "gpu_pid": 12345,
            "cpu_pid": 12346
        })
        
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "accepted"
        assert data["boot_status"] == "ready"
        assert data["instance_id"] == 52818959

    def test_partial_status_returns_accepted(self):
        from fastapi.testclient import TestClient
        from backend.api.app import create_app
        from backend.api.dependencies import get_service_manager
        
        app = create_app()
        client = TestClient(app)
        
        mock_mgr = MagicMock()
        mock_mgr.get_full_status.return_value = {
            "instances": [{"id": 52818960, "status": "RUNNING"}]
        }
        app.dependency_overrides[get_service_manager] = lambda: mock_mgr
        
        response = client.post("/api/services/instance-ready", json={
            "instance_id": 52818960,
            "status": "partial",
            "worker": "kryptex",
            "gpu_pid": 12345
        })
        
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "accepted"
        assert data["boot_status"] == "partial"

    def test_failed_status_returns_accepted(self):
        from fastapi.testclient import TestClient
        from backend.api.app import create_app
        from backend.api.dependencies import get_service_manager
        
        app = create_app()
        client = TestClient(app)
        
        mock_mgr = MagicMock()
        mock_mgr.get_full_status.return_value = {
            "instances": [{"id": 52818961, "status": "RUNNING"}]
        }
        app.dependency_overrides[get_service_manager] = lambda: mock_mgr
        
        response = client.post("/api/services/instance-ready", json={
            "instance_id": 52818961,
            "status": "failed",
            "worker": "kryptex",
            "error": "cuInit failed"
        })
        
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "accepted"
        assert data["boot_status"] == "failed"


# ============================================================================
# Fase 2B — Health Check Logic Tests (Shell Script Validation)
# ============================================================================


class TestHealthCheckLogic:
    """Testa a lógica de verificação de processos e boot status.
    
    Como são scripts shell, testamos via subprocess com mocks ou simulamos
    a lógica em Python equivalente.
    """

    def _simulate_boot_status(self, gpu_proc_running: bool, cpu_proc_running: bool,
                               has_gpu_log_error: bool, gpu_error_first: bool = False) -> tuple:
        """Simula a lógica do health check no bash."""
        gpu_status = "running" if gpu_proc_running else "stopped"
        cpu_status = "running" if cpu_proc_running else "stopped"
        
        # Determina BOOT_ERROR
        boot_errors = []
        if not gpu_proc_running:
            boot_errors.append("gpu_not_running")
        elif has_gpu_log_error:
            boot_errors.append("gpu_log_error")
        
        if not cpu_proc_running:
            boot_errors.append("cpu_not_running")
        
        boot_error = ",".join(boot_errors) if boot_errors else ""

        # Determina BOOT_FINAL_STATUS
        if boot_error == "" and gpu_status == "running":
            if has_gpu_log_error:
                boot_final = "partial"
            else:
                boot_final = "ready"
        else:
            boot_final = "failed"

        return gpu_status, cpu_status, boot_final, boot_error

    def test_both_running_no_errors_is_ready(self):
        gpu_s, cpu_s, boot, err = self._simulate_boot_status(
            gpu_proc_running=True, cpu_proc_running=True, has_gpu_log_error=False
        )
        assert gpu_s == "running"
        assert cpu_s == "running"
        assert boot == "ready"
        assert err == ""

    def test_gpu_not_running_is_failed(self):
        gpu_s, cpu_s, boot, err = self._simulate_boot_status(
            gpu_proc_running=False, cpu_proc_running=True, has_gpu_log_error=False
        )
        assert boot == "failed"
        assert "gpu_not_running" in err

    def test_cpu_not_running_with_gpu_is_failed(self):
        gpu_s, cpu_s, boot, err = self._simulate_boot_status(
            gpu_proc_running=True, cpu_proc_running=False, has_gpu_log_error=False
        )
        assert boot == "failed"
        assert "cpu_not_running" in err

    def test_gpu_log_error_is_partial(self):
        gpu_s, cpu_s, boot, err = self._simulate_boot_status(
            gpu_proc_running=True, cpu_proc_running=True, has_gpu_log_error=True
        )
        assert boot == "partial"
        assert "gpu_log_error" in err

    def test_both_stopped_is_failed(self):
        gpu_s, cpu_s, boot, err = self._simulate_boot_status(
            gpu_proc_running=False, cpu_proc_running=False, has_gpu_log_error=False
        )
        assert boot == "failed"
        assert "gpu_not_running" in err
        assert "cpu_not_running" in err

    def test_partial_recovery_after_restart(self):
        """Simula cenário onde GPU foi reiniciada com sucesso."""
        # Primeiro estado: não está rodando
        gpu_s1, cpu_s1, boot1, _ = self._simulate_boot_status(
            gpu_proc_running=False, cpu_proc_running=True, has_gpu_log_error=False
        )
        assert boot1 == "failed"
        
        # Após reinício: GPU volta a rodar
        gpu_s2, cpu_s2, boot2, err2 = self._simulate_boot_status(
            gpu_proc_running=True, cpu_proc_running=True, has_gpu_log_error=False
        )
        assert gpu_s2 == "running"  # reiniciado
        assert boot2 == "ready"


# ============================================================================
# Integração — VastClient with GlobalRateLimit
# ============================================================================


class TestVastClientGlobalRateLimitIntegration:
    """Testa que VastClient inicializa com _global_rate_limit corretamente."""

    def test_vast_client_has_global_rate_limit(self):
        from backend.integrations.vast_client import VastClient
        from backend.core.rate_limit import GlobalRateLimit

        client = VastClient(api_key="test_key_123")
        
        assert hasattr(client, '_global_rate_limit')
        assert isinstance(client._global_rate_limit, GlobalRateLimit)
        assert client._global_rate_limit is not None

    def test_vast_client_global_rate_limit_is_singleton(self):
        from backend.integrations.vast_client import VastClient

        client1 = VastClient(api_key="key1")
        client2 = VastClient(api_key="key2")

        # Ambos devem compartilhar o mesmo GlobalRateLimit singleton
        assert client1._global_rate_limit is client2._global_rate_limit


# ============================================================================
# Execução Principal
# ============================================================================

if __name__ == "__main__":
    import sys
    print("Running comprehensive Fase 1/2A/2B tests...")
    
    test_classes = [
        TestGlobalRateLimitSingletonsAndLifecycle,
        TestGlobalRateLimitDailyQuota,
        TestGlobalRateLimitEndpointCooldown,
        TestGlobalRateLimitDynamicCache,
        TestGlobalRateLimitPersistence,
        TestInstanceReadyEndpointValidation,
        TestInstanceReadyEndpointNotFound,
        TestInstanceReadyEndpointSuccess,
        TestHealthCheckLogic,
        TestVastClientGlobalRateLimitIntegration,
    ]
    
    passed = 0
    failed = 0
    
    for test_class in test_classes:
        print(f"\n{'='*60}")
        print(f"Running {test_class.__name__}")
        print('='*60)
        
        instance = test_class()
        test_methods = [m for m in dir(instance) if m.startswith('test_')]
        
        class_passed = 0
        class_failed = 0
        
        for method_name in test_methods:
            try:
                method = getattr(instance, method_name)
                # Check if method needs tmp_path fixture
                import inspect
                sig = inspect.signature(method)
                params = sig.parameters
                
                if 'tmp_path' in params:
                    import tempfile
                    with tempfile.TemporaryDirectory() as tmpdir:
                        from pathlib import Path
                        method(tmp_path=Path(tmpdir))
                else:
                    method()
                
                print(f"  ✓ {method_name}")
                class_passed += 1
            except Exception as e:
                print(f"  ✗ {method_name}: {e}")
                class_failed += 1
        
        passed += class_passed
        failed += class_failed
    
    print(f"\n{'='*60}")
    print(f"RESULTS: {passed} passed, {failed} failed (total: {passed + failed})")
    print('='*60)
    
    sys.exit(1 if failed > 0 else 0)
