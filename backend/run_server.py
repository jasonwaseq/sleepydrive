from __future__ import annotations

import asyncio
import os
import sys

import uvicorn


def main() -> None:
    host = os.getenv("APP_HOST", "0.0.0.0")
    try:
        port = int(os.getenv("APP_PORT", "8080"))
    except ValueError:
        port = 8080

    config = uvicorn.Config("app:app", host=host, port=port, loop="asyncio")
    server = uvicorn.Server(config)

    if sys.platform.startswith("win"):
        # aiomqtt requires add_reader/add_writer, which are unavailable on Proactor.
        loop = asyncio.SelectorEventLoop()
        asyncio.set_event_loop(loop)
        loop.run_until_complete(server.serve())
        return

    uvicorn.run("app:app", host=host, port=port, loop="asyncio")


if __name__ == "__main__":
    main()
