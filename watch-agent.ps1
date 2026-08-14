<#
.SYNOPSIS
  Claude Code と Codex CLI(ChatGPT) の利用制限状態を自動でチェックし、
  data.json を更新 → git push → (回復検知時)Gmail通知 まで行う無人監視スクリプト。
  Windowsタスクスケジューラから定期実行される想定（setup-task.ps1 参照）。

.重要な前提・限界（正直に書いておきます）
  - OpenAI(Codex)は「残り使用量をAPIで問い合わせる」公式手段が現時点で存在しません。
    ChatGPT側は引き続き「ごく軽いプロンプトを実際に送ってみて、制限メッセージが返るか」
    を見る"ping方式"で判定します（非対話でのレート情報取得が未サポートであることが
    OpenAI公式リポジトリのissueで確認済みです）。
  - Claudeは 2026-08-14 以降、Claude Codeのstatus line hook
    （~/.claude/statusline_dashboard.py）が書き出す ~/.claude/rate_limit_cache.json
    から実際の rate_limits（5時間枠/週間枠の使用率・リセット時刻）を読み取れるように
    なったため、これを正として使う（"statusline方式"）。このキャッシュは対話セッションで
    status lineが描画されたときにしか更新されないため、存在しない/24時間以上古い場合は
    従来のping方式にフォールバックする。
  - ping方式のチェック自体は極小だが実際の利用量を消費する。既定は10分間隔。
  - 制限メッセージの文言はプラン・言語・時期によって変わる可能性がある。
    誤検知に気づいたら下の $claudeLimitPattern / $codexLimitPattern を調整すること。
  - Geminiはブラウザ版のみのためこの自動チェック対象外（gemini-log.ps1で手動記録）。
#>

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
. (Join-Path $PSScriptRoot "send-gmail.ps1")

$dataPath = Join-Path $PSScriptRoot "data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json
$now = Get-Date
$nowIso = $now.ToString("yyyy-MM-ddTHH:mm:sszzz")

# 検知用の正規表現は「制限に達した」ことの判定と、reset目安時刻の抽出を分離している。
# reset目安の文言（"resets at ..." / "resets ..." / "resets in ..." 等）は将来変わりうるため、
# 抽出に失敗しても depleted 判定自体は妥当なままにするための設計。
# 2026-08-14 実機検証: claude.exe バイナリ内の文字列から、実際の表示は
#   "<Type> limit reached · resets <time>" / "resets in <duration>" のように
#   "resets" の直後に "at" が付かないケースがあることを確認した。
#   旧正規表現は "resets? \s+ at \s+" を必須としていたため、このケースで
#   reset目安の抽出は失敗するが、下記の分離設計により depleted 判定自体には影響しない。
$claudeLimitPattern = '(?is)usage limit reached'
$claudeResetHintPattern = '(?is)resets?\s*(?:at|in)?\s*([^,."\r\n]{1,60})'
# codex CLI はこの環境に未インストールのため、下記パターンは実機検証できていない。
# README/AGENT_PROMPT記載の通りOpenAI公式でも非対話でのレート情報取得は未サポートであり、
# 実際のメッセージ文言は "codex exec" 経由で制限に当たった際に必ず一度目視確認すること。
$codexLimitPattern = '(?is)usage limit reached|rate limit'
$codexResetHintPattern = '(?is)(try again[^\r\n."]*|resets?\s*(?:at|in)?\s*[^,."\r\n]{1,60})'

# Claude statusline方式（実数値）関連
$claudeCachePath = Join-Path $HOME ".claude\rate_limit_cache.json"
$claudeCacheMaxAgeHours = 24
$claudeDepletedThreshold = 99.5   # usedPercentageがこれ以上なら「上限到達」とみなす
$claudeRecoveryDropPoints = 20    # 直前ポーリングからこれ以上usedPercentageが下がったら「回復」とみなす

function Get-ResetHint($raw, $hintPattern) {
  if ($raw -match $hintPattern) { return $Matches[1].Trim() }
  return $null
}

function Test-ClaudeStatus {
  try {
    $raw = (& claude -p "Reply with only the single word OK." --output-format json 2>&1) -join "`n"
  } catch {
    return [PSCustomObject]@{ status = "unknown"; raw = "$_" }
  }

  # --output-format json は1行のJSONを出力する想定だが、フック等の余計な行が
  # 混ざることがあるため、JSONとして読める行を後ろから探して優先的に見る。
  $jsonLine = ($raw -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
  $parsed = $null
  if ($jsonLine) {
    try { $parsed = $jsonLine | ConvertFrom-Json } catch { $parsed = $null }
  }

  if ($raw -match $claudeLimitPattern) {
    return [PSCustomObject]@{ status = "depleted"; resetHint = (Get-ResetHint $raw $claudeResetHintPattern); raw = $raw }
  }
  if ($parsed) {
    if ($parsed.is_error -eq $true) {
      # 制限メッセージにはマッチしなかったが is_error=true → 他のエラー(認証切れ、
      # ネットワーク不通等)の可能性があるため、readyと誤判定せず unknown にする。
      return [PSCustomObject]@{ status = "unknown"; raw = $raw }
    }
    if ($parsed.is_error -eq $false) {
      return [PSCustomObject]@{ status = "ready"; raw = $raw }
    }
  }
  # JSONが解釈できず制限文言にも一致しない場合は判定不能として扱う。
  return [PSCustomObject]@{ status = "unknown"; raw = $raw }
}

function Test-CodexStatus {
  try {
    $raw = (& codex exec "Reply with only the single word OK." --json --skip-git-repo-check --ephemeral 2>&1) -join "`n"
  } catch {
    return [PSCustomObject]@{ status = "unknown"; raw = "$_" }
  }
  if ($raw -match $codexLimitPattern) {
    return [PSCustomObject]@{ status = "depleted"; resetHint = (Get-ResetHint $raw $codexResetHintPattern); raw = $raw }
  }
  return [PSCustomObject]@{ status = "ready"; raw = $raw }
}

function Get-LastEvent($svc) {
  $sorted = $svc.events | Sort-Object { [datetime]$_.timestamp }
  if ($sorted.Count -eq 0) { return $null }
  return $sorted[$sorted.Count - 1]
}

# ~/.claude/rate_limit_cache.json を読み、有効(24時間以内・fiveHourあり)なら返す。無ければ$null。
function Get-ClaudeRateLimitCache {
  if (-not (Test-Path $claudeCachePath)) { return $null }
  try {
    $cache = Get-Content $claudeCachePath -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $cache.updatedAt) { return $null }
  try {
    $updatedAt = [datetimeoffset]::Parse($cache.updatedAt)
  } catch {
    return $null
  }
  $ageHours = ([datetimeoffset]::UtcNow - $updatedAt).TotalHours
  if ($ageHours -lt 0 -or $ageHours -gt $claudeCacheMaxAgeHours) { return $null }
  if (-not $cache.fiveHour -or $null -eq $cache.fiveHour.usedPercentage) { return $null }
  return $cache
}

# statusline方式でclaudeサービスを更新する。戻り値: @{ changed=bool; notifications=@() }
function Update-ClaudePrecise($svc, $cache) {
  $result = @{ changed = $false; notifications = @() }

  $previousUsed = $svc.usedPercentage
  $usedPercentage = $cache.fiveHour.usedPercentage
  $resetsAt = $cache.fiveHour.resetsAt
  $weeklyUsedPercentage = if ($cache.sevenDay) { $cache.sevenDay.usedPercentage } else { $null }
  $weeklyResetsAt = if ($cache.sevenDay) { $cache.sevenDay.resetsAt } else { $null }

  if ("$($svc.usedPercentage)" -ne "$usedPercentage" -or "$($svc.resetsAt)" -ne "$resetsAt" -or
      "$($svc.weeklyUsedPercentage)" -ne "$weeklyUsedPercentage" -or "$($svc.weeklyResetsAt)" -ne "$weeklyResetsAt" -or
      $svc.lastSource -ne "statusline" -or $svc.mode -ne "auto-precise") {
    $result.changed = $true
  }

  $svc | Add-Member -NotePropertyName usedPercentage -NotePropertyValue $usedPercentage -Force
  $svc | Add-Member -NotePropertyName resetsAt -NotePropertyValue $resetsAt -Force
  $svc | Add-Member -NotePropertyName weeklyUsedPercentage -NotePropertyValue $weeklyUsedPercentage -Force
  $svc | Add-Member -NotePropertyName weeklyResetsAt -NotePropertyValue $weeklyResetsAt -Force
  $svc | Add-Member -NotePropertyName lastSource -NotePropertyValue "statusline" -Force
  $svc | Add-Member -NotePropertyName mode -NotePropertyValue "auto-precise" -Force

  $last = Get-LastEvent $svc
  $pendingRecovery = ($last -and $last.type -eq "depleted")

  if ($usedPercentage -ge $claudeDepletedThreshold -and -not $pendingRecovery) {
    $svc.events = @($svc.events) + [PSCustomObject]@{
      timestamp = $nowIso
      type      = "depleted"
      resetHint = $resetsAt
    }
    Write-Host "[claude] 上限到達を検知(statusline) ($nowIso) resetsAt=$resetsAt" -ForegroundColor Red
    $result.changed = $true
  }
  elseif ($pendingRecovery -and $null -ne $previousUsed -and $previousUsed -ge 95 -and
          ($previousUsed - $usedPercentage) -ge $claudeRecoveryDropPoints) {
    $lastDepletedAt = [datetime]$last.timestamp
    $expected = $lastDepletedAt.AddHours($svc.resetCycleHours)
    $irregular = $now -lt $expected.AddMinutes(-15)

    $svc.events = @($svc.events) + [PSCustomObject]@{
      timestamp = $nowIso
      type      = "recovered"
      irregular = $irregular
    }
    Write-Host "[claude] 回復を検知(statusline) ($nowIso) irregular=$irregular" -ForegroundColor Green
    $result.changed = $true

    $subject = if ($irregular) { "[$($svc.name)] 通常より早く回復しました" } else { "[$($svc.name)] 利用制限が回復しました" }
    $body = @"
$($svc.name) の利用制限が回復しました。

回復時刻: $nowIso
上限到達時刻: $($last.timestamp)
通常のリセット目安: $($svc.resetCycleHours)時間後 ($($expected.ToString('yyyy-MM-dd HH:mm')))
イレギュラー回復: $(if ($irregular) { 'はい（通常より早い）' } else { 'いいえ（通常どおり）' })
"@
    $result.notifications += @{ subject = $subject; body = $body }
  }

  return $result
}

$changed = $false
$notifications = @()

# --- Claude: statuslineキャッシュがあればそれを正として使い、無い/古い場合のみpingにフォールバック ---
$claudeSvc = $data.services | Where-Object { $_.id -eq "claude" }
if ($claudeSvc) {
  $claudeCache = Get-ClaudeRateLimitCache

  if ($claudeCache) {
    $r = Update-ClaudePrecise $claudeSvc $claudeCache
    if ($r.changed) { $changed = $true }
    $notifications += $r.notifications
  }
  else {
    $prevSource = $claudeSvc.lastSource
    $prevMode = $claudeSvc.mode
    $result = Test-ClaudeStatus

    if ($result.status -eq "unknown") {
      Write-Host "[claude] 状態を確認できませんでした（ping方式・キャッシュ無し/期限切れ）: $($result.raw)" -ForegroundColor Yellow
    }
    else {
      $claudeSvc | Add-Member -NotePropertyName lastSource -NotePropertyValue "ping" -Force
      $claudeSvc | Add-Member -NotePropertyName mode -NotePropertyValue "auto-precise" -Force
      if ($prevSource -ne "ping" -or $prevMode -ne "auto-precise") { $changed = $true }

      $last = Get-LastEvent $claudeSvc
      $pendingRecovery = ($last -and $last.type -eq "depleted")

      if ($result.status -eq "depleted" -and -not $pendingRecovery) {
        $claudeSvc.events = @($claudeSvc.events) + [PSCustomObject]@{
          timestamp = $nowIso
          type      = "depleted"
          resetHint = $result.resetHint
        }
        Write-Host "[claude] 上限到達を検知(ping) ($nowIso) 目安: $($result.resetHint)" -ForegroundColor Red
        $changed = $true
      }
      elseif ($result.status -eq "ready" -and $pendingRecovery) {
        $lastDepletedAt = [datetime]$last.timestamp
        $expected = $lastDepletedAt.AddHours($claudeSvc.resetCycleHours)
        $irregular = $now -lt $expected.AddMinutes(-15)

        $claudeSvc.events = @($claudeSvc.events) + [PSCustomObject]@{
          timestamp = $nowIso
          type      = "recovered"
          irregular = $irregular
        }
        Write-Host "[claude] 回復を検知(ping) ($nowIso) irregular=$irregular" -ForegroundColor Green
        $changed = $true

        $subject = if ($irregular) { "[$($claudeSvc.name)] 通常より早く回復しました" } else { "[$($claudeSvc.name)] 利用制限が回復しました" }
        $body = @"
$($claudeSvc.name) の利用制限が回復しました。

回復時刻: $nowIso
上限到達時刻: $($last.timestamp)
通常のリセット目安: $($claudeSvc.resetCycleHours)時間後 ($($expected.ToString('yyyy-MM-dd HH:mm')))
イレギュラー回復: $(if ($irregular) { 'はい（通常より早い）' } else { 'いいえ（通常どおり）' })
"@
        $notifications += @{ subject = $subject; body = $body }
      }
      # 状態変化なし（変わらずready、または変わらずdepleted）の場合はイベントは追加しない
    }
  }
}

# --- ChatGPT: 従来どおりping方式のみ ---
foreach ($cfg in @(
    @{ id = "chatgpt"; test = { Test-CodexStatus } }
  )) {

  $svc = $data.services | Where-Object { $_.id -eq $cfg.id }
  if (-not $svc) { continue }

  $result = & $cfg.test
  if ($result.status -eq "unknown") {
    Write-Host "[$($cfg.id)] 状態を確認できませんでした（コマンド未導入 or 未ログインの可能性）: $($result.raw)" -ForegroundColor Yellow
    continue
  }

  $last = Get-LastEvent $svc
  $pendingRecovery = ($last -and $last.type -eq "depleted")

  if ($result.status -eq "depleted" -and -not $pendingRecovery) {
    $svc.events = @($svc.events) + [PSCustomObject]@{
      timestamp = $nowIso
      type      = "depleted"
      resetHint = $result.resetHint
    }
    Write-Host "[$($cfg.id)] 上限到達を検知 ($nowIso) 目安: $($result.resetHint)" -ForegroundColor Red
    $changed = $true
  }
  elseif ($result.status -eq "ready" -and $pendingRecovery) {
    $lastDepletedAt = [datetime]$last.timestamp
    $expected = $lastDepletedAt.AddHours($svc.resetCycleHours)
    $irregular = $now -lt $expected.AddMinutes(-15)

    $svc.events = @($svc.events) + [PSCustomObject]@{
      timestamp = $nowIso
      type      = "recovered"
      irregular = $irregular
    }
    Write-Host "[$($cfg.id)] 回復を検知 ($nowIso) irregular=$irregular" -ForegroundColor Green
    $changed = $true

    $subject = if ($irregular) { "[$($svc.name)] 通常より早く回復しました" } else { "[$($svc.name)] 利用制限が回復しました" }
    $body = @"
$($svc.name) の利用制限が回復しました。

回復時刻: $nowIso
上限到達時刻: $($last.timestamp)
通常のリセット目安: $($svc.resetCycleHours)時間後 ($($expected.ToString('yyyy-MM-dd HH:mm')))
イレギュラー回復: $(if ($irregular) { 'はい（通常より早い）' } else { 'いいえ（通常どおり）' })
"@
    $notifications += @{ subject = $subject; body = $body }
  }
  # 状態変化なし（変わらずready、または変わらずdepleted）の場合は何もしない
}

if ($changed) {
  $data | ConvertTo-Json -Depth 10 | Set-Content $dataPath -Encoding UTF8

  git add data.json | Out-Null
  git commit -m "auto: recovery check @ $nowIso" | Out-Null
  git push | Out-Null

  foreach ($n in $notifications) {
    Send-RecoveryGmail -Subject $n.subject -Body $n.body | Out-Null
  }
} else {
  Write-Host "変化なし ($nowIso)"
}
