# =====================================================================
#  Změna autora ve Word / Excel souborech
#  Použití: přetáhni soubory (nebo složku) na zmen-autora.bat
# =====================================================================

# ------------------------- NASTAVENÍ ---------------------------------
$Autor = "Jan Novák"                # nový autor
$ZmenitNaposledyUlozil = $true      # přepsat i "Naposledy uložil"
# ---------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$PriponyOoxml = '.docx', '.docm', '.dotx', '.dotm', '.xlsx', '.xlsm', '.xltx', '.xltm'
$PriponyWord  = '.doc', '.dot'
$PriponyExcel = '.xls', '.xlt'
$VsechnyPripony = $PriponyOoxml + $PriponyWord + $PriponyExcel

# --- nové formáty (docx/xlsx): přímá úprava docProps/core.xml, Office není potřeba ---

function Set-XmlHodnota($Xml, $Ns, $Prefix, $Nazev, $Hodnota) {
    $root = $Xml.DocumentElement
    $nalezene = $root.GetElementsByTagName($Nazev, $Ns)
    if ($nalezene.Count -gt 0) {
        $el = $nalezene.Item(0)
    } else {
        $el = $Xml.CreateElement($Prefix, $Nazev, $Ns)
        [void]$root.AppendChild($el)
    }
    $el.InnerText = $Hodnota
}

function Set-AutorOoxml($Cesta) {
    $zip = [System.IO.Compression.ZipFile]::Open($Cesta, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry('docProps/core.xml')
        if (-not $entry) { throw "soubor neobsahuje docProps/core.xml" }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        $obsah = $reader.ReadToEnd()
        $reader.Close()

        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.LoadXml($obsah)

        Set-XmlHodnota $xml 'http://purl.org/dc/elements/1.1/' 'dc' 'creator' $Autor
        if ($ZmenitNaposledyUlozil) {
            Set-XmlHodnota $xml 'http://schemas.openxmlformats.org/package/2006/metadata/core-properties' 'cp' 'lastModifiedBy' $Autor
        }

        $entry.Delete()
        $stream = $zip.CreateEntry('docProps/core.xml').Open()
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
        $writer = [System.Xml.XmlWriter]::Create($stream, $settings)
        $xml.Save($writer)
        $writer.Close()
        $stream.Close()
    } finally {
        $zip.Dispose()
    }
}

# --- staré formáty (doc/xls): přes nainstalovaný Word / Excel ---

function Set-ComVlastnost($Vlastnosti, $Nazev, $Hodnota) {
    $p = [System.__ComObject].InvokeMember('Item', 'GetProperty', $null, $Vlastnosti, @($Nazev))
    [void][System.__ComObject].InvokeMember('Value', 'SetProperty', $null, $p, @($Hodnota))
}

function Set-AutorWord($Cesta) {
    $app = New-Object -ComObject Word.Application
    $puvodniJmeno = $app.UserName
    try {
        $app.Visible = $false
        $app.DisplayAlerts = 0
        # Word při uložení zapíše "Naposledy uložil" = UserName, proto ho dočasně změníme
        if ($ZmenitNaposledyUlozil) { $app.UserName = $Autor }
        $doc = $app.Documents.Open($Cesta, $false, $false, $false)
        Set-ComVlastnost $doc.BuiltInDocumentProperties 'Author' $Autor
        $doc.Saved = $false
        $doc.Save()
        $doc.Close()
    } finally {
        $app.UserName = $puvodniJmeno
        $app.Quit()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    }
}

function Set-AutorExcel($Cesta) {
    $app = New-Object -ComObject Excel.Application
    $puvodniJmeno = $app.UserName
    try {
        $app.Visible = $false
        $app.DisplayAlerts = $false
        if ($ZmenitNaposledyUlozil) { $app.UserName = $Autor }
        $wb = $app.Workbooks.Open($Cesta)
        Set-ComVlastnost $wb.BuiltinDocumentProperties 'Author' $Autor
        $wb.Save()
        $wb.Close($false)
    } finally {
        $app.UserName = $puvodniJmeno
        $app.Quit()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($app)
    }
}

# --- hlavní část ---

if ($args.Count -eq 0) {
    Write-Host "Pretahni Word/Excel soubory (nebo slozku) na zmen-autora.bat"
    Read-Host "Stiskni Enter"
    exit
}

$soubory = foreach ($a in $args) {
    if (Test-Path -LiteralPath $a -PathType Container) {
        Get-ChildItem -LiteralPath $a -Recurse -File |
            Where-Object { $VsechnyPripony -contains $_.Extension.ToLower() -and -not $_.Name.StartsWith('~$') }
    } elseif (Test-Path -LiteralPath $a -PathType Leaf) {
        Get-Item -LiteralPath $a
    } else {
        Write-Host "NENALEZENO  $a" -ForegroundColor Yellow
    }
}

Write-Host "Novy autor: $Autor`n"

foreach ($f in $soubory) {
    $ext = $f.Extension.ToLower()
    try {
        if     ($PriponyOoxml -contains $ext) { Set-AutorOoxml $f.FullName }
        elseif ($PriponyWord  -contains $ext) { Set-AutorWord  $f.FullName }
        elseif ($PriponyExcel -contains $ext) { Set-AutorExcel $f.FullName }
        else {
            Write-Host "PRESKOCENO $($f.Name) (nepodporovany typ)" -ForegroundColor Yellow
            continue
        }
        Write-Host "OK          $($f.Name)" -ForegroundColor Green
    } catch {
        Write-Host "CHYBA       $($f.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Read-Host "Hotovo. Stiskni Enter"
