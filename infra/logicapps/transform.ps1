#requires -Version 7
# Transform HTTP-Matter-On-Email-Receipt: remove SharePoint site/library work,
# keep blob archiving + matter lookups, fix correctness bugs, add peek-lock durability.
param(
  [string]$InPath  = "C:\Development\REPO\RSE-Law\infra\logicapps\HTTP-Matter-On-Email-Receipt.before.json",
  [string]$OutPath = "C:\Development\REPO\RSE-Law\infra\logicapps\HTTP-Matter-On-Email-Receipt.after.json",
  # Regenerate even though the live workflow has been edited outside this repo.
  # Only correct once whatever changed live is also expressed below.
  [switch]$AcceptDrift,
  # Skip the drift check entirely - for working with no Azure access.
  [switch]$NoDriftCheck,
  [string]$BaselinePath = "$PSScriptRoot\deployed.json"
)
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ guard
# This script regenerates after.json from a frozen snapshot plus the edits below.
# If someone changed the live workflow in the portal, that change exists in neither,
# so overwriting after.json here is the first step in silently reverting it - the
# concurrency 100-vs-40 drift is exactly this. deploy.ps1 blocks the PUT, but by then
# the generated file already disagrees with live and the reason is easy to miss.
# Stop at the source instead.
# dot-sourced unconditionally: it only defines functions, and Sort-JsonKeys is needed
# on the emit path even when the drift check is skipped
. "$PSScriptRoot\drift.ps1"
if (-not $NoDriftCheck) {
  $guard = Test-WorkflowDrift -BaselinePath $BaselinePath
  if (-not $guard.Checked) {
    Write-Warning "drift not checked - $($guard.Reason). Regenerating anyway; verify with ./deploy.ps1 before deploying."
  } elseif ($guard.Drift.Count -gt 0) {
    Write-Host "DRIFT - the live workflow differs from the last deployed baseline in $($guard.Drift.Count) place(s):" -ForegroundColor Yellow
    $guard.Drift | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    if (-not $AcceptDrift) {
      throw "refusing to regenerate $([IO.Path]::GetFileName($OutPath)) while live has drifted. " +
            "Express the live change in this script first, or re-run with -AcceptDrift to discard it."
    }
    Write-Warning '-AcceptDrift given: the live-only changes above will be discarded on the next deploy.'
  }
}

$res = Get-Content $InPath -Raw | ConvertFrom-Json -AsHashtable
$def = $res.properties.definition
$Q   = "'speventgridqueue'"
$SB  = @{ connection = @{ name = '@parameters(''$connections'')[''servicebus''][''connectionId'']' } }
$BLOB= @{ connection = @{ name = '@parameters(''$connections'')[''azureblob-1''][''connectionId'']' } }
$SP  = @{ connection = @{ name = '@parameters(''$connections'')[''sharepointonline''][''connectionId'']' } }

function San([string]$expr) {
  # strip \ / : * ? " < > | -> _   (same chain Create_blob_1 already used)
  $c = $expr
  foreach ($ch in @('\','/',':','*','?','"','<','>','|')) { $c = "replace($c, '$ch', '_')" }
  # Real subjects arrive with tabs and newlines in them - a forwarded header block
  # pasted into the subject line. The blob connector rejects those with
  # 400 InvalidUri, and since the name is deterministic the message then fails
  # identically on all 10 redeliveries and dead-letters unarchived.
  #
  # Blob storage rejects the whole C0 range and DEL, not only the tab/CR/LF actually
  # observed, so cover all of it rather than wait for the next variant to strand mail.
  # Written as %XX escapes so the emitted definition stays printable ASCII - the
  # control character only ever exists at runtime.
  foreach ($n in @(0..31) + 127) { $c = "replace($c, decodeUriComponent('%{0:X2}'), '_')" -f $n }
  $c
}

# ---------------------------------------------------------------- 1. TRIGGER
$def.triggers = @{
  'When_a_message_is_received_in_a_queue_(peek-lock)' = @{
    type       = 'ApiConnection'
    recurrence = @{ frequency = 'Minute'; interval = 1 }
    # Measured on a ~2,700-message sweep batch: 40 -> ~147 msg/min, 100 -> ~330 msg/min.
    # 100 costs ~1.2% of runs a lost peek-lock (Service Bus caps lockDuration at
    # PT5M and the slowest runs exceed it under that much parallelism). Those
    # messages redeliver and re-archive to the same deterministic blob name, so the
    # cost is repeated work, not lost mail - worth it for 2.2x throughput.
    runtimeConfiguration = @{ concurrency = @{ runs = 100 } }
    inputs     = @{
      host    = $SB
      method  = 'get'
      path    = "/@{encodeURIComponent(encodeURIComponent($Q))}/messages/head/peek"
      queries = @{ queueType = 'Main' }
    }
  }
}

# ------------------------------------------------- 2. INNER: blob-only branch
$root = $def.actions
$odata = $root.If_Odata_ID_is_valid.actions
$notEmpty = $odata.Not_empty_subject.actions
$found = $notEmpty.If_BlnFoundItem_and_not_calendar

# calendar guard: coalesce so a null From/To no longer throws InvalidTemplate
$found.expression = @{
  and = @(
    @{ equals = @('@variables(''blnFoundItem'')', '@true') }
    # guard the blob path: an empty matter would write everything to /matters//Emails/
    @{ equals = @('@empty(trim(coalesce(variables(''strFoundMatter''),'''')))', '@false') }
    @{ not = @{ contains = @('@toUpper(coalesce(outputs(''Get_Email_From''),''''))', 'CALENDAR') } }
    @{ not = @{ contains = @('@toUpper(coalesce(outputs(''Get_Email_To''),''''))',   'CALENDAR') } }
  )
}

# Collapse the two duplicate branches (site-exists / new-site) into one blob path.
# Kept: the sanitised .eml write and the attachment loop. Dropped: their byte-identical twins.
# cap the stem so a very long subject / attachment name cannot exceed the blob name limit,
# which would otherwise make that email permanently unarchivable
function Cap([string]$e, [int]$n) { "if(greater(length($e), $n), substring($e, 0, $n), $e)" }
# last $n characters - the distinguishing end of a Graph message id
function Tail([string]$e, [int]$n) { "if(greater(length($e), $n), substring($e, sub(length($e), $n), $n), $e)" }
# Cap inlines its argument three times, so the 42-replace sanitising chain is composed
# once into its own action and capped by reference. Inlining it would emit ~126 nested
# replace() calls per name and make the definition unreadable for no benefit.
# trim last: capping at 180 can itself leave trailing whitespace on the stem
$emlStem = "trim(" + (Cap "outputs('Email_Subject_Clean')" 150) + ")"
$attStem = "trim(" + (Cap "outputs('Attachment_Name_Clean')" 180) + ")"

<#
The blob name must be unique per MESSAGE, not per subject.

Naming by subject alone meant every reply in a thread wrote to the same path and
silently overwrote the one before it. Measured on matter 120.058: 53 stored files
representing 16 actual conversations, and the surviving copies quote threads 30
messages deep. That is why the search web part returned far fewer results than the
matters mailbox - the mailbox has one entry per message, the archive had one per
subject line.

The suffix is the tail of the Graph message id, which is the part that varies between
messages in a mailbox. Deterministic per message on purpose: the same message always
lands on the same blob, so re-running the sweep or replaying the dead-letter queue
still overwrites rather than duplicates - the property the recovery scripts rely on.

Versioning cannot backstop this. The storage account has hierarchical namespace
enabled, so Azure blob versioning is unavailable on it ("FeatureNotSupportedForAccount").
Uniqueness in the name is the only protection there is.

The subject cap drops 180 -> 150 so names stay about the length they were.
#>
# Case is preserved deliberately. The id is base64, where case carries information, and
# blob names are case-sensitive - lowercasing it would throw away entropy for tidiness.
# Only the three characters that are awkward in a name are swapped out.
$idTail = "replace(replace(replace(" + (Tail "coalesce(outputs('Get_Message_ID'),'')" 24) + ", '/', '_'), '+', '-'), '=', '')"

$found.actions = @{
  Email_Subject_Clean = @{
    type = 'Compose'
    runAfter = @{}
    inputs = "@" + (San "outputs('Get_Email_Subject')")
  }
  Email_Blob_Name = @{
    type = 'Compose'
    runAfter = @{ Email_Subject_Clean = @('Succeeded') }
    inputs = "@concat($emlStem, ' [', $idTail, '].eml')"
  }
  HTTP_Graph_API_Call_to_Get_Email_Message_Value = @{
    type = 'Http'
    runAfter = @{ Email_Blob_Name = @('Succeeded') }
    runtimeConfiguration = @{ contentTransfer = @{ transferMode = 'Chunked' } }
    inputs = @{
      method = 'GET'
      uri    = 'https://graph.microsoft.com/v1.0/@{outputs(''Get_OData_ID'')}/$value'
      authentication = @{ type = 'ManagedServiceIdentity'; audience = 'https://graph.microsoft.com' }
    }
  }
  Create_blob_1 = @{
    type = 'ApiConnection'
    runAfter = @{ HTTP_Graph_API_Call_to_Get_Email_Message_Value = @('Succeeded') }
    inputs = @{
      host = $BLOB
      method = 'post'
      path = "/v2/datasets/@{encodeURIComponent(encodeURIComponent('samatters'))}/files"
      body = "@body('HTTP_Graph_API_Call_to_Get_Email_Message_Value')"
      queries = @{
        folderPath = "/matters/@{variables('strFoundMatter')}/Emails/"
        name       = "@outputs('Email_Blob_Name')"
        queryParametersSingleEncoded = $true
      }
    }
  }
  For_each_Attachment_1 = @{
    type = 'Foreach'
    foreach = "@variables('arrAttachments')"
    runAfter = @{ Create_blob_1 = @('Succeeded') }
    runtimeConfiguration = @{ concurrency = @{ repetitions = 4 } }
    actions = @{
      # per-iteration, so this is the current attachment's name even at repetitions 4
      Attachment_Name_Clean = @{
        type = 'Compose'
        runAfter = @{}
        inputs = "@" + (San "item()?['Name']")
      }
      Create_blob_for_Attachment = @{
        type = 'ApiConnection'
        runAfter = @{ Attachment_Name_Clean = @('Succeeded') }
        inputs = @{
          host = $BLOB
          method = 'post'
          path = "/v2/datasets/@{encodeURIComponent(encodeURIComponent('samatters'))}/files"
          body = "@item()?['Content']"
          queries = @{
            folderPath = "/matters/@{variables('strFoundMatter')}/Emails/Attachments/"
            name       = "@$attStem"
            queryParametersSingleEncoded = $true
          }
        }
      }
    }
  }
}

# --------------------------------- 3. matter lookup: one query, deterministic
$regex = $notEmpty.If_Subject_has_Reg_Ex_Match

# NB: filter/select are Logic App ACTIONS (Query / Select), not expression functions.
# Only join/union/take/length/string/greater exist as expressions.
$clauseExpr = "@concat('RSEFileNo eq ''', item(), ''' or CaseNo eq ''', item(), ''' or ClaimNo eq ''', item(), '''')"
$filterExpr = "@join(body('Build_Lookup_Clauses'), ' or ')"

$regex.else = @{ actions = @{
  Split_Subject_into_array = $regex.else.actions.Split_Subject_into_array
  # drop noise words; matter/case/claim numbers are all >2 chars (06.145, 24STCV24941)
  # and the splitter does not break on '.' or '-', so they survive intact
  Filter_Subject_Words = @{
    type = 'Query'
    runAfter = @{ Split_Subject_into_array = @('Succeeded') }
    inputs = @{
      from  = "@outputs('Split_Subject_into_array')"
      where = "@greater(length(string(item())), 2)"
    }
  }
  # union(x, x) is the dedupe idiom; take() caps the OData $filter so it cannot blow the URL limit
  Candidate_Subject_Words = @{
    type = 'Compose'
    runAfter = @{ Filter_Subject_Words = @('Succeeded') }
    inputs = "@take(union(body('Filter_Subject_Words'), body('Filter_Subject_Words')), 20)"
  }
  Build_Lookup_Clauses = @{
    type = 'Select'
    runAfter = @{ Candidate_Subject_Words = @('Succeeded') }
    inputs = @{
      from   = "@outputs('Candidate_Subject_Words')"
      select = $clauseExpr
    }
  }
  Set_variable_blnKeepProcessing = @{
    type = 'SetVariable'
    runAfter = @{ Build_Lookup_Clauses = @('Succeeded') }
    inputs = @{ name = 'blnKeepProcessing'; value = '@true' }
  }
  If_Any_Candidate_Words = @{
    type = 'If'
    runAfter = @{ Set_variable_blnKeepProcessing = @('Succeeded') }
    expression = @{ and = @(@{ not = @{ equals = @("@length(outputs('Candidate_Subject_Words'))", 0) } }) }
    actions = @{
      # ONE SharePoint round trip for the whole subject, replacing one call per word
      Get_items_In_LookUp_List_By_Subject_Word = @{
        type = 'ApiConnection'
        runAfter = @{}
        inputs = @{
          host = $SP
          method = 'get'
          path = "/datasets/@{encodeURIComponent(encodeURIComponent('https://reiszsidermaneisenberg.sharepoint.com/sites/MatterExchange-POC'))}/tables/@{encodeURIComponent(encodeURIComponent('940d4826-7cf4-4bf1-979e-f6d28f4ba1c9'))}/items"
          queries = @{ '$filter' = $filterExpr }
        }
      }
      # sequential, but purely in-memory: first word in SUBJECT order wins => deterministic
      For_each_Subject_Word = @{
        type = 'Foreach'
        foreach = "@outputs('Candidate_Subject_Words')"
        runAfter = @{ Get_items_In_LookUp_List_By_Subject_Word = @('Succeeded') }
        runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
        actions = @{
          If_blnKeepProcessing = @{
            type = 'If'
            runAfter = @{}
            expression = @{ and = @(@{ equals = @("@variables('blnKeepProcessing')", '@true') }) }
            actions = @{
              Filter_Rows_Matching_Word = @{
                type = 'Query'
                runAfter = @{}
                inputs = @{
                  from = "@body('Get_items_In_LookUp_List_By_Subject_Word')?['value']"
                  where = "@or(or(equals(item()?['RSEFileNo'], items('For_each_Subject_Word')), equals(item()?['CaseNo'], items('For_each_Subject_Word'))), equals(item()?['ClaimNo'], items('For_each_Subject_Word')))"
                }
              }
              If_Item_Found_In_List_and_blnKeepProcessing = @{
                type = 'If'
                runAfter = @{ Filter_Rows_Matching_Word = @('Succeeded') }
                expression = @{ and = @(@{ not = @{ equals = @("@length(body('Filter_Rows_Matching_Word'))", 0) } }) }
                actions = @{
                  Set_variable_blnFoundItem_1 = @{
                    type = 'SetVariable'; runAfter = @{}
                    inputs = @{ name = 'blnFoundItem'; value = '@true' }
                  }
                  Set_variable_strFoundMatter_1 = @{
                    type = 'SetVariable'
                    runAfter = @{ Set_variable_blnFoundItem_1 = @('Succeeded') }
                    inputs = @{ name = 'strFoundMatter'; value = "@first(body('Filter_Rows_Matching_Word'))?['RSEFileNo']" }
                  }
                  Set_variable_blnKeepProcessing_False = @{
                    type = 'SetVariable'
                    runAfter = @{ Set_variable_strFoundMatter_1 = @('Succeeded') }
                    inputs = @{ name = 'blnKeepProcessing'; value = '@false' }
                  }
                }
                else = @{ actions = @{} }
              }
            }
            else = @{ actions = @{} }
          }
        }
      }
    }
    else = @{ actions = @{} }
  }
} }

# ------- 3b. a well-formed matter number is filed even if the list lacks it
# The lookup list is maintained by hand, so it always lags newly opened matters.
# SharePoint is no longer the archive target, and a blob path creates its own
# folder, so the list's remaining job is resolution, not permission. Requiring a
# row meant a subject carrying a perfectly good file number was archived nowhere
# at all - measured 2026-08-08 as 87% of all unfiled mail.
# Spliced into the chain rather than hung off the HTTP call in parallel: an action
# may only reference another that is on its own runAfter path, and ARM rejects the
# definition outright otherwise.
$notEmpty.Get_Reg_Ex_Match_Type = @{
  type = 'Compose'
  runAfter = @{ Get_Reg_Ex_Match_All_Subject = @('Succeeded') }
  inputs = "@body('HTTP_Az_Func_Reg_Matter_Full_Subject_')?['type']"
}
$regex.runAfter = @{ Get_Reg_Ex_Match_Type = @('Succeeded') }
# Only values the function classified as an RSE File No are trusted this way -
# those passed the strict anchored pattern. A Case/Claim number is just an
# external reference and still needs the list to map it onto a matter.
$regex.actions.If_Found_Item_in_List.else = @{ actions = @{
  If_Well_Formed_RSE_No_Not_In_List = @{
    type = 'If'
    runAfter = @{}
    expression = @{ and = @(@{ equals = @("@outputs('Get_Reg_Ex_Match_Type')", 'RSE File No') }) }
    actions = @{
      Set_variable_blnFoundItem_Unlisted = @{
        type = 'SetVariable'; runAfter = @{}
        inputs = @{ name = 'blnFoundItem'; value = '@true' }
      }
      Set_variable_strFoundMatter_Unlisted = @{
        type = 'SetVariable'
        runAfter = @{ Set_variable_blnFoundItem_Unlisted = @('Succeeded') }
        inputs = @{ name = 'strFoundMatter'; value = "@outputs('Get_Reg_Ex_Match_All_Subject')" }
      }
    }
    else = @{ actions = @{} }
  }
} }

# ------------------------------- 4. serialise appends that race on a variable
$odata.For_each_Recipient.runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
$odata.For_each_CC.runtimeConfiguration        = @{ concurrency = @{ repetitions = 1 } }
$odata.If_Has_Attachments.actions.For_each_Attachment.runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }

# ---------------------------------------- 5. Graph calls -> managed identity
$mi = @{ type = 'ManagedServiceIdentity'; audience = 'https://graph.microsoft.com' }
function Use-MI($a) { if ($a) { $a.inputs.Remove('headers') | Out-Null; $a.inputs.authentication = $mi } }
Use-MI $odata.HTTP_Graph_API_Call_to_Get_Email_Message_via_User
Use-MI $odata.If_Has_Attachments.actions.HTTP_Graph_API_Call_to_Get_Email_Message_Attachments
Use-MI $odata.If_Has_Attachments.actions.For_each_Attachment.actions.HTTP_Graph_API_Call_to_Get_Email_Message_Attachment_Content

# drop the swallow-the-error terminate so a Graph failure fails the run (and abandons the message)
$odata.Remove('Compose_Error_Get_Email_via_User_ID') | Out-Null
$odata.Remove('Terminate') | Out-Null

# ------------------------- 6. wrap in a scope; complete / abandon the message
$init = $root.Initialize_variables
$init.inputs.variables = @($init.inputs.variables | Where-Object { $_.name -ne 'strAttachmentURL' })

$scopeActions = @{
  Get_Message_JSON = $root.Get_Message_JSON
  Parse_JSON       = $root.Parse_JSON
  Get_Message_ID   = $root.Get_Message_ID
  Get_OData_ID     = $root.Get_OData_ID
  If_Odata_ID_is_valid = $root.If_Odata_ID_is_valid
}
$scopeActions.Get_Message_JSON.runAfter = @{}
$scopeActions.Get_Message_ID.runAfter   = @{ Parse_JSON = @('Succeeded') }

$def.actions = @{
  Initialize_variables = $init
  Process_Message = @{
    type = 'Scope'
    runAfter = @{ Initialize_variables = @('Succeeded') }
    actions = $scopeActions
  }
  Complete_the_message_in_a_queue = @{
    type = 'ApiConnection'
    runAfter = @{ Process_Message = @('Succeeded') }
    inputs = @{
      host = $SB
      method = 'delete'
      path = "/@{encodeURIComponent(encodeURIComponent($Q))}/messages/complete"
      queries = @{ lockToken = "@triggerBody()?['LockToken']"; queueType = 'Main' }
    }
  }
  # Not every failure deserves a retry. A change notification whose message no
  # longer exists (draft sent, mail moved or deleted) can never succeed, so
  # abandoning it just burns 10 redeliveries and dead-letters a no-op event.
  # Retry real errors; complete the unprocessable ones.
  If_Message_No_Longer_Exists = @{
    type = 'If'
    runAfter = @{ Process_Message = @('Failed','TimedOut') }
    expression = @{ and = @(@{ equals = @(
      "@outputs('HTTP_Graph_API_Call_to_Get_Email_Message_via_User')?['statusCode']", 404) }) }
    actions = @{
      Complete_Stale_Notification = @{
        type = 'ApiConnection'
        runAfter = @{}
        inputs = @{
          host = $SB
          method = 'delete'
          path = "/@{encodeURIComponent(encodeURIComponent($Q))}/messages/complete"
          queries = @{ lockToken = "@triggerBody()?['LockToken']"; queueType = 'Main' }
        }
      }
      # A vanished message is the expected case, not a fault. Without this the run
      # reports Failed and the failure rate stops being a usable health signal;
      # the 404 itself stays visible in this run's action history.
      Terminate_Stale_Handled = @{
        type = 'Terminate'
        runAfter = @{ Complete_Stale_Notification = @('Succeeded') }
        inputs = @{ runStatus = 'Succeeded' }
      }
    }
    else = @{ actions = @{
      Abandon_the_message_in_a_queue = @{
        type = 'ApiConnection'
        runAfter = @{}
        inputs = @{
          host = $SB
          method = 'post'
          path = "/@{encodeURIComponent(encodeURIComponent($Q))}/messages/abandon"
          queries = @{ lockToken = "@triggerBody()?['LockToken']"; queueType = 'Main' }
        }
      }
      Terminate_Failed = @{
        type = 'Terminate'
        runAfter = @{ Abandon_the_message_in_a_queue = @('Succeeded','Failed','TimedOut') }
        inputs = @{ runStatus = 'Failed'; runError = @{ code = 'ProcessingFailed'; message = 'Message processing failed; message abandoned for redelivery.' } }
      }
    } }
  }
}

# ------------------------------------------------- 7. prune dead connections
$keep = @('servicebus','azureblob-1','sharepointonline')
$conns = $res.properties.parameters.'$connections'.value
foreach ($n in @($conns.Keys)) { if ($n -notin $keep) { $conns.Remove($n) | Out-Null } }

# before.json was captured while the workflow was disabled, and a PUT is a full
# replace - carrying that state through silently disables production on deploy.
$res.properties.state = 'Enabled'

# emit definition-only payload for PUT, key-sorted so regenerating is byte-stable and
# the diff shows only what actually changed
Sort-JsonKeys $res | ConvertTo-Json -Depth 100 | Set-Content $OutPath -Encoding utf8
Write-Host "wrote $OutPath"

