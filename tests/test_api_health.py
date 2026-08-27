import os
import sys
from unittest.mock import MagicMock

from fastapi.testclient import TestClient

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

for module_name in [
    "torch",
    "transformers",
    "kokoro",
    "adaptive_classifier",
    "text2emotion",
    "ollama",
    "openai",
    "together",
    "IPython",
    "IPython.display",
    "playsound3",
    "soundfile",
    "pyaudio",
    "librosa",
    "pypdf",
    "langid",
    "pypinyin",
    "fake_useragent",
    "chromedriver_autoinstaller",
    "num2words",
    "sentencepiece",
    "sacremoses",
    "scipy",
    "numpy",
    "selenium_stealth",
    "undetected_chromedriver",
    "markdownify",
]:
    sys.modules.setdefault(module_name, MagicMock())

os.environ.setdefault("WORK_DIR", "/tmp")

import api as api_module


def test_health_is_ready_only_after_successful_initialization(monkeypatch):
    interaction = MagicMock()
    interaction.agents = []
    monkeypatch.setattr(api_module, "initialize_system", lambda: interaction)

    with TestClient(api_module.api) as client:
        assert client.get("/healthz").json()["status"] == "alive"
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_health_returns_service_unavailable_when_initialization_fails(monkeypatch):
    def fail_initialization():
        raise RuntimeError("provider is unavailable")

    monkeypatch.setattr(api_module, "initialize_system", fail_initialization)

    with TestClient(api_module.api) as client:
        assert client.get("/healthz").status_code == 200
        response = client.get("/health")

    assert response.status_code == 503
    assert response.json()["status"] == "not_ready"


def test_query_success_metadata_is_lowercase_for_successful_agent(monkeypatch):
    interaction = MagicMock()
    interaction.agents = []
    interaction.current_agent.agent_name = "test-agent"
    interaction.current_agent.get_blocks_result.return_value = []
    interaction.last_success = True
    monkeypatch.setattr(api_module, "initialize_system", lambda: interaction)

    async def successful_think_wrapper(_interaction, _query):
        return True

    monkeypatch.setattr(api_module, "think_wrapper", successful_think_wrapper)

    with TestClient(api_module.api) as client:
        response = client.post("/query", json={"query": "hi", "tts_enabled": False})

    assert response.status_code == 200
    assert response.json()["success"] == "true"
