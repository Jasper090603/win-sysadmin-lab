<#
.SYNOPSIS
    Shared helper functions for the JSLab scripts. Dot-source it:  . "$PSScriptRoot\..\common\LabHelpers.ps1"
#>

function New-LabPassword {
    <# Random password with at least one upper, lower, digit and symbol (meets AD complexity rules). #>
    param([ValidateRange(12, 64)][int]$Length = 16)

    $sets  = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*-_=+?')
    $all   = -join $sets
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 4

    $pick = {
        param([string]$Set)
        $rng.GetBytes($bytes)
        $Set[[int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$Set.Length)]
    }

    $chars = New-Object 'System.Collections.Generic.List[char]'
    foreach ($s in $sets) { $chars.Add((& $pick $s)) }
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

    # Fisher-Yates shuffle so the guaranteed characters are not always first
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $rng.GetBytes($bytes)
        $j = [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]($i + 1))
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function ConvertTo-LabSamAccountName {
    <# First initial + last name, lowercase, letters only, max 20 characters (e.g. Maya Chen -> mchen). #>
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName
    )
    $first = ($FirstName -replace '[^a-zA-Z]', '').ToLower()
    $last  = ($LastName  -replace '[^a-zA-Z]', '').ToLower()
    if (-not $first -or -not $last) { throw "Cannot build a username from '$FirstName $LastName'" }
    $sam = $first.Substring(0, 1) + $last
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
    $sam
}

function Test-LabSamFormat {
    <# Guards AD -Filter strings against odd input from CSV files. #>
    param([string]$Sam)
    -not [string]::IsNullOrWhiteSpace($Sam) -and $Sam -match '^[a-zA-Z0-9._-]{1,20}$'
}
