# Shared helpers used by notifier.ps1 and command.ps1.

function Escape-Html([string]$text) {
    return $text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function Get-Feed([string]$channelId) {
    $url = "https://www.youtube.com/feeds/videos.xml?channel_id=$channelId"
    $resp = Invoke-WebRequest -Uri $url -UserAgent "Mozilla/5.0" -UseBasicParsing
    [xml]$xml = $resp.Content

    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("atom", "http://www.w3.org/2005/Atom")
    $ns.AddNamespace("media", "http://search.yahoo.com/mrss/")
    $ns.AddNamespace("yt", "http://www.youtube.com/xml/schemas/2015")

    $entries = @()
    foreach ($entry in $xml.SelectNodes("//atom:entry", $ns)) {
        $videoId = $entry.SelectSingleNode("yt:videoId", $ns).InnerText
        $title = $entry.SelectSingleNode("atom:title", $ns).InnerText
        $linkNode = $entry.SelectSingleNode("atom:link", $ns)
        $link = if ($linkNode) { $linkNode.GetAttribute("href") } else { "https://www.youtube.com/watch?v=$videoId" }
        $thumbNode = $entry.SelectSingleNode("media:group/media:thumbnail", $ns)
        $thumb = if ($thumbNode) { $thumbNode.GetAttribute("url") } else { "" }

        $entries += [PSCustomObject]@{
            VideoId        = $videoId
            Title          = $title
            Link           = $link
            Thumbnail      = $thumb
            # Highest-res, full 9:16 crop YouTube serves for Shorts (falls back below if missing).
            ThumbnailHiRes = "https://i.ytimg.com/vi/$videoId/oardefault.jpg"
        }
    }
    # Feed is newest-first; reverse so index 0 = oldest.
    [array]::Reverse($entries)
    return $entries
}

# Windows PowerShell 5.1 does not UTF-8-encode a string -Body by default,
# which corrupts non-ASCII characters (accents, emoji) and gets rejected by
# Telegram ("text must be encoded in UTF-8"). Encoding to bytes ourselves
# sidesteps that on both Windows PowerShell and pwsh (GitHub Actions runners).
function Invoke-TelegramApi([string]$uri, [hashtable]$payload) {
    $json = $payload | ConvertTo-Json
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
}

function Send-TelegramVideo([string]$token, [string]$chatId, $video, [string]$channelName) {
    $kind = if ($video.Link -match "/shorts/") { "Short" } else { "Video" }
    $caption = '<a href="' + $video.Link + '">' + (Escape-Html $video.Title) + '</a>' + "`n`n" + $kind + "`n`n" + '<b>' + (Escape-Html $channelName) + '</b>'
    $uri = "https://api.telegram.org/bot$token/sendPhoto"

    # Try the high-res vertical crop first; fall back to the feed's default
    # thumbnail if that variant doesn't exist for this video (e.g. non-Shorts uploads).
    $candidates = @($video.ThumbnailHiRes, $video.Thumbnail) | Where-Object { $_ }

    foreach ($photoUrl in $candidates) {
        $payload = @{
            chat_id    = $chatId
            photo      = $photoUrl
            caption    = $caption
            parse_mode = "HTML"
        }

        try {
            $result = Invoke-TelegramApi $uri $payload
            if ($result.ok) {
                return
            }
            Write-Warning "Telegram API error for $photoUrl : $($result | ConvertTo-Json -Compress)"
        } catch {
            Write-Warning "Telegram request failed for $photoUrl : $_"
        }
    }
    Write-Warning "All thumbnail variants failed for '$($video.Title)'; notification not sent."
}

function Send-TelegramText([string]$token, [string]$chatId, [string]$text) {
    $uri = "https://api.telegram.org/bot$token/sendMessage"
    $payload = @{
        chat_id    = $chatId
        text       = $text
        parse_mode = "HTML"
    }
    try {
        Invoke-TelegramApi $uri $payload | Out-Null
    } catch {
        Write-Warning "Telegram sendMessage failed: $_"
    }
}
