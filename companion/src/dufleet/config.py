"""The companion's settings for `dufleet run`: a TOML file, checked with pydantic.

    [hub]
    url = "https://<project>.supabase.co"
    publishable_key = "sb_publishable_..."
    email = "hauler-1@devices.example"   # the bot's device user
    # password_env = "DUFLEET_DEVICE_PASSWORD"  (the password is read from this variable, never the file)

    [bot]
    id = "<the bot's id in the hub>"

    [transport]
    kind = "sim"            # the only kind until ADR-0001 picks the real ones

    [pump]                  # optional; these are the defaults
    lease_s = 60
    poll_s = 2.0
    idle_s = 10.0           # a job T frames have not named for this long has ended
    lost_s = 30.0           # after asking for a resend, wait this long for the result

    [game]                  # optional
    lua_dir = 'C:\\ProgramData\\My Dual Universe\\Game\\data\\lua'

Unknown keys are refused, so a typo does not silently fall back to a default.
"""

from __future__ import annotations

import os
import tomllib
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

DEFAULT_PATH = Path.home() / ".dufleet" / "companion.toml"


class ConfigError(Exception):
    """A config file that cannot be read or does not validate, or a missing secret."""


class _Section(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class HubConfig(_Section):
    url: str
    publishable_key: str = Field(min_length=1)
    email: str = Field(min_length=3)
    password_env: str = "DUFLEET_DEVICE_PASSWORD"

    @field_validator("url")
    @classmethod
    def _http(cls, value: str) -> str:
        if not value.startswith(("https://", "http://")):
            raise ValueError("must start with https:// (or http:// for a local stack)")
        return value.rstrip("/")

    def password(self) -> str:
        value = os.environ.get(self.password_env)
        if not value:
            raise ConfigError(f"set {self.password_env} to the device user's password")
        return value


class BotConfig(_Section):
    id: uuid.UUID


class TransportConfig(_Section):
    kind: Literal["sim"] = "sim"


class PumpConfig(_Section):
    lease_s: int = Field(60, ge=10, le=3600)
    poll_s: float = Field(2.0, gt=0, le=60)
    idle_s: float = Field(10.0, gt=0)
    lost_s: float = Field(30.0, gt=0)


class GameConfig(_Section):
    lua_dir: str | None = None


class Config(_Section):
    hub: HubConfig
    bot: BotConfig
    transport: TransportConfig = TransportConfig()
    pump: PumpConfig = PumpConfig()
    game: GameConfig = GameConfig()


def _describe(exc: ValidationError) -> str:
    return "; ".join(f"{'.'.join(str(p) for p in e['loc'])}: {e['msg']}" for e in exc.errors())


def parse(data: dict) -> Config:
    try:
        return Config.model_validate(data)
    except ValidationError as exc:
        raise ConfigError(_describe(exc)) from None


def load(path: Path = DEFAULT_PATH) -> Config:
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc.strerror or exc}") from None
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from None
    try:
        return parse(data)
    except ConfigError as exc:
        raise ConfigError(f"{path}: {exc}") from None
