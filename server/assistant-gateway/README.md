# Legacy assistant gateway

This Python gateway is retained as an earlier integration experiment. The current product direction is local, offline assistance; deployment of this gateway is not required for that workflow. Its presence does not mean Xiaozhi or cloud AI is part of the intended AreoEase experience.

## Modes

| Mode | Behavior |
|---|---|
| `mock` | Exercises the gateway contract without a model service |
| `xiaozhi` | Connects to a configured self-hosted Xiaozhi WebSocket service |
| `llm` | Calls a configured OpenAI-compatible model endpoint |

The app also retains legacy direct-provider code. Removing cloud access from the product requires removing or disabling those app paths, not merely leaving this gateway stopped.

## Local development

From this directory, create a Python environment and install dependencies:

```sh
python -m venv .venv
python -m pip install -r requirements.txt
python -m unittest discover -s tests
python gateway.py
```

Activate the environment before installing or running. Review `config.example.env` and set the desired values in the shell; the server does not automatically load that file. The default host is `127.0.0.1`, port `8787`, and mode `mock`. A health response does not prove an upstream connection works.

## Configuration reference

- `GATEWAY_HOST`, `GATEWAY_PORT`, and `GATEWAY_MODE` select the listener and mode.
- `GATEWAY_TOKEN` protects gateway access and is required when listening beyond loopback.
- `XIAOZHI_WS_URL`, `XIAOZHI_DEVICE_ID`, `XIAOZHI_CLIENT_ID`, `XIAOZHI_TOKEN`, and `XIAOZHI_TIMEOUT_SECONDS` configure the historical WebSocket integration.
- `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL` configure the model API. The base URL excludes `/chat/completions`; non-loopback model endpoints require HTTPS.

Keep credentials outside source control and APKs. Model requests leave the local machine when a remote upstream is configured. Do not treat mock tests as evidence of production connectivity, privacy guarantees, or upstream user isolation.

See [knowledge notes](knowledge/README.md) and the [Android app](../../mobile_app/README.md). Historical integration documents are retained for maintenance, not as deployment instructions for the offline product.
