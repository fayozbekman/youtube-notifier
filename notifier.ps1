# YouTube new-upload notifier -> Telegram (cloud / GitHub Actions version).
#
# Free approach: reads each channel's public RSS feed
# (https://www.youtube.com/feeds/videos.xml?channel_id=...), which needs no
# API key and no quota, and sends a Telegram message (thumbnail + linked
# title, marked Short/Video, channel name in bold) for any video published
# since the last run.
#
# Channel list lives in channels.json (not sensitive, committed to the repo).
# Telegram credentials come from environment variables, populated by the
# GitHub Actions workflow from repository secrets - never stored in the repo.
# "Last seen" video per channel lives in state.json, which the workflow
# commits back to the repo after each run so state survives between runs.

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ChannelsPath = Join-Path $ScriptDir "channels.json"
$StatePath = Join-Path $ScriptDir "state.json"

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

$state = @{}
if (Test-Path $StatePath) {
    $raw = Get-Content $StatePath -Raw | ConvertFrom-Json
    foreach ($prop in $raw.PSObject.Properties) {
        $state[$prop.Name] = $prop.Value
    }
}

foreach ($channel in $channels) {
    $channelId = $channel.channel_id
    $name = if ($channel.name) { $channel.name } else { $channelId }

    try {
        $entries = Get-Feed $channelId
    } catch {
        Write-Warning "[$name] Failed to fetch feed: $_"
        continue
    }

    if ($entries.Count -eq 0) {
        continue
    }

    $lastSeen = $state[$channelId]

    if (-not $lastSeen) {
        # First run for this channel: just record current state, don't
        # blast out the whole back catalog.
        $state[$channelId] = $entries[-1].VideoId
        Write-Host "[$name] Initialized, $($entries.Count) existing videos noted (no notifications sent)."
        continue
    }

    $idx = -1
    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($entries[$i].VideoId -eq $lastSeen) { $idx = $i; break }
    }

    if ($idx -eq -1) {
        $newEntries = , $entries[-1]
    } elseif (($idx + 1) -ge $entries.Count) {
        $newEntries = @()
    } else {
        $newEntries = $entries[($idx + 1)..($entries.Count - 1)]
    }

    foreach ($video in $newEntries) {
        if (-not $video) { continue }
        Write-Host "[$name] New video: $($video.Title) ($($video.Link))"
        Send-TelegramVideoBest $token $chatId $video $name
    }

    $state[$channelId] = $entries[-1].VideoId
}

$state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding utf8
