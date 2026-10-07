Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppDir = $PSScriptRoot
$AppScript = $PSCommandPath
$PackageDir = Split-Path -Parent $AppDir
$ThumbDir = Join-Path $AppDir "thumbs"
$SettingsDir = Join-Path $env:APPDATA "JACKSwitcher"
$SavedPathFile = Join-Path $SettingsDir "tf2path.txt"


function Show-Message($text, $icon = "Information") {
    [System.Windows.Forms.MessageBox]::Show($text, "JACK Switcher", "OK", $icon) | Out-Null
}

function Test-TF2Running {
    return [bool](Get-Process -Name "tf_win64", "tf", "hl2" -ErrorAction SilentlyContinue)
}

function Test-TF2Folder($folder) {
    return ($folder -and (Test-Path (Join-Path $folder "tf\gameinfo.txt")))
}

function Get-SteamLibraries {
    $libraries = New-Object System.Collections.Generic.List[string]

    foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam") {
        $steam = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($steam.SteamPath) { $libraries.Add($steam.SteamPath.Replace("/", "\")) }
        if ($steam.InstallPath) { $libraries.Add($steam.InstallPath) }
    }

    foreach ($steamFolder in @($libraries)) {
        $libraryFile = Join-Path $steamFolder "steamapps\libraryfolders.vdf"
        if (-not (Test-Path $libraryFile)) { continue }
        $found = [regex]::Matches((Get-Content $libraryFile -Raw), '"path"\s+"([^"]+)"')
        foreach ($match in $found) { $libraries.Add($match.Groups[1].Value.Replace("\\", "\")) }
    }

    $libraries.Add("C:\Program Files (x86)\Steam")
    return $libraries
}

function Select-TF2Folder {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = "Couldn't find Team Fortress 2. Select your 'Team Fortress 2' folder (the one with the 'tf' folder inside)."

    while ($picker.ShowDialog() -eq "OK") {
        if (Test-TF2Folder $picker.SelectedPath) {
            New-Item -ItemType Directory -Force $SettingsDir | Out-Null
            Set-Content -Path $SavedPathFile -Value $picker.SelectedPath
            return $picker.SelectedPath
        }
        Show-Message "That folder doesn't have tf\gameinfo.txt in it. Pick the 'Team Fortress 2' folder." "Warning"
    }
    return $null
}

function Find-TF2 {
    if (Test-Path $SavedPathFile) {
        $saved = (Get-Content $SavedPathFile -Raw).Trim()
        if (Test-TF2Folder $saved) { return $saved }
    }

    foreach ($library in Get-SteamLibraries) {
        $folder = Join-Path $library "steamapps\common\Team Fortress 2"
        if (Test-TF2Folder $folder) { return $folder }
    }

    return Select-TF2Folder
}


$TF2Folder = Find-TF2
if (-not $TF2Folder) { exit }
$CustomFolder = Join-Path $TF2Folder "tf\custom"
New-Item -ItemType Directory -Force $CustomFolder | Out-Null


$Categories = [ordered]@{
    jack  = @{ Title = "JACK Skins"; Folder = Join-Path $PackageDir "vpks";       FilePrefix = "jack_";     DefaultName = "Normal JACK";       Toggle = $false }
    xhair = @{ Title = "Crosshairs"; Folder = Join-Path $PackageDir "crosshairs"; FilePrefix = "pt_xhair_"; DefaultName = "Default Crosshair"; Toggle = $false }
    icon  = @{ Title = "Icons";      Folder = Join-Path $PackageDir "icons";      FilePrefix = "pt_icon_";  DefaultName = "Default Icons";     Toggle = $false }
    sound = @{ Title = "Sounds";     Folder = Join-Path $PackageDir "sounds";     FilePrefix = "pt_sound_"; DefaultName = "Default Sounds";    Toggle = $false }
    extra = @{ Title = "Extras";     Folder = Join-Path $PackageDir "extras";     FilePrefix = "extra_";    DefaultName = $null;               Toggle = $true }
}

$CustomItemsDir = Join-Path $SettingsDir "custom"
$CustomListFile = Join-Path $CustomItemsDir "custom.txt"
$Items = New-Object System.Collections.Generic.List[hashtable]

function Read-ItemList($listFile, $customFolder) {
    if (-not (Test-Path $listFile)) { return }
    foreach ($line in Get-Content $listFile) {
        if (-not $line.Trim()) { continue }
        $category, $group, $name, $file, $thumb = $line.Split("|")
        if (-not $file) { $file = $null }
        $folder = if ($customFolder) { $customFolder } else { $Categories[$category].Folder }
        $Items.Add(@{ Category = $category; Group = $group; Name = $name; File = $file; Thumb = $thumb; Folder = $folder; IsCustom = [bool]$customFolder })
    }
}

Read-ItemList (Join-Path $AppDir "items.txt") $null
Read-ItemList $CustomListFile $CustomItemsDir


function Get-InstalledFiles($category) {
    $prefix = $Categories[$category].FilePrefix
    return @(Get-ChildItem -Path $CustomFolder -Filter "$prefix*.vpk" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

function Get-InstalledName($category) {
    $installedFiles = Get-InstalledFiles $category
    if ($installedFiles.Count -eq 0) { return $Categories[$category].DefaultName }

    foreach ($item in $Items) {
        if ($item.Category -eq $category -and $item.File -and ($installedFiles -contains $item.File)) { return $item.Name }
    }
    return "Unknown"
}

function Install-Item($item) {
    if (Test-TF2Running) {
        Show-Message "Close TF2 first. TF2 only loads custom files when it starts, and it locks them while it's open." "Warning"
        return
    }

    $category = $Categories[$item.Category]
    try {
        if ($category.Toggle) {
            if (Test-Installed $item) { Remove-InstalledFile $item.File } else { Copy-ToCustom $item }
            return
        }
        foreach ($file in Get-InstalledFiles $item.Category) { Remove-InstalledFile $file }
        if ($item.File) { Copy-ToCustom $item }
    } catch {
        Show-Message "Couldn't switch: $($_.Exception.Message)" "Error"
    }
}

function Test-Installed($item) {
    return ($item.File -and (Test-Path (Join-Path $CustomFolder $item.File)))
}

function Remove-InstalledFile($file) {
    Remove-Item -Path (Join-Path $CustomFolder $file) -Force -ErrorAction Stop
    Remove-Item -Path (Join-Path $CustomFolder "$file.sound.cache") -Force -ErrorAction SilentlyContinue
}

function Copy-ToCustom($item) {
    Copy-Item -Path (Join-Path $item.Folder $item.File) -Destination $CustomFolder -Force -ErrorAction Stop
}

function Get-SafeFileName($name) {
    $safe = ($name.ToLower() -replace "[^a-z0-9]+", "_").Trim("_")
    if (-not $safe) { $safe = "item" }
    return $safe
}

function Add-CustomItem($sourceFile, $category, $name) {
    $prefix = $Categories[$category].FilePrefix
    $base = "$($prefix)custom_$(Get-SafeFileName $name)"
    $file = "$base.vpk"
    $n = 2
    while (Test-Path (Join-Path $CustomItemsDir $file)) {
        $file = "$($base)_$n.vpk"
        $n++
    }

    $existingNames = @($Items | Where-Object { $_.Category -eq $category } | ForEach-Object { $_.Name })
    while ($existingNames -contains $name) { $name = "$name (custom)" }

    New-Item -ItemType Directory -Force $CustomItemsDir | Out-Null
    Copy-Item -Path $sourceFile -Destination (Join-Path $CustomItemsDir $file) -ErrorAction Stop
    Add-Content -Path $CustomListFile -Value "$category|Custom|$name|$file|custom"

    $item = @{ Category = $category; Group = "Custom"; Name = $name; File = $file; Thumb = "custom"; Folder = $CustomItemsDir; IsCustom = $true }
    $Items.Add($item)
    return $item
}

function Remove-CustomItem($item) {
    if (Test-Installed $item) { Remove-InstalledFile $item.File }
    Remove-Item -Path (Join-Path $CustomItemsDir $item.File) -Force -ErrorAction SilentlyContinue
    $kept = @(Get-Content $CustomListFile | Where-Object { $_.Split("|")[3] -ne $item.File })
    Set-Content -Path $CustomListFile -Value $kept
    [void]$Items.Remove($item)
}

function New-DesktopShortcut {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $desktop "JACK Switcher.lnk"))
    $link.TargetPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppScript`""
    $link.WorkingDirectory = $AppDir
    $link.IconLocation = (Join-Path $AppDir "icon.ico") + ",0"
    $link.WindowStyle = 7
    $link.Save()
    Show-Message "Shortcut added to your desktop."
}


$Colors = @{
    Background = [System.Drawing.Color]::FromArgb(30, 31, 38)
    Card       = [System.Drawing.Color]::FromArgb(45, 47, 58)
    CardHover  = [System.Drawing.Color]::FromArgb(62, 65, 80)
    Accent     = [System.Drawing.Color]::FromArgb(207, 115, 54)
    Text       = [System.Drawing.Color]::FromArgb(235, 232, 225)
    DimText    = [System.Drawing.Color]::FromArgb(150, 150, 160)
    Warning    = [System.Drawing.Color]::FromArgb(230, 170, 90)
    White      = [System.Drawing.Color]::White
}

function New-Font($size, [switch]$Bold) {
    $family = if ($Bold) { "Segoe UI Semibold" } else { "Segoe UI" }
    return New-Object System.Drawing.Font($family, $size)
}

function New-Label($text, $x, $y, $size, $color, [switch]$Bold) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.Font = New-Font $size -Bold:$Bold
    $label.ForeColor = $color
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point($x, $y)
    return $label
}

function New-FlatButton($text, $x, $y, $width, $height, $backColor, $textColor) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $text
    $button.FlatStyle = "Flat"
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $backColor
    $button.ForeColor = $textColor
    $button.Font = New-Font 10.5 -Bold
    $button.Size = New-Object System.Drawing.Size($width, $height)
    $button.Location = New-Object System.Drawing.Point($x, $y)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $button
}

function New-GroupHeader($text) {
    $header = New-Object System.Windows.Forms.Label
    $header.Text = $text
    $header.ForeColor = $Colors.Accent
    $header.Font = New-Font 13 -Bold
    $header.Size = New-Object System.Drawing.Size(800, 34)
    $header.TextAlign = "BottomLeft"
    $header.Margin = New-Object System.Windows.Forms.Padding(6, 8, 6, 0)
    return $header
}

function Get-CardFor($control) {
    while (-not ($control.Tag -is [hashtable])) { $control = $control.Parent }
    return $control
}

function New-ItemCard($item) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object System.Drawing.Size(150, 178)
    $card.Margin = New-Object System.Windows.Forms.Padding(6)
    $card.BackColor = $Colors.Card
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Tag = @{ Item = $item; Selected = $false }

    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Size = New-Object System.Drawing.Size(134, 134)
    $picture.Location = New-Object System.Drawing.Point(8, 8)
    $picture.SizeMode = "Zoom"
    $picture.BackColor = [System.Drawing.Color]::Transparent
    $thumbFile = Join-Path $ThumbDir "$($item.Thumb).png"
    if (Test-Path $thumbFile) {
        $imageBytes = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($thumbFile))
        $picture.Image = [System.Drawing.Image]::FromStream($imageBytes)
    }

    $name = New-Object System.Windows.Forms.Label
    $name.Text = $item.Name
    $name.ForeColor = $Colors.Text
    $name.Font = New-Font 10 -Bold
    $name.TextAlign = "MiddleCenter"
    $name.Size = New-Object System.Drawing.Size(150, 30)
    $name.Location = New-Object System.Drawing.Point(0, 144)
    $name.BackColor = [System.Drawing.Color]::Transparent

    $card.Controls.Add($picture)
    $card.Controls.Add($name)

    foreach ($control in @($card, $picture, $name)) {
        $control.Add_Click({ param($sender) Install-Item (Get-CardFor $sender).Tag.Item; Update-Window })
        $control.Add_MouseEnter({ param($sender) Set-CardHover (Get-CardFor $sender) $true })
        $control.Add_MouseLeave({ param($sender) Set-CardHover (Get-CardFor $sender) $false })
    }
    return $card
}

function Set-CardHover($card, $hovering) {
    if ($card.Tag.Selected) { return }
    $card.BackColor = if ($hovering) { $Colors.CardHover } else { $Colors.Card }
}

function Add-CardToPage($item) {
    $page = $tabPages[$item.Category]
    if ($lastGroup[$item.Category] -ne $item.Group) {
        $page.Controls.Add((New-GroupHeader $item.Group))
        $lastGroup[$item.Category] = $item.Group
    }
    $card = New-ItemCard $item
    if ($item.IsCustom) {
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $remove = $menu.Items.Add("Remove from menu")
        $remove.Tag = $card
        $remove.Add_Click({ param($sender) Remove-CustomCard $sender.Tag })
        foreach ($control in @($card) + @($card.Controls)) { $control.ContextMenuStrip = $menu }
    }
    $page.Controls.Add($card)
    $cards.Add($card)
}

function Remove-CustomCard($card) {
    if (Test-TF2Running) {
        Show-Message "Close TF2 first." "Warning"
        return
    }
    $item = $card.Tag.Item
    Remove-CustomItem $item
    $page = $tabPages[$item.Category]
    $page.Controls.Remove($card)
    [void]$cards.Remove($card)

    $customLeft = @($Items | Where-Object { $_.Category -eq $item.Category -and $_.IsCustom }).Count
    if ($customLeft -eq 0) {
        $header = $page.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -eq "Custom" } | Select-Object -First 1
        if ($header) { $page.Controls.Remove($header) }
        $lastGroup[$item.Category] = $null
    }
    Update-Window
}

function Show-AddCustomDialog($defaultName) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Add Custom"
    $dialog.BackColor = $Colors.Background
    $dialog.ForeColor = $Colors.Text
    $dialog.Font = New-Font 10
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.StartPosition = "CenterParent"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(380, 190)

    $dialog.Controls.Add((New-Label "Name" 20 18 10 $Colors.Text))
    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Text = $defaultName
    $nameBox.Location = New-Object System.Drawing.Point(20, 42)
    $nameBox.Size = New-Object System.Drawing.Size(340, 26)
    $dialog.Controls.Add($nameBox)

    $dialog.Controls.Add((New-Label "Goes in" 20 78 10 $Colors.Text))
    $categoryBox = New-Object System.Windows.Forms.ComboBox
    $categoryBox.DropDownStyle = "DropDownList"
    $categoryBox.Location = New-Object System.Drawing.Point(20, 102)
    $categoryBox.Size = New-Object System.Drawing.Size(340, 26)
    foreach ($key in $Categories.Keys) { [void]$categoryBox.Items.Add($Categories[$key].Title) }
    $categoryBox.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($Categories.Keys), $currentTab))
    $dialog.Controls.Add($categoryBox)

    $ok = New-FlatButton "Add" 170 144 90 34 $Colors.Accent $Colors.White
    $ok.DialogResult = "OK"
    $cancel = New-FlatButton "Cancel" 270 144 90 34 $Colors.Card $Colors.Text
    $cancel.DialogResult = "Cancel"
    $dialog.Controls.Add($ok)
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    if ($dialog.ShowDialog($window) -ne "OK" -or -not $nameBox.Text.Trim()) { return $null }
    return @{ Category = @($Categories.Keys)[$categoryBox.SelectedIndex]; Name = $nameBox.Text.Trim() }
}

function Start-AddCustom {
    $picker = New-Object System.Windows.Forms.OpenFileDialog
    $picker.Title = "Pick a .vpk to add"
    $picker.Filter = "VPK files (*.vpk)|*.vpk"
    if ($picker.ShowDialog($window) -ne "OK") { return }

    $choice = Show-AddCustomDialog ([IO.Path]::GetFileNameWithoutExtension($picker.FileName))
    if (-not $choice) { return }

    try {
        $item = Add-CustomItem $picker.FileName $choice.Category $choice.Name
        Add-CardToPage $item
        Show-Tab $choice.Category
        Update-Window
    } catch {
        Show-Message "Couldn't add it: $($_.Exception.Message)" "Error"
    }
}


$window = New-Object System.Windows.Forms.Form
$window.Text = "JACK Switcher"
$window.BackColor = $Colors.Background
$window.ForeColor = $Colors.Text
$window.StartPosition = "CenterScreen"
$window.FormBorderStyle = "FixedSingle"
$window.MaximizeBox = $false
$window.ClientSize = New-Object System.Drawing.Size(860, 770)
$window.Font = New-Font 9.5

$window.Controls.Add((New-Label "PASS Time Switcher" 20 14 17 $Colors.Text -Bold))
$statusLabel = New-Label "" 23 52 10 $Colors.DimText
$window.Controls.Add($statusLabel)
$warningLabel = New-Label "" 480 22 10 $Colors.Warning -Bold
$window.Controls.Add($warningLabel)

$tabButtons = @{}
$tabPages = @{}
$tabX = 20
foreach ($category in $Categories.Keys) {
    $button = New-FlatButton $Categories[$category].Title $tabX 82 150 36 $Colors.Card $Colors.DimText
    $button.Tag = $category
    $button.Add_Click({ param($sender) Show-Tab $sender.Tag })
    $window.Controls.Add($button)
    $tabButtons[$category] = $button
    $tabX += 156

    $page = New-Object System.Windows.Forms.FlowLayoutPanel
    $page.Location = New-Object System.Drawing.Point(14, 124)
    $page.Size = New-Object System.Drawing.Size(832, 580)
    $page.AutoScroll = $true
    $page.BackColor = $Colors.Background
    $window.Controls.Add($page)
    $tabPages[$category] = $page
}

$cards = New-Object System.Collections.Generic.List[object]
$lastGroup = @{}
foreach ($item in @($Items)) {
    if ($item.File -and -not (Test-Path (Join-Path $item.Folder $item.File))) { continue }
    Add-CardToPage $item
}

$addCustomButton = New-FlatButton "Add Custom..." 340 716 160 40 $Colors.Card $Colors.Text
$addCustomButton.Add_Click({ Start-AddCustom })
$window.Controls.Add($addCustomButton)

$launchButton = New-FlatButton "Launch TF2" 686 716 160 40 $Colors.Accent $Colors.White
$launchButton.Add_Click({ Start-Process "steam://rungameid/440" })
$window.Controls.Add($launchButton)

$shortcutButton = New-FlatButton "Add Desktop Shortcut" 508 716 170 40 $Colors.Card $Colors.Text
$shortcutButton.Add_Click({ New-DesktopShortcut })
$window.Controls.Add($shortcutButton)

$window.Controls.Add((New-Label "Pick one of each, Extras are on/off switches.`nRestart TF2 after switching.  Test: map pass_brickyard" 20 718 9.5 $Colors.DimText))


function Show-Tab($category) {
    $script:currentTab = $category
    foreach ($key in $tabPages.Keys) {
        $isActive = ($key -eq $category)
        $tabPages[$key].Visible = $isActive
        $tabButtons[$key].BackColor = if ($isActive) { $Colors.Accent } else { $Colors.Card }
        $tabButtons[$key].ForeColor = if ($isActive) { $Colors.White } else { $Colors.DimText }
    }
}

function Update-Window {
    $installed = @{}
    foreach ($category in $Categories.Keys) {
        if (-not $Categories[$category].Toggle) { $installed[$category] = Get-InstalledName $category }
    }
    $extrasOn = @(Get-InstalledFiles "extra").Count

    $statusLabel.Text = "JACK: $($installed.jack)   |   Crosshair: $($installed.xhair)   |   Icons: $($installed.icon)   |   Sounds: $($installed.sound)   |   Extras on: $extrasOn"
    $warningLabel.Text = if (Test-TF2Running) { "TF2 is running - close it before switching" } else { "" }

    foreach ($card in $cards) {
        $item = $card.Tag.Item
        if ($Categories[$item.Category].Toggle) {
            $card.Tag.Selected = Test-Installed $item
        } else {
            $card.Tag.Selected = ($item.Name -eq $installed[$item.Category])
        }
        $card.BackColor = if ($card.Tag.Selected) { $Colors.Accent } else { $Colors.Card }
    }
}


$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 2000
$refreshTimer.Add_Tick({ Update-Window })
$refreshTimer.Start()

Show-Tab "jack"
Update-Window
[void]$window.ShowDialog()
