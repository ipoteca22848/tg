"""Telegram demo bot. No real phone numbers, SMS, Stars or TON."""

import argparse
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
import urllib.error
import urllib.request


DISCLAIMER = "DEMO: номера вымышленные; звёзды и TON тестовые. Регистрация Telegram и реальные переводы недоступны."


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, number TEXT, stars TEXT NOT NULL DEFAULT '0', ton TEXT NOT NULL DEFAULT '0')")
        self.db.execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value INTEGER)")
        self.db.commit()

    def ensure(self, user_id):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO users(id) VALUES (?)", (user_id,))

    def user(self, user_id):
        self.ensure(user_id)
        return self.db.execute("SELECT number, stars, ton FROM users WHERE id=?", (user_id,)).fetchone()

    def number(self, user_id, label=None):
        self.ensure(user_id)
        existing = self.user(user_id)[0]
        if label is None and existing:
            return existing
        label = label if label is not None else self.generate_number("+7")
        if not label.strip() or len(label) > 80 or any(ord(c) < 32 for c in label):
            raise ValueError("Название номера: от 1 до 80 символов без переносов строк.")
        label = "DEMO:" + label.strip().removeprefix("DEMO:")
        with self.db:
            self.db.execute("UPDATE users SET number=? WHERE id=?", (label, user_id))
        return label

    @staticmethod
    def generate_number(prefix):
        if not re.fullmatch(r"\+[1-9][0-9]{0,2}", prefix):
            raise ValueError("Префикс: + и от 1 до 3 цифр, например +7, +888, +44.")
        length = 10 if prefix in ("+7", "+1") else 8 if prefix == "+888" else 9
        return prefix + "".join(str(secrets.randbelow(10)) for _ in range(length))

    def grant(self, user_id, currency, amount):
        if currency not in ("stars", "ton"):
            raise ValueError("Валюта: stars или ton.")
        if amount.lower() in ("infinite", "inf", "∞"):
            value = "infinite"
        else:
            if len(amount) > 40:
                raise ValueError("Слишком длинное значение.")
            try:
                number = Decimal(amount)
            except InvalidOperation:
                raise ValueError("Нужно число или infinite.") from None
            if not number.is_finite() or number < 0 or number > Decimal("1e24"):
                raise ValueError("Баланс: от 0 до 10^24 или infinite.")
            if currency == "stars" and number != number.to_integral_value():
                raise ValueError("Звёзды задаются целым числом.")
            if not -9 <= number.as_tuple().exponent <= 24:
                raise ValueError("Недопустимая точность или показатель степени.")
            value = format(number, "f")
        self.ensure(user_id)
        with self.db:
            self.db.execute(f"UPDATE users SET {currency}=? WHERE id=?", (value, user_id))

    def offset(self, value=None):
        if value is not None:
            with self.db:
                self.db.execute("INSERT OR REPLACE INTO state VALUES ('offset', ?)", (value,))
        row = self.db.execute("SELECT value FROM state WHERE key='offset'").fetchone()
        return row[0] if row else 0


class Bot:
    def __init__(self, store, admin_id):
        if admin_id <= 0:
            raise ValueError("DEMO_ADMIN_ID должен быть положительным Telegram ID.")
        self.store = store
        self.admin_id = admin_id
        self.store.grant(admin_id, "stars", "infinite")
        self.store.grant(admin_id, "ton", "infinite")

    def reply(self, message):
        user = message.get("from", {})
        user_id = user.get("id")
        if not isinstance(user_id, int) or user.get("is_bot"):
            return None
        if message.get("chat", {}).get("type") != "private":
            return "Работаю только в личном чате. " + DISCLAIMER
        text = message.get("text", "")
        parts = text.strip().split()
        command = parts[0].split("@")[0].lower() if parts else ""
        admin = user_id == self.admin_id
        self.store.ensure(user_id)
        try:
            if command in ("/start", "/help"):
                result = "/number — текущий демономер\n/number +7 — новый с префиксом\n/prefixes — варианты префиксов\n/balance — тестовый баланс\n/id — ваш Telegram ID"
                if admin:
                    result += "\n/admin — команды администратора"
            elif command == "/id":
                result = f"Ваш Telegram ID: {user_id}"
            elif command == "/number":
                if len(parts) > 2:
                    raise ValueError("Формат: /number или /number +888")
                result = self.store.number(user_id, self.store.generate_number(parts[1])) if len(parts) == 2 else self.store.number(user_id)
            elif command == "/prefixes":
                result = "Примеры: +7, +888, +1, +44, +49, +33, +90, +91, +971.\nПоддерживается любая цифровая метка префикса из 1–3 цифр: /number +код. Это не проверка существования кода страны или валидности телефонного номера."
            elif command == "/balance":
                _, stars, ton = self.store.user(user_id)
                show = lambda value: "∞" if value == "infinite" else value
                result = f"Тестовые звёзды: {show(stars)}\nТестовые TON: {show(ton)}"
            elif command in ("/admin", "/setnumber", "/grant", "/users"):
                if not admin:
                    result = "Нужны права администратора. Username не предоставляет прав."
                elif command == "/admin":
                    result = "/setnumber <user_id> <любая метка>\n/grant <user_id> <stars|ton> <число|infinite>\n/users — последние 20 участников"
                elif command == "/users":
                    rows = self.store.db.execute("SELECT id, number FROM users ORDER BY id DESC LIMIT 20").fetchall()
                    result = "\n".join(f"{uid}: {label or 'нет демономера'}" for uid, label in rows)
                else:
                    if len(parts) < 3 or not parts[1].isdigit() or int(parts[1]) <= 0:
                        raise ValueError("Укажите положительный user_id и параметры. Справка: /admin")
                    target = int(parts[1])
                    if target > 2**52:
                        raise ValueError("Некорректный Telegram ID.")
                    if command == "/setnumber":
                        result = self.store.number(target, text.strip().split(maxsplit=2)[2])
                    else:
                        if len(parts) != 4:
                            raise ValueError("Формат: /grant user_id stars|ton число|infinite")
                        self.store.grant(target, parts[2].lower(), parts[3])
                        result = "Тестовый баланс обновлён."
            else:
                result = "Неизвестная команда. Справка: /help"
        except ValueError as error:
            result = str(error)
        return result + "\n\n" + DISCLAIMER


class Telegram:
    def __init__(self, token):
        self.url = "https://api.telegram.org/bot" + token + "/"

    def call(self, method, data):
        request = urllib.request.Request(
            self.url + method, data=json.dumps(data).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Telegram HTTP {error.code}; проверьте токен и доступ.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise RuntimeError("Telegram недоступен; проверьте сеть.") from None
        if not payload.get("ok"):
            raise RuntimeError("Telegram отклонил запрос.")
        return payload["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", default=str(Path(__file__).with_name("demo.sqlite3")))
    args = parser.parse_args()
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    admin_id = os.environ.get("DEMO_ADMIN_ID", "")
    if not token or not admin_id.isdigit() or int(admin_id) <= 0:
        parser.error("Нужны TELEGRAM_BOT_TOKEN и положительный DEMO_ADMIN_ID в окружении.")
    store = Store(args.database)
    bot = Bot(store, int(admin_id))
    telegram = Telegram(token)
    try:
        telegram.call("getMe", {})
        if telegram.call("getWebhookInfo", {}).get("url"):
            parser.error("У бота настроен webhook. Удалите его отдельно или используйте другого бота.")
    except RuntimeError as error:
        parser.error(str(error))
    print("DEMO bot polling started. No real numbers or funds.", flush=True)
    while True:
        try:
            updates = telegram.call("getUpdates", {
                "offset": store.offset(), "timeout": 25, "allowed_updates": ["message"]})
            for update in updates:
                message = update.get("message")
                if message:
                    result = bot.reply(message)
                    if result:
                        try:
                            telegram.call("sendMessage", {
                                "chat_id": message["chat"]["id"], "text": result})
                        except RuntimeError:
                            print("Could not deliver reply; update acknowledged.", flush=True)
                store.offset(update["update_id"] + 1)
        except RuntimeError as error:
            print(str(error), flush=True)
            time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
