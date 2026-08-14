<#
.SYNOPSIS
  watch-agent.ps1 をWindowsタスクスケジューラに登録し、以後10分おきに
  自動実行させる（=これ以降は完全放置でOK）。最初の1回だけ実行してください。

.使い方
  管理者権限のPowerShellで:
  .\setup-task.ps1
#>

$taskName = "RecoveryDashboardWatcher"
$scriptPath = Join-Path $PSScriptRoot "watch-agent.ps1"
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }

$action = New-ScheduledTaskAction -Execute $pwsh `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

# [TimeSpan]::MaxValue はタスクスケジューラのXMLスキーマ（ISO8601 duration）が
# 受け付ける上限を超えてしまい Register-ScheduledTask がエラーになるため、
# 実質的に無期限とみなせる長期間（10年）を指定する。
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 10) `
  -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -DontStopOnIdleEnd

try {
  Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Settings $settings `
    -Description "回復量ダッシュボード: Claude/Codexの利用制限を10分おきに自動チェック" `
    -Force -ErrorAction Stop | Out-Null
} catch {
  Write-Host "タスクの登録に失敗しました: $_" -ForegroundColor Red
  exit 1
}

Write-Host "タスク '$taskName' を登録しました。10分おきに自動実行されます。" -ForegroundColor Green
Write-Host "確認/停止する場合: タスクスケジューラ（taskschd.msc）から '$taskName' を探してください。" -ForegroundColor Cyan
