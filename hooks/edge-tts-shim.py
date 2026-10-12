"""edge-tts endpoint shim (2026-10-12) — runs the stock edge-tts CLI against the new host.

Microsoft moved Edge Read Aloud from speech.platform.bing.com to api.msedgeservices.com;
since 2026-10-12 the legacy WebSocket handshake answers 403 everywhere (rany2/edge-tts#490).
edge-tts 7.2.8 (latest on PyPI) still points at the legacy host. Swapping the host + path
while keeping the legacy token and Sec-MS-GEC-Version is enough (confirmed in #490).
CLI arguments pass through unchanged; a 403 on the new host retries the legacy one once.

speak.sh routes synthesis through this file whenever it exists.
Retire it: once `pip install -U edge-tts` makes a bare `edge-tts --text hi --write-media x.mp3`
produce audio again, delete this file — speak.sh falls back to the plain edge-tts command.
"""
import sys

from aiohttp import WSServerHandshakeError
import edge_tts.communicate as communicate
import edge_tts.voices as voices
from edge_tts.constants import TRUSTED_CLIENT_TOKEN, WSS_URL as LEGACY_WSS_URL
from edge_tts.util import main

NEW_BASE = "api.msedgeservices.com/tts/cognitiveservices"
# communicate.py / voices.py bind these with `from .constants import ...`,
# so patch the names where they are read, not in constants.
voices.VOICE_LIST = (
    f"https://{NEW_BASE}/voices/list?Ocp-Apim-Subscription-Key={TRUSTED_CLIENT_TOKEN}"
)
WSS_URLS = [
    f"wss://{NEW_BASE}/websocket/v1?Ocp-Apim-Subscription-Key={TRUSTED_CLIENT_TOKEN}",
    LEGACY_WSS_URL,
]

for i, url in enumerate(WSS_URLS):
    communicate.WSS_URL = url
    try:
        main()
        break
    except WSServerHandshakeError as e:
        if e.status != 403 or i == len(WSS_URLS) - 1:
            raise
        print(f"{url.split('?')[0]}: 403, trying next host", file=sys.stderr)
