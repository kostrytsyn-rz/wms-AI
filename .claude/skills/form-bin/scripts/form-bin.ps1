# form-bin v1.0 — Read 1C ordinary (binary) forms: Form.bin -> module text, elements, events
param(
	[Parameter(Mandatory=$true)]
	[string]$Path,
	[ValidateSet("overview","module","elements","events","raw","unpack")]
	[string]$Mode = "overview",
	[string]$Name = "",
	[string]$OutDir = "",
	[int]$Limit = 400,
	[int]$Offset = 0
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Resolve path: Form.bin | Ext dir | form dir | Forms/<name>.xml | Template.bin-like container ---

function Resolve-FormBin([string]$p) {
	if (-not (Test-Path -LiteralPath $p)) { throw "Path not found: $p" }
	$item = Get-Item -LiteralPath $p
	if (-not $item.PSIsContainer) {
		if ($item.Extension -ieq ".xml") {
			$dir = Join-Path $item.DirectoryName $item.BaseName
			$cand = Join-Path $dir "Ext\Form.bin"
			if (Test-Path -LiteralPath $cand) { return (Get-Item -LiteralPath $cand).FullName }
			$cand = Join-Path $dir "Ext\Form.xml"
			if (Test-Path -LiteralPath $cand) { throw "This is a managed form (Ext\Form.xml). Use /inspect form-info instead: $cand" }
			throw "Form.bin not found next to $p"
		}
		return $item.FullName
	}
	foreach ($rel in @("Form.bin", "Ext\Form.bin")) {
		$cand = Join-Path $item.FullName $rel
		if (Test-Path -LiteralPath $cand) { return (Get-Item -LiteralPath $cand).FullName }
	}
	if (Test-Path -LiteralPath (Join-Path $item.FullName "Ext\Form.xml")) { throw "This is a managed form (Ext\Form.xml). Use /inspect form-info instead." }
	throw "Form.bin not found in $p"
}

$binPath = Resolve-FormBin $Path

# --- C# helper: 1C container (v8 file) reader + brace-format parser ---

if (-not ("FormBin.Reader" -as [type])) {
	Add-Type -Language CSharp -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot "FormBinReader.cs")))
}

# --- Unpack ---

$bytes = [System.IO.File]::ReadAllBytes($binPath)
$entries = [FormBin.Reader]::Unpack($bytes)

function Find-Entry($list, [string]$n) {
	foreach ($e in $list) {
		if ($e.Name -eq $n) { return $e }
		if ($e.Children) { $r = Find-Entry $e.Children $n; if ($r) { return $r } }
	}
	return $null
}

$moduleEntry = Find-Entry $entries "module"
$formEntry = Find-Entry $entries "form"
$moduleText = if ($moduleEntry) { [FormBin.Reader]::Text($moduleEntry.Data) } else { "" }
$formText = if ($formEntry) { [FormBin.Reader]::Text($formEntry.Data) } else { "" }
$moduleLines = if ($moduleText) { $moduleText -split "`r?`n" } else { @() }

# --- Mode: unpack ---

if ($Mode -eq "unpack") {
	if (-not $OutDir) {
		$rel = $binPath -replace '[:\\/]+', '_'
		if ($rel.Length -gt 120) { $rel = $rel.Substring($rel.Length - 120) }
		$OutDir = Join-Path $env:TEMP ("form-bin\" + $rel)
	}
	function Save-Entries($list, [string]$dir) {
		New-Item -ItemType Directory -Force -Path $dir | Out-Null
		foreach ($e in $list) {
			$target = Join-Path $dir $e.Name
			if ($e.Children) { Save-Entries $e.Children $target }
			else {
				$ext = if ($e.Name -eq "module") { ".bsl" } elseif ($e.Name -eq "form") { ".txt" } else { "" }
				[System.IO.File]::WriteAllBytes($target + $ext, $e.Data)
				Write-Output ("{0}{1}  ({2} bytes)" -f $target, $ext, $e.Data.Length)
			}
		}
	}
	Save-Entries $entries $OutDir
	exit 0
}

# --- Module helpers ---

function Get-Procedures {
	$res = @()
	for ($i = 0; $i -lt $moduleLines.Count; $i++) {
		$m = [regex]::Match($moduleLines[$i], '^\s*(Процедура|Функция|Procedure|Function)\s+([\wА-Яа-яЁёІіЇїЄєҐґ]+)\s*\((.*)', 'IgnoreCase')
		if ($m.Success) {
			$endLine = $null
			for ($j = $i + 1; $j -lt $moduleLines.Count; $j++) {
				if ($moduleLines[$j] -match '^\s*(КонецПроцедуры|КонецФункции|EndProcedure|EndFunction)') { $endLine = $j + 1; break }
			}
			$res += [pscustomobject]@{
				Kind = $m.Groups[1].Value; Name = $m.Groups[2].Value; Line = $i + 1; End = $endLine
				Export = ($moduleLines[$i] -match '\)\s*(Экспорт|Export)')
			}
		}
	}
	return $res
}

function Write-Lines([int]$from, [int]$to) {
	for ($k = $from; $k -le $to -and $k -le $moduleLines.Count; $k++) {
		Write-Output ("{0,5}  {1}" -f $k, $moduleLines[$k - 1])
	}
}

if ($Mode -eq "module") {
	if (-not $moduleEntry) { Write-Output "Module stream not found in $binPath"; exit 0 }
	if ($Name) {
		$procs = Get-Procedures | Where-Object { $_.Name -ieq $Name }
		if (-not $procs) { Write-Output "Procedure '$Name' not found. Available:"; Get-Procedures | ForEach-Object { Write-Output ("  {0} (line {1})" -f $_.Name, $_.Line) }; exit 0 }
		foreach ($p in $procs) { Write-Lines $p.Line ($(if ($p.End) { $p.End } else { $moduleLines.Count })) }
		exit 0
	}
	$from = $Offset + 1; $to = [Math]::Min($moduleLines.Count, $Offset + $Limit)
	Write-Output ("# Module: {0} lines, showing {1}-{2}" -f $moduleLines.Count, $from, $to)
	Write-Lines $from $to
	if ($to -lt $moduleLines.Count) { Write-Output ("... more: -Offset {0}" -f $to) }
	exit 0
}

if ($Mode -eq "raw") {
	$raw = $formText -split "`r?`n"
	$to = [Math]::Min($raw.Count, $Offset + $Limit)
	Write-Output ("# Form stream: {0} lines, showing {1}-{2}" -f $raw.Count, ($Offset + 1), $to)
	for ($k = $Offset; $k -lt $to; $k++) { Write-Output ("{0,5}  {1}" -f ($k + 1), $raw[$k]) }
	if ($to -lt $raw.Count) { Write-Output ("... more: -Offset {0}" -f $to) }
	exit 0
}

# --- Form stream analysis ---

$typeNames = @{
	"09ccdc77-ea1a-4a6d-ab1c-3435eada2433" = "Панель"
	"e69bf21d-97b2-4f37-86db-675aea9ec2cb" = "КоманднаяПанель"
	"0fc7e20d-f241-460c-bdf4-5ad88e5474a5" = "Надпись"
	"381ed624-9217-4e63-85db-c4c3cb87daae" = "ПолеВвода"
	"6ff79819-710e-4145-97cd-1618da79e3e2" = "Кнопка"
	"236a17b3-7f44-46d9-a907-75f9cdc61ab5" = "ПолеТабличногоДокумента"
}
$extraTypes = Join-Path $PSScriptRoot "element-types.txt"
if (Test-Path -LiteralPath $extraTypes) {
	foreach ($ln in Get-Content -LiteralPath $extraTypes -Encoding UTF8) {
		if ($ln -match '^\s*([0-9a-f-]{36})\s*=\s*(\S+)') { $typeNames[$Matches[1]] = $Matches[2] }
	}
}

$eventNames = @{}
$eventFile = Join-Path $PSScriptRoot "event-codes.txt"
if (Test-Path -LiteralPath $eventFile) {
	foreach ($ln in Get-Content -LiteralPath $eventFile -Encoding UTF8) {
		if ($ln -match '^\s*([^#|]+?)\s*\|\s*(\S+)\s*=\s*(\S+)') { $eventNames[$Matches[1] + "|" + $Matches[2]] = $Matches[3] }
	}
}
function Get-EventName([string]$type, [string]$code) {
	if ($eventNames.ContainsKey("$type|$code")) { return $eventNames["$type|$code"] }
	if ($eventNames.ContainsKey("*|$code")) { return $eventNames["*|$code"] }
	return "код $code"
}

$HANDLER = "e1692cc2-605b-4535-84dd-28440238746c"
$guidRx = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$langRx = '^[a-z]{2,3}$'

$root = [FormBin.Reader]::Parse($formText)

function Get-ElementName($node) {
	# Element: {<typeGuid>,<id>, ..., {14,"Name",...}, ...}
	if (-not $node.IsList -or $node.Count -lt 3) { return $null }
	$t = $node[0]
	if ($t.IsList -or $t.Quoted -or $t.Value -notmatch $guidRx) { return $null }
	foreach ($c in $node.Items) {
		if ($c.IsList -and $c.Count -ge 2 -and $c[0].IsBare("14") -and $c[1].Quoted) { return $c[1].Value }
	}
	return $null
}

function Get-LangText($node) {
	# {"ru","text"} -> text; several languages joined by " / "
	if (-not $node.IsList -or $node.Count -lt 2) { return $null }
	if ($node[0].Quoted -and $node[0].Value -match $langRx -and $node[1].Quoted) { return $node[1].Value }
	return $null
}

$elements = New-Object System.Collections.ArrayList
$events = New-Object System.Collections.ArrayList
$commands = @{}   # command guid -> handler
$buttons = New-Object System.Collections.ArrayList
$formCaption = $null

function Walk($node, $owner, [int]$depth) {
	if (-not $node.IsList) { return }
	$name = Get-ElementName $node
	if ($name) {
		$el = [pscustomobject]@{
			Name = $name; TypeGuid = $node[0].Value
			Type = $(if ($typeNames.ContainsKey($node[0].Value)) { $typeNames[$node[0].Value] } else { "? " + $node[0].Value })
			Id = $node[1].Value; Parent = $(if ($owner) { $owner.Name } else { "" })
			Caption = $null; Pages = @(); Depth = $(if ($owner) { $owner.Depth + 1 } else { 0 })
		}
		[void]$elements.Add($el)
		$owner = $el
	}
	$txt = Get-LangText $node
	if ($txt -ne $null) {
		if (-not $script:formCaption -and -not $owner) { $script:formCaption = $txt }
		elseif ($owner -and -not $owner.Caption -and $txt -ne "" -and $txt -notmatch $langRx) {
			# skip captions that belong to panel pages / buttons (handled separately)
			$gp = $node.Parent; if ($gp) { $gp = $gp.Parent }
			$isPage = $gp -and $gp.IsList -and $gp[0].IsBare("4")
			$isButton = $node.Parent -and $node.Parent.Parent -and $node.Parent.Parent.IsList -and $node.Parent.Parent[0].IsBare("8")
			$isHandler = $node.Parent -and $node.Parent.Parent -and $node.Parent.Parent.IsList -and ($node.Parent.Parent[0].IsBare("1") -or $node.Parent.Parent[0].IsBare("3")) -and $node.Parent.Parent[1].Quoted
			# these types have no own caption: first text found belongs to a column / submenu / cell
			$noCaption = @("ТабличноеПоле", "КоманднаяПанель", "ПолеТабличногоДокумента", "ПолеСписка", "ПолеТекстовогоДокумента", "ПолеHTMLДокумента")
			if (-not $isPage -and -not $isButton -and -not $isHandler -and ($noCaption -notcontains $owner.Type)) { $owner.Caption = $txt }
		}
	}
	# Panel page: {4,{1,1,{"ru","Caption"}},..., "PageName", ...}
	if ($owner -and $owner.TypeGuid -eq "09ccdc77-ea1a-4a6d-ab1c-3435eada2433" -and $node.Count -gt 3 -and $node[0].IsBare("4") -and $node[1].IsList) {
		$cap = $null
		foreach ($c in $node[1].Items) { $t = Get-LangText $c; if ($t -ne $null) { $cap = $t; break } }
		if ($cap -ne $null) {
			$pname = $null
			for ($k = 2; $k -lt $node.Count; $k++) { if ($node[$k].Quoted -and $node[$k].Value -ne "") { $pname = $node[$k].Value; break } }
			if ($pname) { $owner.Pages += ("{0} «{1}»" -f $pname, $cap) }
		}
	}
	# Event handler: {..., e1692cc2-..., {3,"Handler",...}}
	for ($k = 0; $k -lt $node.Count - 1; $k++) {
		if ($node[$k].IsBare($HANDLER) -and $node[$k + 1].IsList -and $node[$k + 1].Count -ge 2 -and $node[$k + 1][1].Quoted) {
			$handler = $node[$k + 1][1].Value
			if ($node[0].IsBare("6") -and $node.Count -gt 1 -and $node[1].Value -match $guidRx) {
				$commands[$node[1].Value] = $handler
			} else {
				$code = ($node.Items[0..($k - 1)] | ForEach-Object { $_.Value }) -join "/"
				[void]$events.Add([pscustomobject]@{ Element = $(if ($owner) { $owner.Name } else { "<Форма>" }); Type = $(if ($owner) { $owner.Type } else { "Форма" }); Code = $code; Handler = $handler })
			}
		}
	}
	# Command bar button: {..., <cmdGuid>, {8,"ButtonName",..., {1,1,{"ru","Caption"}}}}
	for ($k = 1; $k -lt $node.Count; $k++) {
		$b = $node[$k]
		if ($b.IsList -and $b.Count -ge 2 -and $b[0].IsBare("8") -and $b[1].Quoted -and $node[$k - 1].Value -match $guidRx) {
			$cap = $null
			foreach ($c in $b.Items) { if ($c.IsList) { foreach ($cc in $c.Items) { $t = Get-LangText $cc; if ($t -ne $null) { $cap = $t; break } } }; if ($cap) { break } }
			[void]$buttons.Add([pscustomobject]@{ Bar = $(if ($owner) { $owner.Name } else { "" }); Name = $b[1].Value; Caption = $cap; Cmd = $node[$k - 1].Value })
		}
	}
	foreach ($c in $node.Items) { if ($c.IsList) { Walk $c $owner ($depth + 1) } }
}

Walk $root $null 0

# Deduplicate buttons (command bar stores buttons twice: layout + actions)
$buttons = $buttons | Group-Object Bar, Name | ForEach-Object { $_.Group[0] }

function Show-Elements {
	Write-Output ("## Элементы ({0})" -f $elements.Count)
	foreach ($e in $elements) {
		$ind = "  " * $e.Depth
		$cap = if ($e.Caption) { "  «" + $e.Caption + "»" } else { "" }
		Write-Output ("{0}- {1} [{2}]{3}" -f $ind, $e.Name, $e.Type, $cap)
		foreach ($p in $e.Pages) { Write-Output ("{0}    страница: {1}" -f $ind, $p) }
		foreach ($b in ($buttons | Where-Object { $_.Bar -eq $e.Name })) {
			$h = if ($commands.ContainsKey($b.Cmd)) { " -> " + $commands[$b.Cmd] } else { "" }
			$c = if ($b.Caption) { " «" + $b.Caption + "»" } else { "" }
			Write-Output ("{0}    кнопка: {1}{2}{3}" -f $ind, $b.Name, $c, $h)
		}
	}
}

function Show-Events {
	Write-Output ("## Обработчики событий ({0})" -f $events.Count)
	foreach ($ev in $events) { Write-Output ("- {0} [{1}].{2} -> {3}" -f $ev.Element, $ev.Type, (Get-EventName $ev.Type $ev.Code), $ev.Handler) }
	$used = $buttons | Where-Object { $commands.ContainsKey($_.Cmd) }
	if ($used) {
		Write-Output "## Кнопки командных панелей -> обработчики"
		foreach ($b in $used) { Write-Output ("- {0}.{1} -> {2}" -f $b.Bar, $b.Name, $commands[$b.Cmd]) }
	}
}

if ($Mode -eq "elements") { Show-Elements; exit 0 }
if ($Mode -eq "events") { Show-Events; exit 0 }

# --- overview ---

Write-Output ("# Обычная форма: {0}" -f $binPath)
if ($formCaption) { Write-Output ("Заголовок: «{0}»" -f $formCaption) }
Write-Output ("Потоки контейнера: {0}" -f (($entries | ForEach-Object { "{0} ({1} b)" -f $_.Name, $_.Data.Length }) -join ", "))
Write-Output ""
Show-Elements
Write-Output ""
Show-Events
Write-Output ""
$procs = Get-Procedures
Write-Output ("## Модуль формы: {0} строк, процедур/функций: {1}" -f $moduleLines.Count, @($procs).Count)
foreach ($p in $procs) {
	$exp = if ($p.Export) { " Экспорт" } else { "" }
	Write-Output ("- {0} {1}{2}  (строки {3}-{4})" -f $p.Kind, $p.Name, $exp, $p.Line, $p.End)
}
$unknown = $elements | Where-Object { $_.Type -like "? *" } | Select-Object -ExpandProperty TypeGuid -Unique
if ($unknown) {
	Write-Output ""
	Write-Output "Неизвестные GUID типов элементов (можно дописать в scripts/element-types.txt): $($unknown -join ', ')"
}
