"""Canonical and bounded FSRS scheduler snapshots shared by sync and scheduling."""
import json

def normalize_fsrs_config(config):
    """跨 JSON 编码器规范化数值，限制外来备份的形状和资源消耗。"""
    import math
    if not isinstance(config, dict) or set(config) != {"library", "parameters", "desired_retention", "learning_steps", "relearning_steps", "maximum_interval"}:
        raise ValueError("invalid scheduler config")
    def number(value, low, high):
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError("invalid scheduler value")
        return float(value)
    def numbers(values, limit, low, high):
        if not isinstance(values, (list, tuple)) or len(values) > limit:
            raise ValueError("invalid scheduler list")
        return [number(v, low, high) for v in values]
    library = config["library"]
    if not isinstance(library, str) or not 1 <= len(library) <= 64:
        raise ValueError("invalid FSRS library version")
    maximum = number(config["maximum_interval"], 1, 1000000)
    if not maximum.is_integer():
        raise ValueError("invalid maximum interval")
    return {"library": library, "parameters": numbers(config["parameters"], 32, -1000000, 1000000),
            "desired_retention": number(config["desired_retention"], 0.01, 0.9999),
            "learning_steps": numbers(config["learning_steps"], 32, 0, 31536000),
            "relearning_steps": numbers(config["relearning_steps"], 32, 0, 31536000),
            "maximum_interval": int(maximum)}



def fsrs_config_key(config):
    import hashlib
    return hashlib.sha256(json.dumps(normalize_fsrs_config(config), sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()
