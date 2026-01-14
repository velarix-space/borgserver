#!/usr/bin/env python3
"""
Borg Prune Configuration Parser
Parses and validates YAML configuration for borg prune operations.
"""

import sys
import re
import yaml
import json
from pathlib import Path
from typing import Dict, Any, Optional


# Schema definition for prune configuration
SCHEMA = {
    "keep_daily": {"type": "int", "min": -1, "default": 7},
    "keep_weekly": {"type": "int", "min": -1, "default": 4},
    "keep_monthly": {"type": "int", "min": -1, "default": -1},
    "keep_yearly": {"type": "int", "min": -1, "default": -1},
    "keep_within": {"type": "str", "pattern": r"^[0-9]+[dwmy]$", "optional": True},
    "enabled": {"type": "bool", "default": True},
}


class ConfigError(Exception):
    """Configuration validation error"""
    pass


def validate_value(key: str, value: Any, schema_def: Dict[str, Any]) -> Any:
    """Validate a configuration value against its schema definition"""
    # Handle None/missing values
    if value is None:
        if schema_def.get("optional", False):
            return None
        if "default" in schema_def:
            return schema_def["default"]
        raise ConfigError(f"Required field '{key}' is missing")
    
    # Type validation
    if schema_def["type"] == "int":
        if not isinstance(value, int):
            raise ConfigError(f"Field '{key}' must be an integer, got {type(value).__name__}")
        if "min" in schema_def and value < schema_def["min"]:
            raise ConfigError(f"Field '{key}' must be >= {schema_def['min']}, got {value}")
    
    elif schema_def["type"] == "bool":
        if not isinstance(value, bool):
            raise ConfigError(f"Field '{key}' must be a boolean, got {type(value).__name__}")
    
    elif schema_def["type"] == "str":
        if not isinstance(value, str):
            raise ConfigError(f"Field '{key}' must be a string, got {type(value).__name__}")
        if "pattern" in schema_def:
            if not re.match(schema_def["pattern"], value):
                raise ConfigError(f"Field '{key}' has invalid format: {value}")
    
    return value


def validate_client_config(client_name: str, config: Dict[str, Any]) -> Dict[str, Any]:
    """Validate a client's configuration against the schema"""
    validated = {}
    
    for key, schema_def in SCHEMA.items():
        try:
            validated[key] = validate_value(key, config.get(key), schema_def)
        except ConfigError as e:
            raise ConfigError(f"Client '{client_name}': {e}")
    
    return validated


def load_config(config_path: str) -> Dict[str, Dict[str, Any]]:
    """
    Load and validate the prune configuration file.
    Returns a dict with client names as keys and their validated configs as values.
    """
    path = Path(config_path)
    
    if not path.exists():
        raise ConfigError(f"Configuration file not found: {config_path}")
    
    if not path.is_file():
        raise ConfigError(f"Configuration path is not a file: {config_path}")
    
    try:
        with open(path, 'r') as f:
            raw_config = yaml.safe_load(f)
    except yaml.YAMLError as e:
        raise ConfigError(f"Failed to parse YAML: {e}")
    except Exception as e:
        raise ConfigError(f"Failed to read config file: {e}")
    
    if not isinstance(raw_config, dict):
        raise ConfigError("Configuration must be a YAML mapping/dict")
    
    # Validate each client section
    validated_config = {}
    for client_name, client_config in raw_config.items():
        if not isinstance(client_config, dict):
            raise ConfigError(f"Client '{client_name}' config must be a mapping/dict")
        validated_config[client_name] = validate_client_config(client_name, client_config)
    
    # Ensure 'default' section exists
    if "default" not in validated_config:
        raise ConfigError("Configuration must contain a 'default' section")
    
    return validated_config


def get_client_config(config: Dict[str, Dict[str, Any]], client_name: str) -> Dict[str, Any]:
    """
    Get configuration for a specific client, falling back to defaults.
    """
    # Start with default config
    result = config["default"].copy()
    
    # Override with client-specific config if it exists
    if client_name in config and client_name != "default":
        result.update(config[client_name])
    
    return result


def main():
    """Command-line interface for the config parser"""
    if len(sys.argv) < 2:
        print("Usage: prune_config.py <command> [args]", file=sys.stderr)
        print("Commands:", file=sys.stderr)
        print("  validate <config_file>       - Validate configuration file", file=sys.stderr)
        print("  get <config_file> <client>   - Get config for a specific client", file=sys.stderr)
        print("  cache <config_file>          - Load and cache configuration (JSON output)", file=sys.stderr)
        sys.exit(1)
    
    command = sys.argv[1]
    
    try:
        if command == "validate":
            if len(sys.argv) < 3:
                print("Error: Missing config file path", file=sys.stderr)
                sys.exit(1)
            config = load_config(sys.argv[2])
            print(f"Configuration is valid. Found {len(config)} client(s).")
            sys.exit(0)
        
        elif command == "get":
            if len(sys.argv) < 4:
                print("Error: Missing config file path or client name", file=sys.stderr)
                sys.exit(1)
            config = load_config(sys.argv[2])
            client_name = sys.argv[3]
            client_config = get_client_config(config, client_name)
            print(json.dumps(client_config))
            sys.exit(0)
        
        elif command == "cache":
            if len(sys.argv) < 3:
                print("Error: Missing config file path", file=sys.stderr)
                sys.exit(1)
            config = load_config(sys.argv[2])
            print(json.dumps(config))
            sys.exit(0)
        
        else:
            print(f"Error: Unknown command '{command}'", file=sys.stderr)
            sys.exit(1)
    
    except ConfigError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
