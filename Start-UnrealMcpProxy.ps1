#Requires -Version 5.1
<#
Start-UnrealMcpProxy.ps1: a stdio MCP server that never exits while its client runs, forwarding to an HTTP (streamable HTTP)
MCP server that may come and go, such as the Unreal Editor's. Replaces `npx mcp-remote <url>` in the Claude config:

    "unreal-mcp": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
               "D:\\Projects\\MultiplayerRPGDemo1-agent\\tools\\Start-UnrealMcpProxy.ps1", "-Upstream", "http://127.0.0.1:8000/mcp"]
    }

- Answers initialize and ping itself, so it starts and stays up whether the editor runs or not.
- Reconnects on its own: a new handshake every second while the editor is unreachable, a ping every 5 s while it is up, and
  a new session when the editor restarts (its old session id is refused).
- Keeps the last tool list in -ToolCache, so the tools stay listed while the editor is closed. A call made then waits up to
  15 s for the editor, then returns an error result; the connection to the client never breaks.
- Tells the client when the editor's tool list changes (notifications/tools/list_changed).
Windows PowerShell 5.1 (.NET Framework 4.5 or later). Writes only JSON-RPC lines to stdout; logs go to stderr.
#>
param(
    [string]$Upstream = 'http://127.0.0.1:8000/mcp',
    [string]$ToolCache = (Join-Path $env:LOCALAPPDATA 'UnrealMcpProxy\tools.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { Remove-TypeData System.Array } catch { }   # Windows PowerShell 5.1 otherwise writes some arrays as {"value":[...],"Count":n}
Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::DefaultConnectionLimit = 64   # the default 2 would queue pings behind a long tool call
[System.Net.ServicePointManager]::Expect100Continue = $false

$Version = '1.0.2'
$ConnectTimeoutMs = 5000
$ReconnectIntervalMs = 1000
$PingIntervalMs = 5000
$ListWaitMs = 5000
$CallWaitMs = 15000
$RequestTimeoutMs = 300000

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Clock = [System.Diagnostics.Stopwatch]::StartNew()
$Out = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $Utf8)
$Out.AutoFlush = $true
$Handler = New-Object System.Net.Http.HttpClientHandler
$Handler.UseProxy = $false
$Http = New-Object System.Net.Http.HttpClient($Handler)
$Http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

$S = @{
    Session = $null              # @{ Id; Version } of the live upstream session
    Connecting = $false
    LastAttempt = -1000000
    LastPing = 0
    PingPending = $false
    ClientProtocol = '2025-06-18'
    ClientReady = $false
    NextId = 0
    ToolsJson = '[]'
    Refreshing = $false
    RefreshWaiters = New-Object System.Collections.Generic.List[object]
    Ops = New-Object System.Collections.Generic.List[object]
    Waits = New-Object System.Collections.Generic.List[object]
    LastState = ''
    LastError = 'no attempt yet'
}

############################################################################### helpers

function Write-Log([string]$Text) { [Console]::Error.WriteLine('[Start-UnrealMcpProxy] ' + $Text) }

function Write-State([string]$Text) {
    if ($Text -eq $S.LastState) { return }
    $S.LastState = $Text
    Write-Log $Text
}

function ConvertTo-JsonText($Value) { return (ConvertTo-Json -InputObject $Value -Depth 100 -Compress) }

function ConvertFrom-JsonText([string]$Text) {
    try { return , (ConvertFrom-Json -InputObject $Text) } catch { return $null }
}

function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return , $property.Value
}

function Test-Field($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-NextId {
    $S.NextId += 1
    return $S.NextId
}

function Get-Now { return $Clock.ElapsedMilliseconds }

function Send-Raw([string]$Json) { $Out.Write($Json + "`n") }

function Send-Result($Id, [string]$ResultJson) { Send-Raw ('{"jsonrpc":"2.0","id":' + (ConvertTo-JsonText $Id) + ',"result":' + $ResultJson + '}') }

function Send-Error($Id, [int]$Code, [string]$Message) { Send-Raw ('{"jsonrpc":"2.0","id":' + (ConvertTo-JsonText $Id) + ',"error":' + (ConvertTo-JsonText @{ code = $Code; message = $Message }) + '}') }

function Get-ErrorText($Exception) {
    $e = $Exception
    while ($null -ne $e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

# True when the request never reached the server (nothing listening, name not resolved): resending it is safe.
function Test-Unreachable($Exception) {
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.Net.Sockets.SocketException]) { return $true }
        if ($e -is [System.Net.WebException] -and ($e.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure -or $e.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure)) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Read-ToolCache {
    try {
        if (-not (Test-Path -LiteralPath $ToolCache -PathType Leaf)) { return }
        $text = [System.IO.File]::ReadAllText($ToolCache, $Utf8).Trim()
        if (-not $text.StartsWith('[') -or $null -eq (ConvertFrom-JsonText $text)) { Write-Log "ignored $ToolCache (not a tool list)"; return }
        $S.ToolsJson = $text
    } catch {
        Write-Log "cannot read ${ToolCache}: $($_.Exception.Message)"
    }
}

function Save-ToolCache {
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($ToolCache))
        [System.IO.File]::WriteAllText($ToolCache, $S.ToolsJson, $Utf8)
    } catch {
        Write-Log "cannot write ${ToolCache}: $($_.Exception.Message)"
    }
}

############################################################################### upstream operations

# One POST to the upstream server, advanced by Update-Operation from the event loop. Kind decides what its reply does.
function Start-Post([hashtable]$Message, [string]$Kind, $Context, [int]$TimeoutMs) {
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $Upstream)
    $request.Content = New-Object System.Net.Http.StringContent((ConvertTo-JsonText $Message), $Utf8)
    $request.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/json')
    $request.Headers.Accept.ParseAdd('application/json')
    $request.Headers.Accept.ParseAdd('text/event-stream')
    $session = $S.Session
    if ($null -ne $session -and $session.Id) { [void]$request.Headers.TryAddWithoutValidation('Mcp-Session-Id', [string]$session.Id) }
    if ($null -ne $session -and $session.Version) { [void]$request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', [string]$session.Version) }
    $cancel = New-Object System.Threading.CancellationTokenSource
    $op = @{
        Kind = $Kind
        Context = $Context
        Id = $Message['id']
        IsRequest = ($Message.ContainsKey('method') -and $Message.ContainsKey('id'))
        Session = $session
        SessionId = $null
        Stage = 'send'
        Request = $request
        Response = $null
        Reader = $null
        Data = New-Object System.Text.StringBuilder
        Cancel = $cancel
        TimeoutMs = $TimeoutMs
        Deadline = (Get-Now) + $TimeoutMs
        Task = $Http.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)
    }
    $S.Ops.Add($op)
}

function Stop-Operation($Op) {
    [void]$S.Ops.Remove($Op)
    try { $Op.Cancel.Cancel() } catch { }
    foreach ($item in @($Op.Reader, $Op.Response, $Op.Request, $Op.Cancel)) { if ($null -ne $item) { try { $item.Dispose() } catch { } } }
}

# Messages that are not the awaited reply: notifications go to the client, server requests are refused.
function Send-ServerMessage($Message) {
    if ($Message -isnot [System.Management.Automation.PSCustomObject]) { return }
    $method = Get-Field $Message 'method'
    if ($method -isnot [string]) { return }
    if (Test-Field $Message 'id') { Start-Post @{ jsonrpc = '2.0'; id = (Get-Field $Message 'id'); error = @{ code = -32601; message = 'not supported by the proxy' } } 'refuse' $null $ConnectTimeoutMs; return }
    if ($method -eq 'notifications/tools/list_changed') { Start-ToolsRefresh $null; return }
    if ($S.ClientReady) { Send-Raw (ConvertTo-JsonText $Message) }
}

# Handles one parsed upstream message; returns $true when it was the reply the operation waits for.
function Receive-Message($Op, $Parsed) {
    foreach ($message in @($Parsed)) {
        if ($null -eq $message) { continue }
        if ((Get-Field $message 'id') -eq $Op.Id -and ((Test-Field $message 'result') -or (Test-Field $message 'error'))) {
            Stop-Operation $Op
            Complete-Operation $Op $message
            return $true
        }
        Send-ServerMessage $message
    }
    return $false
}

function Update-Operation($Op) {
    if ((Get-Now) -gt $Op.Deadline) {
        Stop-Operation $Op
        Complete-OperationFailure $Op ('no reply within {0} s' -f ($Op.TimeoutMs / 1000)) $false
        return
    }
    if (-not $Op.Task.IsCompleted) { return }
    if ($Op.Task.IsFaulted -or $Op.Task.IsCanceled) {
        $exception = $Op.Task.Exception
        Stop-Operation $Op
        if ($null -eq $exception) { Complete-OperationFailure $Op 'cancelled' $false; return }
        Complete-OperationFailure $Op (Get-ErrorText $exception) (Test-Unreachable $exception)
        return
    }
    switch ($Op.Stage) {
        'send' {
            $response = $Op.Task.Result
            $Op.Response = $response
            $values = $null
            if ($response.Headers.TryGetValues('Mcp-Session-Id', [ref]$values)) { $Op.SessionId = @($values)[0] }
            $status = [int]$response.StatusCode
            if ($status -eq 404 -and $null -ne $Op.Session -and $Op.Session.Id) { Stop-Operation $Op; Complete-OperationFailure $Op 'session expired' $true; return }
            if (-not $response.IsSuccessStatusCode) { Stop-Operation $Op; Complete-OperationFailure $Op "HTTP $status" $false; return }
            if (-not $Op.IsRequest) { Stop-Operation $Op; Complete-Operation $Op $null; return }
            $type = $response.Content.Headers.ContentType
            if ($null -ne $type -and $type.MediaType -eq 'text/event-stream') {
                $Op.Stage = 'stream'
                $Op.Task = $response.Content.ReadAsStreamAsync()
            } else {
                $Op.Stage = 'body'
                $Op.Task = $response.Content.ReadAsStringAsync()
            }
        }
        'body' {
            $parsed = ConvertFrom-JsonText $Op.Task.Result
            if (Receive-Message $Op $parsed) { return }
            Stop-Operation $Op
            Complete-OperationFailure $Op 'the reply did not answer the request' $false
        }
        'stream' {
            $Op.Reader = New-Object System.IO.StreamReader($Op.Task.Result, $Utf8)
            $Op.Stage = 'sse'
            $Op.Task = $Op.Reader.ReadLineAsync()
        }
        'sse' {
            while ($Op.Task.IsCompleted) {
                if ($Op.Task.IsFaulted -or $Op.Task.IsCanceled) { Stop-Operation $Op; Complete-OperationFailure $Op 'the event stream failed' $false; return }
                $line = $Op.Task.Result
                if ($null -eq $line) { Stop-Operation $Op; Complete-OperationFailure $Op 'the server closed the stream without a reply' $false; return }
                if ($line -eq '') {
                    if ($Op.Data.Length -gt 0) {
                        $parsed = ConvertFrom-JsonText $Op.Data.ToString()
                        [void]$Op.Data.Clear()
                        if (Receive-Message $Op $parsed) { return }
                    }
                } elseif ($line.StartsWith('data:')) {
                    $data = $line.Substring(5)
                    if ($data.StartsWith(' ')) { $data = $data.Substring(1) }
                    if ($Op.Data.Length -gt 0) { [void]$Op.Data.Append("`n") }
                    [void]$Op.Data.Append($data)
                }
                $Op.Task = $Op.Reader.ReadLineAsync()
            }
        }
    }
}

function Complete-Operation($Op, $Answer) {
    $context = $Op.Context
    switch ($Op.Kind) {
        'init' {
            if (Test-Field $Answer 'error') { Complete-Connect $false ('initialize refused: ' + (Get-Field (Get-Field $Answer 'error') 'message')); return }
            $S.Session = @{ Id = $Op.SessionId; Version = (Get-Field (Get-Field $Answer 'result') 'protocolVersion') }
            Start-Post @{ jsonrpc = '2.0'; method = 'notifications/initialized' } 'initialized' $null $ConnectTimeoutMs
        }
        'initialized' {
            Write-State "connected to $Upstream"
            $S.LastPing = Get-Now
            Complete-Connect $true $null
            Start-ToolsRefresh $null
        }
        'ping' { $S.PingPending = $false }
        'list' {
            if (Test-Field $Answer 'error') { Complete-ToolsRefreshFailure ('tools/list refused: ' + (Get-Field (Get-Field $Answer 'error') 'message')); return }
            $result = Get-Field $Answer 'result'
            $tools = Get-Field $result 'tools'
            if ($null -ne $tools) { foreach ($tool in @($tools)) { $context.Tools.Add($tool) } }
            $cursor = Get-Field $result 'nextCursor'
            if ($cursor) { Start-Post @{ jsonrpc = '2.0'; id = (Get-NextId); method = 'tools/list'; params = @{ cursor = $cursor } } 'list' $context ($ConnectTimeoutMs * 2); return }
            Complete-ToolsRefresh $context.Tools
        }
        'forward' {
            if (Test-Field $Answer 'error') { Send-Raw ('{"jsonrpc":"2.0","id":' + (ConvertTo-JsonText $context.ClientId) + ',"error":' + (ConvertTo-JsonText (Get-Field $Answer 'error')) + '}'); return }
            Send-Result $context.ClientId (ConvertTo-JsonText (Get-Field $Answer 'result'))
        }
    }
}

function Complete-OperationFailure($Op, [string]$Reason, [bool]$Retry) {
    if ($Retry) { Clear-Session $Op.Session $Reason }
    $context = $Op.Context
    switch ($Op.Kind) {
        'init' { Complete-Connect $false $Reason }
        'initialized' { $S.Session = $null; Complete-Connect $false $Reason }
        'ping' { $S.PingPending = $false; Clear-Session $Op.Session $Reason }
        'list' { Complete-ToolsRefreshFailure "tools/list failed: $Reason" }
        'forward' {
            if ($Retry -and $context.Attempt -eq 0) { $context.Attempt = 1; Add-SessionWait $context $CallWaitMs; return }
            Send-Unavailable $context "The call to the Unreal Editor MCP failed: $Reason"
        }
    }
}

############################################################################### session

function Start-Connect {
    if ($null -ne $S.Session -or $S.Connecting) { return }
    $S.Connecting = $true
    $S.LastAttempt = Get-Now
    $init = @{ jsonrpc = '2.0'; id = (Get-NextId); method = 'initialize'; params = @{ protocolVersion = $S.ClientProtocol; capabilities = @{}; clientInfo = @{ name = 'unreal-mcp-proxy'; version = $Version } } }
    Start-Post $init 'init' $null $ConnectTimeoutMs
}

function Complete-Connect([bool]$Connected, [string]$Reason) {
    $S.Connecting = $false
    if (-not $Connected) { $S.Session = $null; $S.LastError = $Reason; Write-State "Unreal MCP not reachable at $Upstream ($Reason); retrying"; return }
    $waits = $S.Waits.ToArray()
    $S.Waits.Clear()
    foreach ($context in $waits) { Start-ClientRequest $context }
}

function Clear-Session($Session, [string]$Reason) {
    if ($null -eq $Session -or -not [object]::ReferenceEquals($Session, $S.Session)) { return }
    $S.Session = $null
    Write-State "disconnected ($Reason); reconnecting"
}

function Add-SessionWait($Context, [int]$WaitMs) {
    $Context.Deadline = (Get-Now) + $WaitMs
    $S.Waits.Add($Context)
    Start-Connect
}

function Clear-ExpiredWaits {
    if ($S.Waits.Count -eq 0) { return }
    $now = Get-Now
    foreach ($context in $S.Waits.ToArray()) {
        if ($now -lt $context.Deadline) { continue }
        [void]$S.Waits.Remove($context)
        Send-Unavailable $context "The Unreal Editor MCP is not reachable at $Upstream (last error: $($S.LastError)). Start the editor and its MCP server; the proxy reconnects on its own."
    }
}

function Invoke-KeepAlive {
    $now = Get-Now
    if ($null -eq $S.Session) {
        if (-not $S.Connecting -and $now - $S.LastAttempt -ge $ReconnectIntervalMs) { Start-Connect }
        return
    }
    if ($S.Connecting -or $S.PingPending -or $now - $S.LastPing -lt $PingIntervalMs) { return }
    $S.LastPing = $now
    $S.PingPending = $true
    Start-Post @{ jsonrpc = '2.0'; id = (Get-NextId); method = 'ping' } 'ping' $null $ConnectTimeoutMs
}

############################################################################### tool list

function Start-ToolsRefresh($Context) {
    if ($null -ne $Context) { $S.RefreshWaiters.Add($Context) }
    if ($S.Refreshing) { return }
    if ($null -eq $S.Session) { Complete-ToolsRefreshFailure 'not connected'; return }
    $S.Refreshing = $true
    Start-Post @{ jsonrpc = '2.0'; id = (Get-NextId); method = 'tools/list'; params = @{} } 'list' @{ Tools = (New-Object System.Collections.Generic.List[object]) } ($ConnectTimeoutMs * 2)
}

function Complete-ToolsRefresh($Tools) {
    $S.Refreshing = $false
    $json = ConvertTo-JsonText $Tools.ToArray()
    $changed = $json -ne $S.ToolsJson
    if ($changed) {
        $S.ToolsJson = $json
        Save-ToolCache
        Write-Log "tool list changed: $($Tools.Count) tools"
    }
    $waiters = $S.RefreshWaiters.ToArray()
    $S.RefreshWaiters.Clear()
    foreach ($context in $waiters) { Send-Result $context.ClientId ('{"tools":' + $S.ToolsJson + '}') }
    if ($changed -and $waiters.Count -eq 0 -and $S.ClientReady) { Send-Raw '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}' }
}

function Complete-ToolsRefreshFailure([string]$Reason) {
    $S.Refreshing = $false
    Write-Log $Reason
    $waiters = $S.RefreshWaiters.ToArray()
    $S.RefreshWaiters.Clear()
    foreach ($context in $waiters) { Send-Result $context.ClientId ('{"tools":' + $S.ToolsJson + '}') }
}

############################################################################### client (stdio)

function Send-Unavailable($Context, [string]$Text) {
    if ($Context.Method -eq 'tools/list') { Send-Result $Context.ClientId ('{"tools":' + $S.ToolsJson + '}'); return }
    if ($Context.Method -eq 'tools/call') { Send-Result $Context.ClientId (ConvertTo-JsonText @{ content = @(@{ type = 'text'; text = $Text }); isError = $true }); return }
    Send-Error $Context.ClientId -32603 $Text
}

function Start-ClientRequest($Context) {
    if ($Context.Method -eq 'tools/list') { Start-ToolsRefresh $Context; return }
    $message = @{ jsonrpc = '2.0'; id = (Get-NextId); method = $Context.Method }
    if ($null -ne $Context.Params) { $message['params'] = $Context.Params }
    Start-Post $message 'forward' $Context $RequestTimeoutMs
}

function Invoke-ClientMessage($Message) {
    $method = Get-Field $Message 'method'
    if ($method -isnot [string]) { return }   # replies to server requests: the proxy sends none
    $hasId = Test-Field $Message 'id'
    $id = Get-Field $Message 'id'
    $params = Get-Field $Message 'params'
    switch -Exact ($method) {
        'initialize' {
            $protocol = Get-Field $params 'protocolVersion'
            if ($protocol -is [string] -and $protocol) { $S.ClientProtocol = $protocol }
            Send-Result $id (ConvertTo-JsonText @{ protocolVersion = $S.ClientProtocol; capabilities = @{ tools = @{ listChanged = $true } }; serverInfo = @{ name = 'unreal-mcp-proxy'; version = $Version } })
            return
        }
        'notifications/initialized' { $S.ClientReady = $true; return }
        'ping' { if ($hasId) { Send-Result $id '{}' }; return }
    }
    if (-not $hasId) { return }   # other notifications (cancellations included) are not forwarded
    $context = @{ ClientId = $id; Method = $method; Params = $params; Attempt = 0; Deadline = 0 }
    if ($null -ne $S.Session) { Start-ClientRequest $context; return }
    if ($method -eq 'tools/list') { Add-SessionWait $context $ListWaitMs; return }
    if ($method -eq 'tools/call') { Add-SessionWait $context $CallWaitMs; return }
    Send-Error $id -32603 'Unreal Editor MCP not connected'
}

############################################################################### event loop

function Invoke-Main {
    Read-ToolCache
    Write-Log "starting; upstream $Upstream, tool cache $ToolCache"
    $in = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $Utf8)
    $read = $in.ReadLineAsync()
    while ($true) {
        while ($read.IsCompleted) {
            if ($read.IsFaulted -or $read.IsCanceled) { Write-Log 'stdin failed; exiting'; return }
            $line = $read.Result
            if ($null -eq $line) { Write-Log 'stdin closed; exiting'; return }
            if ($line.Trim()) {
                $parsed = ConvertFrom-JsonText $line
                if ($null -eq $parsed) { Write-Log 'ignored a line that is not JSON' }
                foreach ($message in @($parsed)) {
                    if ($null -eq $message) { continue }
                    try { Invoke-ClientMessage $message } catch { Write-Log "error: $($_.Exception.Message)"; if (Test-Field $message 'id') { Send-Error (Get-Field $message 'id') -32603 $_.Exception.Message } }
                }
            }
            $read = $in.ReadLineAsync()
        }
        foreach ($op in $S.Ops.ToArray()) {
            if (-not $S.Ops.Contains($op)) { continue }
            try { Update-Operation $op } catch { Write-Log "error: $($_.Exception.Message)"; if ($S.Ops.Contains($op)) { Stop-Operation $op; Complete-OperationFailure $op $_.Exception.Message $false } }
        }
        try { Clear-ExpiredWaits; Invoke-KeepAlive } catch { Write-Log "error: $($_.Exception.Message)" }
        $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        $tasks.Add($read)
        foreach ($op in $S.Ops) { $tasks.Add($op.Task) }
        [void][System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 200)
    }
}

Invoke-Main | Out-Null   # nothing reaches stdout except Send-Raw's JSON-RPC lines
