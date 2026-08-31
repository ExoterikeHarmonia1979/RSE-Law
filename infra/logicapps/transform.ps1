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

<#
A blank subject is not a reason to throw the email away.

Not_empty_subject guarded everything - matching, lookup and the blob write - so a message
with no subject was skipped entirely and the run reported Succeeded. Measured on live
traffic: 3 of 250 runs, one of them ordinary internal mail from MLee@rse-law.com. Nothing
about a blank subject makes the message less worth keeping; it only makes it unresolvable,
which is exactly what the unsorted bucket is for.

The gate cannot simply be deleted. The subject is fed to the regex function as strData, and
the function rejects an empty strData with 400 Bad Request, which would fail the run and
abandon the message back to the queue in a loop.

So substitute instead of gate: Subject_For_Matching is the subject when there is one and the
literal "(no subject)" when there is not. The function then resolves it to
UnsortedMatterCommunication like any other unmatchable subject, and the blob is named
"(no subject) [<message id>].eml" - still unique per message, because the id tail carries
the uniqueness, not the stem.

Chained in front of the gate rather than added beside it: a Compose hanging off
Get_Email_Subject would run in parallel with the gate and might not have executed when the
condition is evaluated. Taking over the gate's own runAfter guarantees the order.
#>
$odata.Subject_For_Matching = @{
  type = 'Compose'
  runAfter = $odata.Not_empty_subject.runAfter
  inputs = "@if(empty(trim(coalesce(outputs('Get_Email_Subject'),''))), '(no subject)', outputs('Get_Email_Subject'))"
}
$odata.Not_empty_subject.runAfter = @{ Subject_For_Matching = @('Succeeded') }
# The gate is kept, not deleted, so the action graph and the run history stay comparable.
# It now asserts that there is something to match on, which the substitution guarantees -
# but if Subject_For_Matching ever yields empty, the old skip is still the safe outcome.
$odata.Not_empty_subject.expression = @{ and = @(
  @{ equals = @("@empty(trim(coalesce(outputs('Subject_For_Matching'),'')))", '@false') }
) }

<#
Calendar events are excluded on purpose - the firm does not want them archived - but the
test has to be what the message IS, not who is copied on it.

It used to drop anything whose From or To contained the string "CALENDAR". The firm runs a
calendar@rse-law.com mailbox that is routinely copied on ordinary matter correspondence, so
the guard was discarding real mail: measured over 7,992 Inbox messages, 51 were caught and
Graph classifies 50 of them as #microsoft.graph.message - ordinary email - against ONE genuine
#microsoft.graph.eventMessageRequest. A 98% false-positive rate, silently, with subjects like
"RE: DAE/JXK/MFB 98.070 - Def Frize Corp" and "06.211 - Chavez, et al vs. Uber Technologies".

Graph already answers the question exactly. Meeting invites, responses and cancellations are
returned as eventMessage / eventMessageRequest / eventMessageResponse; ordinary mail carries
no such type. Matching on "eventMessage" covers all three and nothing else.

The fetch has no $select, so the full resource - including @odata.type - is available.
#>
$found.expression = @{
  and = @(
    @{ equals = @('@variables(''blnFoundItem'')', '@true') }
    # guard the blob path: an empty matter would write everything to /matters//Emails/
    @{ equals = @('@empty(trim(coalesce(variables(''strFoundMatter''),'''')))', '@false') }
    @{ not = @{ contains = @("@coalesce(body('HTTP_Graph_API_Call_to_Get_Email_Message_via_User')?['@odata.type'], '')", 'eventMessage') } }
  )
}

<#
Fall back to the matter the mailbox itself already states.

matters@rse-law.com files mail into a File Cabinet tree - File Cabinet/119/119.014 - which
is a matter classification a person already made, on 119,573 messages. The pipeline ignored
it and re-derived the matter from the subject line, which is why so much lands unsorted:
for matter 119.014, 52 of 272 messages mention it only in the body or an attachment, and
NONE of the twelve sitting in Inbox carry it in the subject at all.

sweep-inbox.ps1 puts the folder's matter number in the synthetic notification as
Data.MatterHint. This reads it back and uses it ONLY when subject resolution has already
failed, so nothing about existing behaviour changes: real Graph notifications carry no hint
and take exactly the path they did before.

Read from the decoded body rather than body('Parse_JSON'), because the hint is not in that
action's schema and relying on an unschema'd property surviving Parse_JSON would fail
silently - the worst possible failure for a fallback.

CASING IS LOAD-BEARING. The payload key is lowercase 'data'. Property access on a raw
json() result is CASE-SENSITIVE, unlike body('Parse_JSON'), where the schema normalises it -
which is why the surrounding code gets away with ?['Data'] and this cannot. The first
version of this read ?['Data'] and therefore returned null on every single message: the
fallback never once fired, and 64 messages out of File Cabinet/99/99.103 - whose subjects
say "RSE99.103", with no space, so subject matching cannot resolve them - went to
UnsortedMatterCommunication exactly as they had before. Both casings are accepted below so
that a future change to the emitter cannot silently disarm this again.


The hint's shape is validated in the sweep, where a real regex is available; Logic Apps has
none. The write gate below still refuses an empty matter, so the blast radius of a bad hint
is a wrongly-named folder, not a write to /matters//Emails/.
#>
# Declare the hint in Parse_JSON's schema so body('Parse_JSON') is a genuine second source
# rather than a hope. Three sources, because this fallback failing silently is exactly the
# bug that already cost a full re-sweep: lowercase raw (what the sweep emits), uppercase raw,
# then the schema-backed parse.
$pjProps = $root.Parse_JSON.inputs.schema.properties
foreach ($k in @('data','Data')) {
  if ($pjProps.ContainsKey($k) -and $pjProps[$k].properties) {
    $pjProps[$k].properties['MatterHint'] = @{ type = @('string','null') }
  }
}
$hint = "trim(coalesce(json(outputs('Get_Message_JSON'))?['data']?['MatterHint'], " +
        "json(outputs('Get_Message_JSON'))?['Data']?['MatterHint'], " +
        "body('Parse_JSON')?['Data']?['MatterHint'], ''))"
$notEmpty.If_No_Matter_Use_Folder_Hint = @{
  type = 'If'
  runAfter = @{ If_Subject_has_Reg_Ex_Match = @('Succeeded') }
  <#
  "Not found" is not the only failure. The regex function does not return empty for a
  subject it cannot resolve - it returns the literal string UnsortedMatterCommunication,
  and the lookup list contains a row whose RSEFileNo is exactly that (item 185). So an
  unresolvable subject resolves as a perfectly valid matter: blnFoundItem becomes true,
  strFoundMatter becomes the placeholder, and the mail is filed under
  /matters/UnsortedMatterCommunication/.

  Gating the fallback on blnFoundItem alone therefore made it unreachable for exactly the
  mail it was written for. Traced on a real run: subject
  "RE: Trial Subpoena to Rick Marcus in the Gougerchian case; RSE99.103" -> regex match
  "UnsortedMatterCommunication" -> found in list -> hint skipped -> filed unsorted, with a
  perfectly good MatterHint of 99.103 sitting unused in the payload.

  The placeholder must therefore count as "no matter yet". A real matter still wins: this
  only overrides the placeholder, never a genuine match.
  #>
  expression = @{ and = @(
    @{ or = @(
      @{ equals = @('@variables(''blnFoundItem'')', '@false') }
      @{ equals = @('@trim(coalesce(variables(''strFoundMatter''),''''))', 'UnsortedMatterCommunication') }
    ) }
    @{ equals = @("@empty($hint)", '@false') }
  ) }
  actions = @{
    Set_variable_blnFoundItem_Folder = @{
      type = 'SetVariable'; runAfter = @{}
      inputs = @{ name = 'blnFoundItem'; value = '@true' }
    }
    Set_variable_strFoundMatter_Folder = @{
      type = 'SetVariable'
      runAfter = @{ Set_variable_blnFoundItem_Folder = @('Succeeded') }
      inputs = @{ name = 'strFoundMatter'; value = "@$hint" }
    }
  }
  else = @{ actions = @{} }
}

<#
Last resort: a subject that resolved to something, but not to a matter.

The regex function returns UnsortedMatterCommunication only when NOTHING in the subject
matched. When something did match but the lookup list has no row for it, the function
returns that value with type "Case/Claim No" and the workflow finds nothing - blnFoundItem
stays false, strFoundMatter stays empty, and with no folder hint (Inbox has none) the mail
was written nowhere and the run reported Succeeded.

Measured on live traffic, this is the only remaining silent drop for ordinary mail. Real
examples from one 2.5-hour window, every one of them a genuine business email:

    Progressive Claim: 26-200023665                 -> claim 26-200023665, not in the list
    Kanazawa vs. Pandit (Case No. 25STCV20780)      -> court case number, not in the list
    Newly Generated Invoice 128592: Gideon Kisitu   -> invoice number that looks like a claim
    Your Microsoft invoice G179227264 is ready      -> ditto

A court case number or an invoice number that happens to fit a claim-number shape is
exactly the input this has to survive. Falling back to the unsorted bucket makes the
outcome the same as if the subject had matched nothing at all: stored, indexed and
searchable rather than discarded.

Deliberately placed AFTER the folder-hint fallback, so a real matter from the mailbox
folder still wins; this only catches what neither the subject nor the folder could resolve.
It does not affect calendar events - those are excluded by the write gate's own test, which
is evaluated after this and does not care how strFoundMatter was set.
#>
$notEmpty.If_Still_No_Matter_Use_Unsorted = @{
  type = 'If'
  runAfter = @{ If_No_Matter_Use_Folder_Hint = @('Succeeded') }
  expression = @{ or = @(
    @{ equals = @('@variables(''blnFoundItem'')', '@false') }
    @{ equals = @('@empty(trim(coalesce(variables(''strFoundMatter''),'''')))', '@true') }
  ) }
  actions = @{
    Set_variable_blnFoundItem_Unsorted = @{
      type = 'SetVariable'; runAfter = @{}
      inputs = @{ name = 'blnFoundItem'; value = '@true' }
    }
    Set_variable_strFoundMatter_Unsorted = @{
      type = 'SetVariable'
      runAfter = @{ Set_variable_blnFoundItem_Unsorted = @('Succeeded') }
      inputs = @{ name = 'strFoundMatter'; value = 'UnsortedMatterCommunication' }
    }
  }
  else = @{ actions = @{} }
}

# the write gate now waits on the last fallback rather than on subject resolution alone
$found.runAfter = @{ If_Still_No_Matter_Use_Unsorted = @('Succeeded') }

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
    # the substituted subject, so a blank-subject message still yields a usable blob stem
    inputs = "@" + (San "outputs('Subject_For_Matching')")
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
            <#
            One folder per MESSAGE, not one flat folder per matter.

            Attachment blob names were the attachment name alone, so two different messages
            in one matter that both attach Invoice.pdf or image001.png wrote to the same
            path and the second silently replaced the first - the identical defect fixed for
            .eml names, left open until now and recorded in the README.

            A subfolder rather than a name suffix, so a downloaded file keeps its real name:
            "Invoice.pdf", not "Invoice [Q4TAMd2rHPEk].pdf". The segment is the same
            deterministic message-id tail the .eml uses, so an attachment sits beside its own
            message and re-running the sweep overwrites its own blob rather than duplicating.

            Nothing reads these by path: EmlPreviewFunc and EmlAttachmentNamesSkill both
            parse attachments out of the .eml, the index gets attachment_names from that
            skill, and refile-unsorted.ps1 excludes anything below the prefix either way.
            Attachments already written stay flat; only new writes are nested.
            #>
            folderPath = "/matters/@{variables('strFoundMatter')}/Emails/Attachments/@{$idTail}/"
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

# Match on the substituted subject too. The function returns 400 for an empty strData, which
# would fail the run and put the message into an abandon/retry loop rather than archiving it.
$notEmpty.HTTP_Az_Func_Reg_Matter_Full_Subject_.inputs.body = @{ strData = "@{outputs('Subject_For_Matching')}" }
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

# ------------------- 4b. an unreadable attachment list must not lose the email
# Graph answers /attachments with ErrorItemNotFound for some items ("The specified object
# was not found in the store"). The HTTP action fails, but Get_Attachment_JSON still
# *succeeds* - it happily parses the error body, because 'value' is not required by its
# schema - so the run reaches the Foreach with body(...)?['value'] evaluating to null.
#
# A Foreach over null throws ExpressionEvaluationFailed. The run fails, the message is
# abandoned and redelivered, and after 10 attempts Service Bus dead-letters it, so the
# email is never archived at all - body and attachments alike. Losing the whole record
# because one part of it was unreadable is the worst outcome available.
#
# coalesce to an empty array: there is then nothing to iterate, arrAttachments stays empty,
# and Create_blob_1 still files the message itself. Note the trade-off - this turns a loud
# total loss into a quiet partial one, so the message archives with its attachments
# missing and nothing in the blob says so. Detecting that needs a reconcile pass comparing
# hasAttachments against the attachment blobs; it is deliberately not smuggled in here.
$odata.If_Has_Attachments.actions.For_each_Attachment['foreach'] =
  "@coalesce(body('Get_Attachment_JSON')?['value'], createArray())"

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

