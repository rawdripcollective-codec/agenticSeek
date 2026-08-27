#!/usr/bin/env python3

from __future__ import annotations

import asyncio
import configparser
import os
import sys
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import TYPE_CHECKING, Any

import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from sources.logger import Logger
from sources.schemas import QueryRequest, QueryResponse

if TYPE_CHECKING:
    from sources.interaction import Interaction

APP_VERSION = "0.2.0"
PROJECT_ROOT = Path(__file__).resolve().parent
SCREENSHOTS_DIR = PROJECT_ROOT / ".screenshots"
SCREENSHOTS_DIR.mkdir(exist_ok=True)

load_dotenv(PROJECT_ROOT / ".env")

config = configparser.ConfigParser()
if not config.read(PROJECT_ROOT / "config.ini"):
    raise RuntimeError("Unable to load config.ini from the application directory.")

logger = Logger("backend.log")


class RuntimeState:
    """Runtime-owned dependencies and readiness state for the API process."""

    def __init__(self) -> None:
        self.interaction: "Interaction | None" = None
        self.ready = False
        self.startup_error: str | None = None
        self.query_lock = asyncio.Lock()


def is_running_in_docker() -> bool:
    """Detect whether the current process is running inside a Docker container."""
    if os.path.exists("/.dockerenv"):
        return True
    try:
        return "docker" in Path("/proc/1/cgroup").read_text(encoding="utf-8")
    except OSError:
        return False


def config_value(section: str, option: str, environment_name: str) -> str:
    """Read a configuration value, allowing an explicit deployment-time override."""
    return os.getenv(environment_name, config.get(section, option)).strip()


def config_bool(section: str, option: str, environment_name: str) -> bool:
    value = config_value(section, option, environment_name).lower()
    if value not in {"true", "false", "1", "0", "yes", "no", "on", "off"}:
        raise ValueError(f"{environment_name} must be a boolean value.")
    return value in {"true", "1", "yes", "on"}


def allowed_origins() -> list[str]:
    """Build an explicit CORS allow-list; wildcard origins are opt-in and credential-free."""
    raw_origins = os.getenv("CORS_ALLOWED_ORIGINS", "http://localhost:3000")
    origins = [origin.strip().rstrip("/") for origin in raw_origins.split(",") if origin.strip()]
    if not origins:
        raise ValueError("CORS_ALLOWED_ORIGINS must contain at least one origin.")
    return origins


def initialize_system() -> "Interaction":
    """Initialize provider, browser, and agent graph once during application startup."""
    from sources.agents import BrowserAgent, CasualAgent, CoderAgent, FileAgent, PlannerAgent
    from sources.browser import Browser, create_driver
    from sources.interaction import Interaction
    from sources.llm_provider import Provider

    stealth_mode = config_bool("BROWSER", "stealth_mode", "BROWSER_STEALTH_MODE")
    headless = config_bool("BROWSER", "headless_browser", "BROWSER_HEADLESS")
    if is_running_in_docker() and not headless:
        logger.warning("Detected Docker environment; forcing headless browser mode.")
        headless = True

    personality_folder = (
        "jarvis" if config_bool("MAIN", "jarvis_personality", "JARVIS_PERSONALITY") else "base"
    )
    languages = config_value("MAIN", "languages", "AGENTICSEEK_LANGUAGES").split()
    if not languages:
        raise ValueError("AGENTICSEEK_LANGUAGES must contain at least one language code.")

    provider = Provider(
        provider_name=config_value("MAIN", "provider_name", "AGENTICSEEK_PROVIDER_NAME"),
        model=config_value("MAIN", "provider_model", "AGENTICSEEK_PROVIDER_MODEL"),
        server_address=config_value(
            "MAIN", "provider_server_address", "AGENTICSEEK_PROVIDER_SERVER_ADDRESS"
        ),
        is_local=config_bool("MAIN", "is_local", "AGENTICSEEK_PROVIDER_IS_LOCAL"),
    )
    logger.info(f"Provider initialized: {provider.provider_name} ({provider.model})")

    browser = Browser(
        create_driver(headless=headless, stealth_mode=stealth_mode, lang=languages[0]),
        anticaptcha_manual_install=stealth_mode,
    )
    logger.info("Browser initialized")

    agents = [
        CasualAgent(
            name=config_value("MAIN", "agent_name", "AGENTICSEEK_AGENT_NAME"),
            prompt_path=f"prompts/{personality_folder}/casual_agent.txt",
            provider=provider,
            verbose=False,
        ),
        CoderAgent(
            name="coder",
            prompt_path=f"prompts/{personality_folder}/coder_agent.txt",
            provider=provider,
            verbose=False,
        ),
        FileAgent(
            name="File Agent",
            prompt_path=f"prompts/{personality_folder}/file_agent.txt",
            provider=provider,
            verbose=False,
        ),
        BrowserAgent(
            name="Browser",
            prompt_path=f"prompts/{personality_folder}/browser_agent.txt",
            provider=provider,
            verbose=False,
            browser=browser,
        ),
        PlannerAgent(
            name="Planner",
            prompt_path=f"prompts/{personality_folder}/planner_agent.txt",
            provider=provider,
            verbose=False,
            browser=browser,
        ),
    ]
    logger.info("Agents initialized")

    return Interaction(
        agents,
        tts_enabled=config_bool("MAIN", "speak", "AGENTICSEEK_SPEAK"),
        stt_enabled=config_bool("MAIN", "listen", "AGENTICSEEK_LISTEN"),
        recover_last_session=config_bool(
            "MAIN", "recover_last_session", "AGENTICSEEK_RECOVER_LAST_SESSION"
        ),
        langs=languages,
    )


def close_browser(interaction: "Interaction | None") -> None:
    """Best-effort browser cleanup during a graceful API shutdown."""
    if interaction is None:
        return
    for agent in getattr(interaction, "agents", []):
        browser = getattr(agent, "browser", None)
        driver = getattr(browser, "driver", None)
        if driver is None:
            continue
        try:
            driver.quit()
        except Exception as error:  # Cleanup must not block container shutdown.
            logger.warning(f"Browser cleanup failed: {error}")
        return


@asynccontextmanager
async def lifespan(app: FastAPI):
    runtime = RuntimeState()
    app.state.runtime = runtime
    try:
        runtime.interaction = initialize_system()
        runtime.ready = True
        logger.info("AgenticSeek API is ready to receive requests.")
    except (Exception, SystemExit) as error:
        runtime.startup_error = type(error).__name__
        logger.error(
            "AgenticSeek initialization failed; readiness will remain unavailable "
            f"({type(error).__name__})."
        )
    yield
    close_browser(runtime.interaction)


api = FastAPI(title="AgenticSeek API", version=APP_VERSION, lifespan=lifespan)
api.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins(),
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "Authorization"],
)
api.mount("/screenshots", StaticFiles(directory=SCREENSHOTS_DIR), name="screenshots")


def runtime_for(request: Request) -> RuntimeState:
    return request.app.state.runtime


def service_unavailable(runtime: RuntimeState) -> JSONResponse:
    return JSONResponse(
        status_code=503,
        content={
            "status": "not_ready",
            "detail": "Agent initialization failed. Check backend logs and runtime configuration.",
            "error_type": runtime.startup_error,
        },
    )


@api.get("/healthz")
async def liveness_check() -> dict[str, str]:
    """Process liveness endpoint for container orchestration."""
    return {"status": "alive", "version": APP_VERSION}


@api.get("/health")
async def readiness_check(request: Request):
    """Readiness endpoint used by the frontend, Compose, and startup script."""
    runtime = runtime_for(request)
    if not runtime.ready:
        return service_unavailable(runtime)
    return {"status": "ready", "version": APP_VERSION}


@api.get("/screenshot")
async def get_screenshot():
    screenshot_path = SCREENSHOTS_DIR / "updated_screen.png"
    if screenshot_path.exists():
        return FileResponse(screenshot_path)
    return JSONResponse(status_code=404, content={"error": "No screenshot available"})


@api.get("/is_active")
async def is_active(request: Request):
    runtime = runtime_for(request)
    if not runtime.ready or runtime.interaction is None:
        return service_unavailable(runtime)
    return {"is_active": runtime.interaction.is_active}


@api.post("/stop")
async def stop(request: Request):
    runtime = runtime_for(request)
    if not runtime.ready or runtime.interaction is None:
        return service_unavailable(runtime)
    current_agent = runtime.interaction.current_agent
    if current_agent is None:
        return JSONResponse(status_code=409, content={"error": "No active agent to stop"})
    current_agent.request_stop()
    return {"status": "stopped"}


@api.get("/latest_answer")
async def get_latest_answer(request: Request):
    runtime = runtime_for(request)
    if not runtime.ready or runtime.interaction is None:
        return service_unavailable(runtime)
    interaction = runtime.interaction
    if interaction.current_agent is None:
        return JSONResponse(status_code=404, content={"error": "No agent available"})

    current_agent = interaction.current_agent
    return JSONResponse(
        status_code=200,
        content={
            "done": "true",
            "answer": current_agent.last_answer,
            "reasoning": current_agent.last_reasoning,
            "agent_name": current_agent.agent_name,
            "success": current_agent.success,
            "blocks": {
                str(index): block.jsonify()
                for index, block in enumerate(interaction.get_last_blocks_result())
            },
            "status": current_agent.get_status_message,
            "uid": str(uuid.uuid4()),
        },
    )


async def think_wrapper(interaction: "Interaction", query: str) -> bool:
    interaction.last_query = query
    logger.info("Agent request is being processed.")
    try:
        success = await interaction.think()
    except Exception as error:
        logger.error(f"Agent request failed: {type(error).__name__}")
        interaction.last_answer = ""
        interaction.last_reasoning = "An internal agent error occurred. Check backend logs."
        interaction.last_success = False
        raise

    if not success:
        interaction.last_answer = "Error: No answer from agent"
        interaction.last_reasoning = "Error: No reasoning from agent"
        interaction.last_success = False
    else:
        interaction.last_success = True
    from sources.utility import pretty_print

    pretty_print(interaction.last_answer)
    interaction.speak_answer()
    return success


@api.post("/query", response_model=QueryResponse)
async def process_query(request: Request, payload: QueryRequest):
    runtime = runtime_for(request)
    if not runtime.ready or runtime.interaction is None:
        return service_unavailable(runtime)
    if runtime.query_lock.locked():
        return JSONResponse(
            status_code=429,
            content={
                "done": "false",
                "answer": "",
                "reasoning": "",
                "agent_name": "Unknown",
                "success": "false",
                "blocks": {},
                "status": "Another query is already being processed.",
                "uid": str(uuid.uuid4()),
            },
        )

    interaction = runtime.interaction
    query_response = QueryResponse(
        done="false",
        answer="",
        reasoning="",
        agent_name="Unknown",
        success="false",
        blocks={},
        status="Ready",
        uid=str(uuid.uuid4()),
    )

    async with runtime.query_lock:
        try:
            success = await think_wrapper(interaction, payload.query)
            if not success:
                query_response.answer = interaction.last_answer
                query_response.reasoning = interaction.last_reasoning
                return JSONResponse(status_code=400, content=query_response.jsonify())

            if interaction.current_agent is None:
                logger.error("No current agent was available after processing a query.")
                query_response.answer = "Error: No current agent"
                return JSONResponse(status_code=400, content=query_response.jsonify())

            query_response.done = "true"
            query_response.answer = interaction.last_answer
            query_response.reasoning = interaction.last_reasoning
            query_response.agent_name = interaction.current_agent.agent_name
            query_response.success = "true" if interaction.last_success else "false"
            query_response.blocks = {
                str(index): block.jsonify()
                for index, block in enumerate(interaction.current_agent.get_blocks_result())
            }
            logger.info("Agent request completed successfully.")
            return JSONResponse(status_code=200, content=query_response.jsonify())
        except Exception as error:
            query_response.reasoning = "An internal agent error occurred. Check backend logs."
            logger.error(f"Query processing failed: {type(error).__name__}")
            return JSONResponse(status_code=500, content=query_response.jsonify())
        finally:
            if config_bool("MAIN", "save_session", "AGENTICSEEK_SAVE_SESSION"):
                interaction.save_session()


def backend_port() -> int:
    raw_port = os.getenv("BACKEND_PORT", "7777")
    try:
        port = int(raw_port)
    except ValueError as error:
        raise ValueError("BACKEND_PORT must be a valid integer.") from error
    if not 1 <= port <= 65535:
        raise ValueError("BACKEND_PORT must be between 1 and 65535.")
    return port


def backend_host() -> str:
    default_host = "0.0.0.0"  # nosec B104 - Compose binds host ports locally.
    host = os.getenv("BACKEND_LISTEN_HOST", default_host)
    if host not in {"0.0.0.0", "127.0.0.1", "::"}:  # nosec B104 - allow-list, not exposure.
        raise ValueError("BACKEND_LISTEN_HOST must be 0.0.0.0, 127.0.0.1, or ::.")
    return host


if __name__ == "__main__":
    environment = "Docker" if is_running_in_docker() else "host machine"
    print(f"[AgenticSeek] Starting on {environment}.")
    uvicorn.run(api, host=backend_host(), port=backend_port())
