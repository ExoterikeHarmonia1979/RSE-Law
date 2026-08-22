#requires -Version 7
<#
Upload the Teams emails that exist nowhere in the blob archive.

Input is teams-only.json - the measured gap from teams-vs-archive.ps1, matched by Message-ID.
Each file is filed under the matter its Team is named for, which is a person's own
classification and more reliable than parsing a subject line.

Naming mirrors the pipeline's own scheme so these blobs are indistinguishable from archived
mail and equally safe to re-run:

    /matters/<matter>/Emails/<sanitised name, capped 150> [<Message-ID tail>].eml

The suffix here is the RFC Message-ID tail rather than a Graph message id - these files came
from SharePoint, not a mailbox, so no Graph id exists. It serves the same purpose: unique per
message, identical on every re-run, so uploading twice overwrites rather than duplicates.

Guards:
  - refuses to run if teams-only.json is missing or larger than the inventory it came from
  - skips any blob path that already exists, so a stale list cannot reintroduce duplicates
  - a file whose Message-ID is empty is skipped, never uploaded under a guessed name

Attachments are ALSO written separately, to
    /matters/<matter>/Emails/Attachments/<sanitised name, capped 180>
which is byte-for-byte the convention Create_blob_for_Attachment uses. Parsing is done with
MimeKit 4.9 - the same library EmlAttachmentNamesSkill uses - loaded from the function's own
build output, so "what counts as an attachment" is decided by the same code as the pipeline:
Content-Disposition: attachment, inline images excluded.

Note the convention it is matching has a known flaw: attachment blob names carry no
uniqueness suffix, so two messages in one matter attaching Invoice.pdf collide. That is the
unfixed defect recorded in the README. This script therefore SKIPS any attachment path that
already exists rather than overwriting - parity on layout, without inheriting the overwrite.

Dry run unless -Execute.
#>
param([switch]$Execute, [int]$Parallel = 12)
$mimeDir = 'C:\Development\REPO\RSE-Law\RegExAzFunc\bin\Debug\net10.0'
$ErrorActionPreference = 'Stop'
$sp   = $PSScriptRoot
$az   = "$env:LOCALAPPDATA\AzureCLI\bin\az.cmd"
$acct = 'https://samatters.blob.core.windows.net/matters/'

$onlyPath = Join-Path $sp 'teams-only.json'
if (-not (Test-Path $onlyPath)) { throw "no teams-only.json - run teams-vs-archive.ps1 first" }
$only = @(Get-Content $onlyPath -Raw | ConvertFrom-Json)
$inv  = @(Get-Content (Join-Path $sp 'teams-inventory.json') -Raw | ConvertFrom-Json)
Write-Host "teams-only : $($only.Count)"
Write-Host "inventory  : $($inv.Count)"
if ($only.Count -eq 0) { Write-Host "nothing to upload - the Teams are fully represented in the archive"; return }
if ($only.Count -gt $inv.Count) { throw "gap ($($only.Count)) exceeds inventory ($($inv.Count)) - list is wrong" }

function San([string]$s) {
  $t = "$s"
  foreach ($c in @('\','/',':','*','?','"','<','>','|')) { $t = $t.Replace($c,'_') }
  $t = [regex]::Replace($t, '[\x00-\x1F\x7F]', '_')
  $t.Trim()
}
function Tail([string]$id) {
  # Use the LOCAL part, before the '@'. A Message-ID looks like
  #   DS4PR10MB997771C349528772DD1ABFC14@DS4PR10MB9977.namprd10.prod.outlook.com
  # so the last 24 characters are the DOMAIN - identical for every message from the same
  # tenant. Taking the tail produced "[amprd10.prod.outlook.com]" on all 662 planned blobs,
  # which would have defeated the entire point of a per-message suffix and reintroduced the
  # same-subject collision this project exists to fix.
  $local = ($id -split '@')[0]
  $t = San $local
  if ($t.Length -gt 24) { $t = $t.Substring($t.Length - 24, 24) }
  $t
}

$plan = @()
foreach ($f in $only) {
  if (-not $f.MessageId) { continue }
  $stem = San ($f.Name -replace '\.eml$','')
  if ($stem.Length -gt 150) { $stem = $stem.Substring(0,150).Trim() }
  $plan += [pscustomobject]@{
    Src = $f; Blob = "$($f.Matter)/Emails/$stem [$(Tail $f.MessageId)].eml"
  }
}
Write-Host "planned uploads: $($plan.Count)  (skipped $($only.Count - $plan.Count) with no Message-ID)"

# The suffix exists to make each blob unique. Prove it does, rather than assume: a bad Tail()
# silently collapsed all 662 names onto one domain suffix and would have overwritten
# same-subject messages inside a matter - the very defect this project set out to fix.
$dupes = @($plan | Group-Object Blob | Where-Object Count -gt 1)
Write-Host "distinct blob paths: $(@($plan | Select-Object -ExpandProperty Blob -Unique).Count) of $($plan.Count)"
if ($dupes.Count -gt 0) {
  $dupes | Select-Object -First 5 | ForEach-Object { Write-Host "  COLLISION x$($_.Count): $($_.Name)" }
  throw "$($dupes.Count) planned paths collide - refusing to upload a set that would overwrite itself"
}
Write-Host ""
$plan | Select-Object -First 5 | ForEach-Object { "  $($_.Blob)" }

if (-not $Execute) { Write-Host "`nDRY RUN - re-run with -Execute"; return }

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(300)
$okC = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
$bad = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

$gtok = (& $az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)
$stok = (& $az account get-access-token --resource https://storage.azure.com     --query accessToken -o tsv)

$plan | ForEach-Object -ThrottleLimit $Parallel -Parallel {
  $p = $_; $cl = $using:client; $g = $using:gtok; $s = $using:stok
  $ok = $using:okC; $errs = $using:bad; $acctUrl = $using:acct
  $blobUrl = $acctUrl + (($p.Blob -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
  try {
    # already there? never overwrite - this list is a gap, not a refresh
    $head = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $blobUrl)
    $head.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $s)
    $head.Headers.Add('x-ms-version','2021-08-06')
    $hr = $cl.SendAsync($head).GetAwaiter().GetResult()
    $exists = ($hr.StatusCode -eq 200); $hr.Dispose(); $head.Dispose()
    if ($exists) { [void]$ok.AddOrUpdate('skip',1,{param($k,$v) $v+1}); return }

    $dl = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get,
            "https://graph.microsoft.com/v1.0/groups/$($p.Src.GroupId)/drive/items/$($p.Src.ItemId)/content")
    $dl.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $g)
    $dr = $cl.SendAsync($dl).GetAwaiter().GetResult()
    if (-not $dr.IsSuccessStatusCode) { $errs.Add("download $($dr.StatusCode) $($p.Blob)"); $dr.Dispose(); $dl.Dispose(); return }
    $bytes = $dr.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $dr.Dispose(); $dl.Dispose()

    $put = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $blobUrl)
    $put.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $s)
    $put.Headers.Add('x-ms-version','2021-08-06')
    $put.Headers.Add('x-ms-blob-type','BlockBlob')
    $put.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
    $pr = $cl.SendAsync($put).GetAwaiter().GetResult()
    if ($pr.StatusCode -eq 201) { [void]$ok.AddOrUpdate('put',1,{param($k,$v) $v+1}) }
    else { $errs.Add("put $($pr.StatusCode) $($p.Blob)") }
    $pr.Dispose(); $put.Dispose()

    # ---- attachments, same convention as Create_blob_for_Attachment
    # Add-Type inside the parallel body: types loaded in the parent runspace are not
    # visible here, so each runspace loads MimeKit itself.
    Add-Type -Path (Join-Path $using:mimeDir 'BouncyCastle.Cryptography.dll') -ErrorAction SilentlyContinue
    Add-Type -Path (Join-Path $using:mimeDir 'MimeKit.dll') -ErrorAction SilentlyContinue
    $ms = [IO.MemoryStream]::new($bytes)
    try {
      $msg = [MimeKit.MimeMessage]::Load($ms)
      foreach ($a in $msg.Attachments) {
        $an = $null
        if ($a.ContentDisposition -and $a.ContentDisposition.FileName) { $an = $a.ContentDisposition.FileName }
        elseif ($a.ContentType -and $a.ContentType.Name) { $an = $a.ContentType.Name }
        if (-not $an) { continue }
        foreach ($ch in @('\','/',':','*','?','"','<','>','|')) { $an = $an.Replace($ch,'_') }
        $an = [regex]::Replace($an, '[\x00-\x1F\x7F]', '_').Trim()
        if ($an.Length -gt 180) { $an = $an.Substring(0,180).Trim() }
        if (-not $an) { continue }

        $aPath = "$($p.Src.Matter)/Emails/Attachments/$an"
        $aUrl  = $acctUrl + (($aPath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
        $ah = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $aUrl)
        $ah.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $s)
        $ah.Headers.Add('x-ms-version','2021-08-06')
        $ahr = $cl.SendAsync($ah).GetAwaiter().GetResult()
        $aExists = ($ahr.StatusCode -eq 200); $ahr.Dispose(); $ah.Dispose()
        # names carry no uniqueness suffix, so never overwrite - see header
        if ($aExists) { [void]$ok.AddOrUpdate('attSkip',1,{param($k,$v) $v+1}); continue }

        $mem = [IO.MemoryStream]::new()
        if ($a -is [MimeKit.MimePart]) { $a.Content.DecodeTo($mem) } else { $a.WriteTo($mem) }
        $ab = $mem.ToArray(); $mem.Dispose()

        $ap = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $aUrl)
        $ap.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $s)
        $ap.Headers.Add('x-ms-version','2021-08-06')
        $ap.Headers.Add('x-ms-blob-type','BlockBlob')
        $ap.Content = [System.Net.Http.ByteArrayContent]::new($ab)
        $apr = $cl.SendAsync($ap).GetAwaiter().GetResult()
        if ($apr.StatusCode -eq 201) { [void]$ok.AddOrUpdate('attPut',1,{param($k,$v) $v+1}) }
        else { $errs.Add("attPut $($apr.StatusCode) $aPath") }
        $apr.Dispose(); $ap.Dispose()
      }
    } catch { $errs.Add("MIME $($p.Blob) :: $($_.Exception.Message)") }
    finally { $ms.Dispose() }
  } catch { $errs.Add("EX $($p.Blob) :: $($_.Exception.Message)") }
}
$client.Dispose()

Write-Host ""
Write-Host "emails uploaded      : $($okC['put'])"
Write-Host "emails already there : $($okC['skip'])"
Write-Host "attachments uploaded : $($okC['attPut'])"
Write-Host "attachments skipped  : $($okC['attSkip'])   (name already taken - see header)"
Write-Host "failed               : $($bad.Count)"
$bad | Set-Content (Join-Path $sp 'upload-failures.txt')
if ($bad.Count) { $bad | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" } }

