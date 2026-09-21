# Telegram command handler -> "last 5 uploads" lookup.
#
# Polls Telegram's getUpdates for new messages sent to the bot (free, no
# webhook/server needed). If the message text matches one of the tracked
# channel names (exact or partial, case-insensitive), replies with that
# channel's last 5 uploads in the same thumbnail+link format as notifier.ps1.
#
# Only messages from TELEGRAM_CHAT_ID are processed, so strangers who find
# the bot can't use it to spam requests through your GitHub Actions minutes.
#
# "Last processed update" is persisted in telegram_offset.json, which the
# workflow commits back to the repo after each run.

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ChannelsPath = Join-Path $ScriptDir "channels.json"
$OffsetPath = Join-Path $ScriptDir "telegram_offset.json"

. (Join-Path $ScriptDir "Common.ps1")

if (-not (Test-Path $ChannelsPath)) {
    Write-Error "Missing channels file: $ChannelsPath"
    exit 1
}
$channels = Get-Content $ChannelsPath -Raw | ConvertFrom-Json

$token = $env:TELEGRAM_BOT_TOKEN
$chatId = $env:TELEGRAM_CHAT_ID
if (-not $token -or -not $chatId) {
    Write-Error "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID environment variables must be set."
    exit 1
}

$offset = 0
if (Test-Path $OffsetPath) {
    $raw = Get-Content $OffsetPath -Raw | ConvertFrom-Json
    $offset = [int64]$raw.offset
}

$updatesUri = "https://api.telegram.org/bot$token/getUpdates?offset=$offset&timeout=0"
$updates = Invoke-RestMethod -Uri $updatesUri -Method Get

if (-not $updates.ok) {
    Write-Error "getUpdates failed: $($updates | ConvertTo-Json -Compress)"
    exit 1
}

$maxUpdateId = $offset - 1

foreach ($update in $updates.result) {
    if ($update.update_id -gt $maxUpdateId) {
        $maxUpdateId = $update.update_id
    }

    $message = $update.message
    if (-not $message -or -not $message.text) { continue }
    if ("$($message.chat.id)" -ne "$chatId") {
        Write-Host "Ignoring message from unauthorized chat_id $($message.chat.id)"
        continue
    }

    $query = $message.text.Trim()
    if (-not $query) { continue }

    $match = $channels | Where-Object { $_.name -ieq $query } | Select-Object -First 1
    if (-not $match) {
        $match = $channels | Where-Object { $_.name -match [regex]::Escape($query) } | Select-Object -First 1
    }

    if (-not $match) {
        $names = ($channels | ForEach-Object { $_.name }) -join ", "
        Send-TelegramText $token $chatId "No channel matching `"$(Escape-Html $query)`". Tracked channels: $(Escape-Html $names)"
        continue
    }

    Write-Host "Matched '$query' -> $($match.name)"
    try {
        $entries = Get-Feed $match.channel_id
    } catch {
        Send-TelegramText $token $chatId "Couldn't fetch videos for $(Escape-Html $match.name): $_"
        continue
    }

    if ($entries.Count -eq 0) {
        Send-TelegramText $token $chatId "$(Escape-Html $match.name) has no uploads."
        continue
    }

    $count = [Math]::Min(5, $entries.Count)
    $lastFive = @($entries[(-$count)..(-1)])
    # $lastFive is oldest-to-newest; send newest first.
    [array]::Reverse($lastFive)

    foreach ($video in $lastFive) {
        Send-TelegramVideo $token $chatId $video $match.name
    }
}

@{ offset = $maxUpdateId + 1 } | ConvertTo-Json | Set-Content -Path $OffsetPath -Encoding utf8
