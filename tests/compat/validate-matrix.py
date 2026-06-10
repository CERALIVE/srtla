#!/usr/bin/env python3
"""
Validator for SRTLA Compatibility Matrix Registry (matrix.yaml).

Checks:
- All pins are 40-character hexadecimal strings
- All pairs reference valid sender/receiver names
- All required fields are present in entries
- Blocking tier contains exactly 6 pairs
"""

import sys
import re
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def validate_pin(pin, context=""):
    """Validate that a pin is a 40-character hexadecimal string."""
    if not isinstance(pin, str):
        return False, f"{context}: pin is not a string (got {type(pin).__name__})"
    if len(pin) != 40:
        return False, f"{context}: pin length is {len(pin)}, expected 40"
    if not re.match(r"^[0-9a-f]{40}$", pin):
        return False, f"{context}: pin is not valid hex (got '{pin}')"
    return True, None


def validate_matrix(matrix_path):
    """Validate the compatibility matrix YAML file."""
    errors = []
    warnings = []

    # Load YAML
    try:
        with open(matrix_path, "r") as f:
            matrix = yaml.safe_load(f)
    except Exception as e:
        print(f"ERROR: Failed to load {matrix_path}: {e}", file=sys.stderr)
        return False

    if not isinstance(matrix, dict):
        print("ERROR: matrix.yaml root must be a dictionary", file=sys.stderr)
        return False

    # Extract sections
    senders = matrix.get("senders", [])
    receivers = matrix.get("receivers", [])
    pairs = matrix.get("pairs", [])
    excluded = matrix.get("excluded", [])

    # Build name sets
    sender_names = set()
    receiver_names = set()

    # Validate senders
    if not isinstance(senders, list):
        errors.append("senders must be a list")
    else:
        for i, sender in enumerate(senders):
            if not isinstance(sender, dict):
                errors.append(f"senders[{i}]: entry must be a dict")
                continue

            name = sender.get("name")
            if not name:
                errors.append(f"senders[{i}]: missing 'name' field")
                continue

            sender_names.add(name)

            # Validate required fields
            for field in ["repo", "pin", "role", "tier"]:
                if field not in sender:
                    errors.append(f"senders[{i}] ({name}): missing '{field}' field")

            # Validate pin
            pin = sender.get("pin")
            if pin:
                valid, msg = validate_pin(pin, f"senders[{i}] ({name})")
                if not valid:
                    errors.append(msg)

            # Validate role
            role = sender.get("role")
            if role and role != "sender":
                errors.append(f"senders[{i}] ({name}): role must be 'sender', got '{role}'")

            # Validate tier
            tier = sender.get("tier")
            if tier and tier not in ["blocking", "informational"]:
                errors.append(f"senders[{i}] ({name}): tier must be 'blocking' or 'informational', got '{tier}'")

    # Validate receivers
    if not isinstance(receivers, list):
        errors.append("receivers must be a list")
    else:
        for i, receiver in enumerate(receivers):
            if not isinstance(receiver, dict):
                errors.append(f"receivers[{i}]: entry must be a dict")
                continue

            name = receiver.get("name")
            if not name:
                errors.append(f"receivers[{i}]: missing 'name' field")
                continue

            receiver_names.add(name)

            # Validate required fields
            for field in ["repo", "pin", "role", "tier"]:
                if field not in receiver:
                    errors.append(f"receivers[{i}] ({name}): missing '{field}' field")

            # Validate pin
            pin = receiver.get("pin")
            if pin:
                valid, msg = validate_pin(pin, f"receivers[{i}] ({name})")
                if not valid:
                    errors.append(msg)

            # Validate role
            role = receiver.get("role")
            if role and role != "receiver":
                errors.append(f"receivers[{i}] ({name}): role must be 'receiver', got '{role}'")

            # Validate tier
            tier = receiver.get("tier")
            if tier and tier not in ["blocking", "informational"]:
                errors.append(f"receivers[{i}] ({name}): tier must be 'blocking' or 'informational', got '{tier}'")

    # Validate pairs
    blocking_pairs = []
    informational_pairs = []

    if not isinstance(pairs, list):
        errors.append("pairs must be a list")
    else:
        for i, pair in enumerate(pairs):
            if not isinstance(pair, dict):
                errors.append(f"pairs[{i}]: entry must be a dict")
                continue

            sender = pair.get("sender")
            receiver = pair.get("receiver")
            tier = pair.get("tier")

            if not sender:
                errors.append(f"pairs[{i}]: missing 'sender' field")
            elif sender != "ours" and sender not in sender_names:
                errors.append(f"pairs[{i}]: sender '{sender}' not found in senders list")

            if not receiver:
                errors.append(f"pairs[{i}]: missing 'receiver' field")
            elif receiver != "ours" and receiver not in receiver_names:
                errors.append(f"pairs[{i}]: receiver '{receiver}' not found in receivers list")

            if not tier:
                errors.append(f"pairs[{i}]: missing 'tier' field")
            elif tier not in ["blocking", "informational"]:
                errors.append(f"pairs[{i}]: tier must be 'blocking' or 'informational', got '{tier}'")
            else:
                if tier == "blocking":
                    blocking_pairs.append(pair)
                else:
                    informational_pairs.append(pair)

    # Validate blocking tier count
    if len(blocking_pairs) != 6:
        errors.append(f"blocking tier must have exactly 6 pairs, got {len(blocking_pairs)}")

    # Validate excluded
    if not isinstance(excluded, list):
        errors.append("excluded must be a list")
    else:
        for i, entry in enumerate(excluded):
            if not isinstance(entry, dict):
                errors.append(f"excluded[{i}]: entry must be a dict")
                continue

            name = entry.get("name")
            if not name:
                errors.append(f"excluded[{i}]: missing 'name' field")

            if "repo" not in entry:
                errors.append(f"excluded[{i}] ({name}): missing 'repo' field")

            if "reason" not in entry:
                errors.append(f"excluded[{i}] ({name}): missing 'reason' field")

    # Print results
    if errors:
        print("VALIDATION FAILED", file=sys.stderr)
        print(f"\nErrors ({len(errors)}):", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return False

    if warnings:
        print(f"Warnings ({len(warnings)}):", file=sys.stderr)
        for warning in warnings:
            print(f"  - {warning}", file=sys.stderr)

    print("VALIDATION PASSED", file=sys.stdout)
    print(f"  Senders: {len(senders)}", file=sys.stdout)
    print(f"  Receivers: {len(receivers)}", file=sys.stdout)
    print(f"  Pairs: {len(pairs)} (blocking: {len(blocking_pairs)}, informational: {len(informational_pairs)})", file=sys.stdout)
    print(f"  Excluded: {len(excluded)}", file=sys.stdout)
    return True


if __name__ == "__main__":
    script_dir = Path(__file__).parent
    matrix_path = script_dir / "matrix.yaml"

    if not matrix_path.exists():
        print(f"ERROR: {matrix_path} not found", file=sys.stderr)
        sys.exit(1)

    success = validate_matrix(matrix_path)
    sys.exit(0 if success else 1)
