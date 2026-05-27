#!/usr/bin/env python3
"""
HaberZ Bülten Audio Generator
Two-step pipeline:
  1. GPT-4o-mini writes a professional TV news anchor script (~5 min) from RSS headlines.
  2. OpenAI TTS (onyx voice) converts the script to audio.
Output: audio-output/bulten_morning.mp3 or audio-output/bulten_evening.mp3
"""

import datetime
import json
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
RSS_URL = "https://www.sabah.com.tr/rss/gundem.xml"
OUTPUT_DIR = "audio-output"

_HTML = re.compile(r"<[^>]+>")
_JUNK = re.compile(
    r"(Son Dakika[!:]?|SON DAKİKA[!:]?|Devamın?ı? için tıklayınız\.?|"
    r"Haberin devamı(nı)? için tıklayınız\.?|Devamını oku\.?|"
    r"Haber için tıklayınız\.?|>> ?Tıklayınız\.?|tıklayınız\.?|"
    r"https?://\S+|\[.*?\])",
    re.IGNORECASE,
)
_SPACE = re.compile(r"\s{2,}")


def clean(text: str) -> str:
    text = _HTML.sub(" ", text)
    text = _JUNK.sub(" ", text)
    text = _SPACE.sub(" ", text)
    return text.strip(" .")


def fetch_headlines(url: str) -> list[dict]:
    req = urllib.request.Request(url, headers={"User-Agent": "HaberZ-Bot/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        data = r.read()
    root = ET.fromstring(data)
    items = []
    for item in root.iter("item"):
        title = clean(item.findtext("title", ""))
        desc = clean(item.findtext("description", ""))
        if title:
            items.append({"title": title, "description": desc})
        if len(items) >= 7:  # 7 stories fits comfortably in 5 minutes
            break
    return items


def generate_script(headlines: list[dict], label: str) -> str:
    """Ask GPT-4o-mini to write a professional Turkish TV news anchor script."""

    stories = ""
    for i, h in enumerate(headlines, 1):
        stories += f"{i}. Başlık: {h['title']}\n"
        if h["description"] and len(h["description"]) > 20:
            stories += f"   Detay: {h['description']}\n"
        stories += "\n"

    system_prompt = (
        "Sen deneyimli bir Türk televizyonu haber sunucususun. "
        "Sana verilen haberleri, canlı TV ana haber bülteni gibi sun. "
        "Profesyonel, akıcı ve ilgi çekici bir dil kullan. "
        "Her haberi kısa ve öz tut — dinleyicinin dikkatini kaybetmemesi için. "
        "Haberler arasında 'Öte yandan...', 'Bu arada...', 'Gündemin bir diğer önemli konusu...', "
        "'Ekonomi gündeminden...', 'Siyasi arenada...' gibi doğal geçişler kullan. "
        "Sadece sunucu metnini yaz — başlık, madde işareti veya açıklama ekleme. "
        "Toplam metin 650 kelimeyi geçmemeli (yaklaşık 5 dakika)."
    )

    user_prompt = (
        f"HaberZ {label} Bülteni için aşağıdaki haberleri TV haber sunucusu gibi sun:\n\n"
        f"{stories}"
        f"Bültene 'HaberZ {label} Bülteni'nde hoş geldiniz.' diye başla ve "
        f"'HaberZ ile haberdar kalın, iyi günler.' diye bitir."
    )

    payload = json.dumps({
        "model": "gpt-4o-mini",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": 1200,
        "temperature": 0.7,
    }).encode()

    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        result = json.loads(r.read())

    return result["choices"][0]["message"]["content"].strip()


def call_tts(text: str) -> bytes:
    payload = json.dumps({
        "model": "tts-1-hd",
        "input": text,
        "voice": "onyx",
        "response_format": "mp3",
        "speed": 1.0,
    }).encode()

    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=payload,
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def main() -> None:
    if not OPENAI_API_KEY:
        print("ERROR: OPENAI_API_KEY not set.", file=sys.stderr)
        sys.exit(1)

    istanbul = datetime.timezone(datetime.timedelta(hours=3))
    now = datetime.datetime.now(istanbul)

    label = "Akşam" if now.hour >= 17 else "Sabah"
    filename = "bulten_evening.mp3" if now.hour >= 17 else "bulten_morning.mp3"

    print(f"[{now.strftime('%H:%M')} Istanbul] Generating {label} bulletin → {filename}")

    headlines = fetch_headlines(RSS_URL)
    if not headlines:
        print("ERROR: No headlines fetched.", file=sys.stderr)
        sys.exit(1)
    print(f"Fetched {len(headlines)} headlines.")

    print("Generating news anchor script via GPT-4o-mini...")
    script = generate_script(headlines, label)
    word_count = len(script.split())
    print(f"Script: {word_count} words\n---\n{script[:300]}…\n---")

    print("Converting to speech via OpenAI TTS...")
    audio = call_tts(script)
    print(f"Audio: {len(audio):,} bytes")

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    out = os.path.join(OUTPUT_DIR, filename)
    with open(out, "wb") as f:
        f.write(audio)
    print(f"Saved: {out}")


if __name__ == "__main__":
    main()
