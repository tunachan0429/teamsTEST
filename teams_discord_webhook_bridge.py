"""
=====================================================================
Teams ↔ Discord ウェブフック ブリッジ Bot（管理者同意不要版）
=====================================================================

【できること】
  1. Teamsの指定チャンネルに新着メッセージ → Discordに転送
     （Power Automate を使って管理者なしで設定可能）
  2. Discordから /send コマンドで Teamsにメッセージ送信
     （Teams の「受信ウェブフック」を使用）

【必要なもの】
  - Discordボットトークン
  - Discordウェブフック or ボット通知チャンネルID
  - Teams受信ウェブフックURL（チャンネル設定から作成）
  - Power Automate フロー（Teams→Discord転送用）

【インストール】
  pip install discord.py aiohttp

【起動】
  python teams_discord_webhook_bridge.py

=====================================================================
# セットアップ手順

## A. Discord → Teams（欠席連絡など）の設定

1. Teamsで送りたいチャンネルを開く
2. チャンネル名横の「…」→「チャンネルの管理」→「コネクタ」を探す
   ※ 新しいTeamsでは「ワークフロー」→「チームへの投稿」を使う
3. 「受信ウェブフック」を追加 → URLをコピー
4. CONFIG の TEAMS_INCOMING_WEBHOOK_URL に貼り付け

## B. Teams → Discord（先生からの通知）の設定

Power Automateを使います（学校アカウントでも使える場合が多い）：

1. https://make.powerautomate.com にTeamsアカウントでログイン
2. 「新しいフロー」→「自動化されたクラウドフロー」
3. トリガー：「Microsoft Teams - チャネルで新しいメッセージが投稿されたとき」
   → チームとチャンネルを選択
4. アクション：「HTTP - HTTPを呼び出す」
   - 方法: POST
   - URI: http://あなたのサーバーIP:8080/teams
   - ヘッダー: Content-Type: application/json
   - 本文:
     {
       "sender": "@{triggerOutputs()?['body/from/user/displayName']}",
       "message": "@{triggerOutputs()?['body/body/content']}",
       "timestamp": "@{triggerOutputs()?['body/createdDateTime']}"
     }

   ※ サーバーをngrokなどで外部公開する必要があります
   ※ ngrokは無料: https://ngrok.com/  起動後 ngrok http 8080 でURLが発行されます

=====================================================================
"""

import discord
from discord import app_commands
from discord.ext import commands
import aiohttp
from aiohttp import web
import asyncio
import json
import logging
import os
import re
from datetime import datetime, timezone

# ─────────────────────────────────────────────
# ログ設定
# ─────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("bridge.log", encoding="utf-8"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────
# ★ ここを自分の環境に合わせて変更してください ★
# ─────────────────────────────────────────────
CONFIG = {
    # ── Discord設定 ──────────────────────────────
    # Discordボットトークン
    # https://discord.com/developers/applications で取得
    "DISCORD_BOT_TOKEN": os.getenv("DISCORD_BOT_TOKEN", "ここにDiscordボットトークン"),

    # Teams通知を転送するDiscordチャンネルのID
    # （DiscordでチャンネルIDを右クリック→「IDをコピー」）
    "DISCORD_NOTIFY_CHANNEL_ID": int(os.getenv("DISCORD_NOTIFY_CHANNEL_ID", "0")),

    # ── Teams設定 ────────────────────────────────
    # Teams受信ウェブフックURL（チャンネルの「コネクタ」または「ワークフロー」から取得）
    # これはDiscord → Teams 送信に使う
    "TEAMS_INCOMING_WEBHOOK_URL": os.getenv(
        "TEAMS_INCOMING_WEBHOOK_URL",
        "ここにTeams受信ウェブフックURL"
    ),

    # ── サーバー設定 ─────────────────────────────
    # Railwayは PORT を自動設定するのでそちらを優先。ローカルは8080
    "WEBHOOK_SERVER_PORT": int(os.getenv("PORT", os.getenv("WEBHOOK_SERVER_PORT", "8080"))),

    # Power Automateからのリクエスト認証トークン（任意の文字列でOK）
    # Power Automate側のHTTPヘッダーに X-Auth-Token: ここの値 を設定してください
    "WEBHOOK_SECRET": os.getenv("WEBHOOK_SECRET", "secret-token-change-me"),
}


# ─────────────────────────────────────────────
# Teams への送信（受信ウェブフック使用）
# ─────────────────────────────────────────────
async def send_to_teams(message: str, sender_name: str) -> bool:
    """
    Teams受信ウェブフックにメッセージを送信する。
    Adaptive Card形式（新形式）と MessageCard形式（旧形式）の両方に対応。
    """
    webhook_url = CONFIG["TEAMS_INCOMING_WEBHOOK_URL"]
    if not webhook_url or webhook_url.startswith("ここに"):
        logger.error("Teams受信ウェブフックURLが設定されていません")
        return False

    # MessageCard形式（多くの環境で動作する）
    payload = {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": "0076D7",
        "summary": f"{sender_name}からのメッセージ",
        "sections": [
            {
                "activityTitle": f"📨 Discordより: **{sender_name}**",
                "activitySubtitle": datetime.now(timezone.utc).strftime("%Y/%m/%d %H:%M"),
                "activityText": message,
                "markdown": True
            }
        ]
    }

    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                webhook_url,
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=aiohttp.ClientTimeout(total=10)
            ) as resp:
                if resp.status in (200, 202):
                    logger.info(f"Teams送信成功: {sender_name} → {message[:50]}")
                    return True
                else:
                    body = await resp.text()
                    logger.error(f"Teams送信失敗 ({resp.status}): {body}")
                    return False
    except aiohttp.ClientError as e:
        logger.error(f"Teams送信ネットワークエラー: {e}")
        return False
    except asyncio.TimeoutError:
        logger.error("Teams送信タイムアウト")
        return False


# ─────────────────────────────────────────────
# Discord Bot
# ─────────────────────────────────────────────
intents = discord.Intents.default()
intents.message_content = True

bot = commands.Bot(command_prefix="!", intents=intents)


@bot.event
async def on_ready():
    await bot.tree.sync()
    logger.info(f"ボット起動完了: {bot.user} (ID: {bot.user.id})")
    logger.info("スラッシュコマンドを同期しました")


# ── スラッシュコマンド ─────────────────────────

@bot.tree.command(name="send", description="Teamsの指定チャンネルにメッセージを送ります（欠席連絡など）")
@app_commands.describe(message="送信するメッセージ（例：明日の朝練を欠席します）")
async def slash_send(interaction: discord.Interaction, message: str):
    """自分の名前でTeamsにメッセージを送信する"""
    await interaction.response.defer()

    sender = interaction.user.display_name
    success = await send_to_teams(message, sender)

    if success:
        embed = discord.Embed(
            title="✅ Teamsに送信しました",
            color=discord.Color.green(),
            timestamp=datetime.now(timezone.utc)
        )
        embed.add_field(name="送信者（Discord名）", value=sender, inline=True)
        embed.add_field(name="メッセージ", value=message, inline=False)
        await interaction.followup.send(embed=embed)
    else:
        await interaction.followup.send(
            "❌ 送信に失敗しました。\n"
            "Teams受信ウェブフックURLが正しく設定されているか確認してください。"
        )


@bot.tree.command(name="send_as", description="Teamsに送るとき、表示名を自分で指定して送ります")
@app_commands.describe(
    name="Teamsに表示する名前（例：山田太郎）",
    message="送信するメッセージ"
)
async def slash_send_as(interaction: discord.Interaction, name: str, message: str):
    """表示名を指定してTeamsにメッセージを送信する"""
    await interaction.response.defer()

    success = await send_to_teams(message, name)

    if success:
        embed = discord.Embed(
            title="✅ Teamsに送信しました",
            color=discord.Color.green(),
            timestamp=datetime.now(timezone.utc)
        )
        embed.add_field(name="表示名（Teams側）", value=name, inline=True)
        embed.add_field(name="送信者（Discord）", value=interaction.user.display_name, inline=True)
        embed.add_field(name="メッセージ", value=message, inline=False)
        await interaction.followup.send(embed=embed)
    else:
        await interaction.followup.send(
            "❌ 送信に失敗しました。\n"
            "設定を確認してください。"
        )


@bot.tree.command(name="help_teams", description="このボットの使い方を表示します")
async def slash_help(interaction: discord.Interaction):
    embed = discord.Embed(
        title="📖 Teams↔Discord ウェブフックブリッジ 使い方",
        color=discord.Color.blurple()
    )
    embed.add_field(
        name="📤 Discordから Teamsへ送信",
        value=(
            "`/send [メッセージ]`\n"
            "　→ 自分のDiscord表示名でTeamsに送信\n\n"
            "`/send_as [名前] [メッセージ]`\n"
            "　→ 指定した名前でTeamsに送信（欠席者の代理連絡などに）"
        ),
        inline=False
    )
    embed.add_field(
        name="📩 TeamsからDiscordへ（自動転送）",
        value=(
            "Power Automateのフローを設定すると\n"
            "Teamsの新着メッセージが自動でこのチャンネルに届きます。\n"
            "（詳細はファイル冒頭のコメントを参照）"
        ),
        inline=False
    )
    embed.add_field(
        name="使用例",
        value=(
            "`/send 明日の朝練を欠席します。`\n"
            "`/send_as 田中花子 体調不良のため本日欠席します。`"
        ),
        inline=False
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


# ─────────────────────────────────────────────
# Power AutomateからのWebhook受信サーバー
# （Teams → Discord 転送用）
# ─────────────────────────────────────────────
async def handle_teams_webhook(request: web.Request) -> web.Response:
    """
    Power Automateから送られてきたTeamsメッセージを受け取り、
    Discordチャンネルに転送する
    """
    # 簡易認証（X-Auth-Tokenヘッダーで確認）
    auth_token = request.headers.get("X-Auth-Token", "")
    if auth_token != CONFIG["WEBHOOK_SECRET"]:
        logger.warning(f"不正なウェブフックリクエスト（トークン不一致）: {request.remote}")
        return web.Response(status=401, text="Unauthorized")

    try:
        data = await request.json()
    except json.JSONDecodeError:
        return web.Response(status=400, text="Invalid JSON")

    sender = data.get("sender", "不明")
    message = data.get("message", "")
    timestamp = data.get("timestamp", "")

    # HTMLタグを除去（TeamsはHTMLで送ってくることがある）
    message_clean = re.sub(r"<[^>]+>", "", message).strip()

    if not message_clean:
        return web.Response(status=200, text="OK (empty message ignored)")

    logger.info(f"Teams → Discord: {sender}: {message_clean[:60]}")

    # Discordに転送
    channel = bot.get_channel(CONFIG["DISCORD_NOTIFY_CHANNEL_ID"])
    if channel:
        try:
            ts_display = ""
            if timestamp:
                try:
                    dt = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
                    ts_display = dt.strftime("%Y/%m/%d %H:%M")
                except ValueError:
                    ts_display = timestamp

            embed = discord.Embed(
                title="📩 Teamsに新着メッセージ",
                description=message_clean,
                color=discord.Color.blue(),
            )
            embed.set_footer(text=f"送信者: {sender}　|　{ts_display}")
            await channel.send(embed=embed)
        except discord.HTTPException as e:
            logger.error(f"Discord送信エラー: {e}")
            return web.Response(status=500, text="Discord send failed")
    else:
        logger.error(f"通知チャンネルが見つかりません (ID: {CONFIG['DISCORD_NOTIFY_CHANNEL_ID']})")

    return web.Response(status=200, text="OK")


async def handle_healthcheck(request: web.Request) -> web.Response:
    """サーバーが動いているか確認用エンドポイント"""
    return web.Response(
        text=json.dumps({"status": "ok", "bot": str(bot.user)}),
        content_type="application/json"
    )


async def start_webhook_server():
    """aiohttp Webサーバーを起動する"""
    app = web.Application()
    app.router.add_post("/teams", handle_teams_webhook)
    app.router.add_get("/health", handle_healthcheck)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", CONFIG["WEBHOOK_SERVER_PORT"])
    await site.start()
    logger.info(f"ウェブフック受信サーバー起動: ポート {CONFIG['WEBHOOK_SERVER_PORT']}")
    logger.info(f"  受信URL: http://0.0.0.0:{CONFIG['WEBHOOK_SERVER_PORT']}/teams")
    logger.info(f"  ヘルスチェック: http://0.0.0.0:{CONFIG['WEBHOOK_SERVER_PORT']}/health")


# ─────────────────────────────────────────────
# メイン起動（BotとWebサーバーを同時起動）
# ─────────────────────────────────────────────
async def main():
    token = CONFIG["DISCORD_BOT_TOKEN"]
    if token.startswith("ここに"):
        print("=" * 60)
        print("⚠️  設定が必要です！")
        print("   CONFIG の各項目を設定してください。")
        print("   または環境変数で設定できます：")
        print("     DISCORD_BOT_TOKEN")
        print("     DISCORD_NOTIFY_CHANNEL_ID")
        print("     TEAMS_INCOMING_WEBHOOK_URL")
        print("     WEBHOOK_SERVER_PORT  （デフォルト: 8080）")
        print("     WEBHOOK_SECRET       （デフォルト: secret-token-change-me）")
        print("=" * 60)
        return

    # ウェブフックサーバーとDiscordボットを並行起動
    await start_webhook_server()
    await bot.start(token)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("ボットを停止しました")
