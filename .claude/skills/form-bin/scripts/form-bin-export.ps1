# form-bin-export v1.0 — batch: every ordinary form (Form.bin) of a dump -> Module.bsl in a mirror cache,
# so that form-module code can be searched with Grep like the rest of the .bsl files.
param(
	[Parameter(Mandatory=$true)]
	[string]$ConfigPath,          # dump root, e.g. configuration
	[string]$OutDir = "",         # default: <parent of ConfigPath>\.formbin-cache
	[switch]$Force                # re-export even if the cached .bsl is newer than Form.bin
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = (Get-Item -LiteralPath $ConfigPath).FullName.TrimEnd('\')
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $root -Parent) ".formbin-cache" }

if (-not ("FormBin.Reader" -as [type])) {
	Add-Type -Language CSharp -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "FormBinReader.cs")))
}

function Find-Entry($list, [string]$n) {
	foreach ($e in $list) {
		if ($e.Name -eq $n) { return $e }
		if ($e.Children) { $r = Find-Entry $e.Children $n; if ($r) { return $r } }
	}
	return $null
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$done = 0; $skipped = 0; $empty = 0; $failed = @()

foreach ($bin in Get-ChildItem -LiteralPath $root -Recurse -Filter "Form.bin" -File) {
	# <...>\Forms\<Имя>\Ext\Form.bin  ->  <OutDir>\<...>\Forms\<Имя>\Ext\Form\Module.bsl (same layout as managed forms)
	$rel = $bin.FullName.Substring($root.Length + 1)
	$target = Join-Path $OutDir ((Split-Path $rel -Parent) + "\Form\Module.bsl")
	if (-not $Force -and (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).LastWriteTime -ge $bin.LastWriteTime)) { $skipped++; continue }
	try {
		$entries = [FormBin.Reader]::Unpack([System.IO.File]::ReadAllBytes($bin.FullName))
		$m = Find-Entry $entries "module"
		$text = if ($m) { [FormBin.Reader]::Text($m.Data) } else { "" }
		if (-not $text) { $empty++ }
		New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
		[System.IO.File]::WriteAllText($target, $text, $utf8Bom)
		$done++
	} catch {
		$failed += ("{0}: {1}" -f $rel, $_.Exception.Message)
	}
}

Write-Output ("Cache: {0}" -f $OutDir)
Write-Output ("Exported: {0}, up to date: {1}, empty module: {2}, failed: {3}" -f $done, $skipped, $empty, $failed.Count)
$failed | ForEach-Object { Write-Output ("  FAILED {0}" -f $_) }
