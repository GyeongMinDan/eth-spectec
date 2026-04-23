from __future__ import annotations

import re
import shutil
from dataclasses import dataclass
from pathlib import Path


FAR_FUTURE_EPOCH = 18446744073709551615
TEKU_FAR_FUTURE_EPOCH = 2000000000
TEKU_FULU_FAR_FUTURE_EPOCH = TEKU_FAR_FUTURE_EPOCH + 1
TEKU_GLOAS_FAR_FUTURE_EPOCH = TEKU_FAR_FUTURE_EPOCH + 2


@dataclass(frozen=True)
class ForkProfile:
    name: str
    fork_epochs: dict[str, int]
    lodestar_fork_version: str
    nimbus_fork_version: str
    prysm_fork_version: str
    eth2spec_fork_version: str
    checked_in_pure_config: str | None = None

    def teku_args(self) -> list[str]:
        def teku_epoch(epoch: int) -> int:
            # Teku multiplies fork epochs by slots-per-epoch when building the
            # fork schedule. UINT64_MAX overflows there, so use a high practical
            # sentinel for forks that should never activate in official tests.
            return TEKU_FAR_FUTURE_EPOCH if epoch == FAR_FUTURE_EPOCH else epoch

        return [
            f"--Xnetwork-altair-fork-epoch={teku_epoch(self.fork_epochs['altair'])}",
            f"--Xnetwork-bellatrix-fork-epoch={teku_epoch(self.fork_epochs['bellatrix'])}",
            f"--Xnetwork-capella-fork-epoch={teku_epoch(self.fork_epochs['capella'])}",
            f"--Xnetwork-deneb-fork-epoch={teku_epoch(self.fork_epochs['deneb'])}",
            f"--Xnetwork-electra-fork-epoch={teku_epoch(self.fork_epochs['electra'])}",
            f"--Xnetwork-fulu-fork-epoch={TEKU_FULU_FAR_FUTURE_EPOCH}",
            f"--Xnetwork-gloas-fork-epoch={TEKU_GLOAS_FAR_FUTURE_EPOCH}",
        ]


def _epochs(
    *,
    altair: int,
    bellatrix: int,
    capella: int,
    deneb: int,
    electra: int,
) -> dict[str, int]:
    return {
        "altair": altair,
        "bellatrix": bellatrix,
        "capella": capella,
        "deneb": deneb,
        "electra": electra,
    }


FORK_PROFILES: dict[str, ForkProfile] = {
    "phase0": ForkProfile(
        name="phase0",
        fork_epochs=_epochs(
            altair=FAR_FUTURE_EPOCH,
            bellatrix=FAR_FUTURE_EPOCH,
            capella=FAR_FUTURE_EPOCH,
            deneb=FAR_FUTURE_EPOCH,
            electra=FAR_FUTURE_EPOCH,
        ),
        lodestar_fork_version="phase0",
        nimbus_fork_version="phase0",
        prysm_fork_version="phase0",
        eth2spec_fork_version="phase0",
    ),
    "altair": ForkProfile(
        name="altair",
        fork_epochs=_epochs(
            altair=0,
            bellatrix=FAR_FUTURE_EPOCH,
            capella=FAR_FUTURE_EPOCH,
            deneb=FAR_FUTURE_EPOCH,
            electra=FAR_FUTURE_EPOCH,
        ),
        lodestar_fork_version="altair",
        nimbus_fork_version="altair",
        prysm_fork_version="altair",
        eth2spec_fork_version="altair",
    ),
    "bellatrix": ForkProfile(
        name="bellatrix",
        fork_epochs=_epochs(
            altair=0,
            bellatrix=0,
            capella=FAR_FUTURE_EPOCH,
            deneb=FAR_FUTURE_EPOCH,
            electra=FAR_FUTURE_EPOCH,
        ),
        lodestar_fork_version="bellatrix",
        nimbus_fork_version="bellatrix",
        prysm_fork_version="bellatrix",
        eth2spec_fork_version="bellatrix",
    ),
    "capella": ForkProfile(
        name="capella",
        fork_epochs=_epochs(
            altair=0,
            bellatrix=0,
            capella=0,
            deneb=75520,
            electra=364032,
        ),
        lodestar_fork_version="capella",
        nimbus_fork_version="capella",
        prysm_fork_version="capella",
        eth2spec_fork_version="capella",
        checked_in_pure_config="pure_capella_configs",
    ),
    "deneb": ForkProfile(
        name="deneb",
        fork_epochs=_epochs(
            altair=0,
            bellatrix=0,
            capella=0,
            deneb=0,
            electra=364032,
        ),
        lodestar_fork_version="deneb",
        nimbus_fork_version="deneb",
        prysm_fork_version="deneb",
        eth2spec_fork_version="deneb",
        checked_in_pure_config="pure_deneb_configs",
    ),
    "electra": ForkProfile(
        name="electra",
        fork_epochs=_epochs(
            altair=0,
            bellatrix=0,
            capella=0,
            deneb=0,
            electra=0,
        ),
        lodestar_fork_version="electra",
        nimbus_fork_version="electra",
        prysm_fork_version="electra",
        eth2spec_fork_version="electra",
    ),
}


def supported_forks() -> list[str]:
    return list(FORK_PROFILES)


def get_fork_profile(fork_version: str) -> ForkProfile:
    try:
        return FORK_PROFILES[fork_version]
    except KeyError as exc:
        supported = ", ".join(supported_forks())
        raise ValueError(f"unsupported fork-version '{fork_version}' (supported: {supported})") from exc


def lighthouse_testnet_dir(spectec_core_dir: Path, profile: ForkProfile) -> Path:
    converter_dir = spectec_core_dir / "Converter"
    if profile.checked_in_pure_config:
        path = converter_dir / profile.checked_in_pure_config / "lighthouse_testnet"
        if path.exists():
            return path

    return _ensure_generated_lighthouse_testnet(converter_dir, profile)


def _ensure_generated_lighthouse_testnet(converter_dir: Path, profile: ForkProfile) -> Path:
    source_dir = converter_dir / "pure_capella_configs" / "lighthouse_testnet"
    target_dir = (
        converter_dir
        / "_generated_pure_configs"
        / f"pure_{profile.name}_configs"
        / "lighthouse_testnet"
    )

    source_config = source_dir / "config.yaml"
    source_deposit_block = source_dir / "deposit_contract_block.txt"
    target_config = target_dir / "config.yaml"
    target_deposit_block = target_dir / "deposit_contract_block.txt"

    if not source_config.exists():
        raise FileNotFoundError(f"missing Lighthouse pure config template: {source_config}")

    target_dir.mkdir(parents=True, exist_ok=True)

    config_text = source_config.read_text()
    replacements = {
        "ALTAIR_FORK_EPOCH": profile.fork_epochs["altair"],
        "BELLATRIX_FORK_EPOCH": profile.fork_epochs["bellatrix"],
        "CAPELLA_FORK_EPOCH": profile.fork_epochs["capella"],
        "DENEB_FORK_EPOCH": profile.fork_epochs["deneb"],
        "ELECTRA_FORK_EPOCH": profile.fork_epochs["electra"],
        "FULU_FORK_EPOCH": FAR_FUTURE_EPOCH,
        "GLOAS_FORK_EPOCH": FAR_FUTURE_EPOCH,
    }
    for key, value in replacements.items():
        config_text = re.sub(
            rf"^({key}:\s*)\d+(\s*(?:#.*)?)$",
            rf"\g<1>{value}\2",
            config_text,
            flags=re.MULTILINE,
        )

    target_config.write_text(config_text)
    if source_deposit_block.exists() and not target_deposit_block.exists():
        shutil.copy2(source_deposit_block, target_deposit_block)

    return target_dir
