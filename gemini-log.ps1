<#
.SYNOPSIS
  Gemini（ブラウザ版のみ・自動チェック不可）用の手動ログ記録スクリプト。
  上限に当たった/回復した瞬間に自分で実行してください。

.使い方
  .\gemini-log.ps1 -Action depleted
  .\gemini-log.ps1 -Action recovered
#>

param(
  [Parameter(Mandatory=$true)][ValidateSet("depleted","recovered")][string]$Action
)

. (Join-Path $PSScriptRoot "send-gmail.ps1")

$dataPath = Join-Path $PSScriptRoot "data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json
$svc = $data.services | Where-Object { $_.id -eq "gemini" }
$now = Get-Date
$nowIso = $now.ToString("yyyy-MM-ddTHH:mm:sszzz")

if ($Action -eq "depleted") {
  $svc.events = @($svc.events) + [PSCustomObject]@{ timestamp = $nowIso; type = "depleted" }
  Write-Host "[gemini] 上限到達を記録しました ($nowIso)" -ForegroundColor Red
}
else {
  $sorted = $svc.events | Sort-Object { [datetime]$_.timestamp }
  $lastDepleted = $sorted | Where-Object { $_.type -eq "depleted" } | Select-Object -Last 1
  $irregular = $false
  if ($lastDepleted) {
    $expected = ([datetime]$lastDepleted.timestamp).AddHours($svc.resetCycleHours)
    $irregular = $now -lt $expected.AddMinutes(-15)
  }
  $svc.events = @($svc.events) + [PSCustomObject]@{ timestamp = $nowIso; type = "recovered"; irregular = $irregular }
  Write-Host "[gemini] 回復を記録しました ($nowIso) irregular=$irregular" -ForegroundColor Green

  Send-RecoveryGmail -Subject "[Gemini] 利用制限が回復しました" -Body "Geminiの利用制限が回復しました。`n回復時刻: $nowIso`nイレギュラー回復: $(if ($irregular) {'はい'} else {'いいえ'})" | Out-Null
}

$data | ConvertTo-Json -Depth 10 | Set-Content $dataPath -Encoding UTF8

Push-Location $PSScriptRoot
git add data.json | Out-Null
git commit -m "log: gemini $Action @ $nowIso" | Out-Null
git push | Out-Null
Pop-Location
