#!/usr/bin/env python3
"""Offline consistency checks for the built SIMDTEST launch; Python stdlib only."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise SystemExit(message)


def artifact(name):
    path = ROOT / "out" / f"{name}.sol" / f"{name}.json"
    check(path.is_file(), f"Missing {path}; run forge build first")
    return json.loads(path.read_text())


def executable_opcodes(code):
    # Solc's trailing CBOR metadata is data, as are PUSH immediate operands.
    metadata_length = int.from_bytes(code[-2:], "big")
    check(metadata_length + 2 <= len(code), "Invalid solc metadata trailer")
    executable = code[: -metadata_length - 2]
    pc = 0
    while pc < len(executable):
        opcode = executable[pc]
        yield pc, opcode
        pc += 1 + (opcode - 0x5F if 0x60 <= opcode <= 0x7F else 0)


manifest = json.loads((ROOT / "launch.json").read_text())
check(manifest["kind"] == "univ4_hook", "Wrong manifest kind")
check(manifest["chainId"] == 1, "Wrong chain")
check(manifest["hook"]["contract"] == "SIMDTESTHook", "Hook must be a plain contract name")
check(manifest["token"]["contract"] == "SIMDTEST", "Token must be a plain contract name")
check(manifest["token"]["name"] == manifest["token"]["symbol"] == "SIMDTEST", "Wrong token metadata")
check(manifest["token"]["decimals"] == 18, "Wrong decimals")
check(int(manifest["token"]["totalSupply"]) == 10**27, "Wrong supply")
permissions = ["beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"]
check(manifest["hook"]["permissions"] == permissions, "Wrong hook permissions")
check(manifest["hook"]["constructorArgs"] == ["$poolManager", "$token"], "Wrong hook arguments")
check(manifest["token"]["constructorArgs"] == [], "Token must have no constructor arguments")
check(isinstance(manifest["notes"], str) and bool(manifest["notes"]), "Missing notes string")
check(manifest["pool"] == {
    "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
    "fee": 12500,
    "tickSpacing": 60,
    "initialPrice": "79228162514264337593543950336",
}, "Pool differs from task parameters")

for name, argument_types in [("SIMDTEST", []), ("SIMDTESTHook", ["address", "address"])]:
    built = artifact(name)
    constructor = next(item for item in built["abi"] if item["type"] == "constructor")
    check([item["type"] for item in constructor["inputs"]] == argument_types, f"{name}: ABI mismatch")
    creation = bytes.fromhex(built["bytecode"]["object"].removeprefix("0x"))
    runtime = bytes.fromhex(built["deployedBytecode"]["object"].removeprefix("0x"))
    check(len(creation) + 32 * len(argument_types) <= 49152, f"{name}: exceeds EIP-3860")
    check(len(runtime) <= 24576, f"{name}: exceeds EIP-170")
    check(not built["bytecode"].get("linkReferences"), f"{name}: unresolved libraries")
    for pc, opcode in executable_opcodes(runtime):
        check(opcode not in (0xF4, 0xFF), f"{name}: forbidden opcode {opcode:#x} at {pc}")
    metadata = built["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    check(metadata["compiler"]["version"].startswith("0.8.26+"), "Wrong compiler")
    settings = metadata["settings"]
    check(settings["evmVersion"] == "cancun", "Wrong EVM target")
    check(settings["optimizer"] == {"enabled": True, "runs": 200}, "Wrong optimizer settings")
    check(settings["metadata"]["bytecodeHash"] == "none", "Metadata hash must be none")
    print(f"{name}: runtime {len(runtime)} bytes; creation plus arguments {len(creation) + 32 * len(argument_types)} bytes; opcodes OK")

listed = set()
for entry in (ROOT / "DEPENDENCIES.sha256").read_text().splitlines():
    digest, relative = entry.split("  ", 1)
    path = ROOT / relative
    check(path.is_file() and not path.is_symlink(), f"Dependency is not an ordinary file: {relative}")
    check(hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"Dependency changed: {relative}")
    listed.add(relative)
actual = {str(path.relative_to(ROOT)) for path in (ROOT / "lib").rglob("*") if path.is_file()}
check(actual == listed, "Vendored file list differs from DEPENDENCIES.sha256")
print(f"Manifest/ABIs and {len(listed)} vendored files OK")
