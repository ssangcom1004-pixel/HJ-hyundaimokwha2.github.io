# Light-weight HTTP web server using Native PowerShell TcpListener
# Bypasses Windows HTTP.sys URL ACL restrictions (No administrator privileges required).

$PORT = 3000
$CSV_PATH = Join-Path $PSScriptRoot "completions.csv"
$PUBLIC_DIR = Join-Path $PSScriptRoot "public"

# Initialize CSV file if not exists
if (-not (Test-Path $CSV_PATH)) {
    Set-Content -Path $CSV_PATH -Value "Name,DateOfBirth,CompletionTime" -Encoding utf8
}

# Discover local IP
$localIP = "127.0.0.1"
$ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | 
       Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
       Select-Object -ExpandProperty IPAddressToString

foreach ($ip in $ips) {
    if ($ip -like "192.168.*" -or $ip -like "10.*" -or $ip -like "172.*") {
        $localIP = $ip
        break
    }
}
if ($localIP -eq "127.0.0.1" -and $ips.Count -gt 0) {
    $localIP = $ips[0]
}

$APP_URL = "http://$($localIP):$PORT"

Write-Host "=================================================="
Write-Host " [EduVerify] Starting server..."
Write-Host " - Local URL: http://localhost:$PORT"
Write-Host " - Network URL (QR): $APP_URL"
Write-Host " - Admin URL: http://localhost:$PORT/admin"
Write-Host "=================================================="

# Create TcpListener on all interfaces
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $PORT)

try {
    $listener.Start()
} catch {
    Write-Host "Error starting TCP listener: $_"
    Exit
}

Write-Host "Server successfully started on port $PORT. Listening... (Ctrl+C to stop)"

function Get-MimeType($filename) {
    $ext = [System.IO.Path]::GetExtension($filename).ToLower()
    switch ($ext) {
        ".html" { return "text/html; charset=utf-8" }
        ".css" { return "text/css; charset=utf-8" }
        ".js" { return "application/javascript; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".csv" { return "text/csv; charset=utf-8" }
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png" { return "image/png" }
        ".gif" { return "image/gif" }
        ".svg" { return "image/svg+xml" }
        ".webp" { return "image/webp" }
        ".mp4" { return "video/mp4" }
        default { return "application/octet-stream" }
    }
}

function Send-TcpResponse($stream, $statusCode, $content, $contentType, $extraHeaders = @()) {
    $statusText = "200 OK"
    if ($statusCode -eq 400) { $statusText = "400 Bad Request" }
    elseif ($statusCode -eq 404) { $statusText = "404 Not Found" }
    elseif ($statusCode -eq 500) { $statusText = "500 Internal Server Error" }

    $headers = @(
        "HTTP/1.1 $statusText",
        "Server: PowerShell-TcpListener",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Headers: Content-Type",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Content-Type: $contentType"
    )
    foreach ($h in $extraHeaders) { $headers += $h }
    
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $headers += "Content-Length: $($bodyBytes.Length)"
    $headers += "Connection: close"
    
    $headerStr = ($headers -join "`r`n") + "`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerStr)
    
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
}

function Send-TcpFileResponse($stream, $filePath) {
    $mimeType = Get-MimeType $filePath
    $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
    
    $headers = @(
        "HTTP/1.1 200 OK",
        "Server: PowerShell-TcpListener",
        "Content-Type: $mimeType",
        "Content-Length: $($fileBytes.Length)",
        "Connection: close"
    )
    
    $headerStr = ($headers -join "`r`n") + "`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerStr)
    
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($fileBytes, 0, $fileBytes.Length)
}

while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        
        # 1. Read HTTP headers byte-by-byte until double CRLF
        $requestBytes = New-Object System.Collections.Generic.List[byte]
        $headerEnd = -1
        $tempBuffer = New-Object byte[] 1
        
        while ($headerEnd -eq -1) {
            $read = $stream.Read($tempBuffer, 0, 1)
            if ($read -eq 0) { break }
            $requestBytes.Add($tempBuffer[0])
            
            if ($requestBytes.Count -ge 4) {
                $c = $requestBytes.Count
                if ($requestBytes[$c-4] -eq 13 -and $requestBytes[$c-3] -eq 10 -and $requestBytes[$c-2] -eq 13 -and $requestBytes[$c-1] -eq 10) {
                    $headerEnd = $requestBytes.Count
                }
            }
        }
        
        if ($headerEnd -eq -1) {
            $client.Close()
            continue
        }
        
        $headerStr = [System.Text.Encoding]::UTF8.GetString($requestBytes.ToArray())
        
        # Parse Request Line (Method and URL)
        $lines = $headerStr -split "`r`n"
        $reqLine = $lines[0] -split " "
        if ($reqLine.Length -lt 2) {
            $client.Close()
            continue
        }
        
        $method = $reqLine[0]
        $rawUrl = $reqLine[1]
        
        # Extract path
        $path = $rawUrl
        if ($rawUrl.Contains("?")) {
            $path = $rawUrl.Substring(0, $rawUrl.IndexOf("?"))
        }

        # 2. Parse Content-Length and Read Body
        $contentLength = 0
        if ($headerStr -match "Content-Length:\s*(\d+)") {
            $contentLength = [int]$Matches[1]
        }
        
        $body = ""
        if ($contentLength -gt 0) {
            $bodyBytes = New-Object byte[] $contentLength
            $bytesRead = 0
            while ($bytesRead -lt $contentLength) {
                $read = $stream.Read($bodyBytes, $bytesRead, $contentLength - $bytesRead)
                if ($read -eq 0) { break }
                $bytesRead += $read
            }
            $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes).Trim()
        }

        # CORS Options
        if ($method -eq "OPTIONS") {
            Send-TcpResponse $stream 200 "" "text/plain"
        }
        # API: Status
        elseif ($path -eq "/api/status" -and $method -eq "GET") {
            $encodedUrl = [Uri]::EscapeDataString($APP_URL)
            $qrCodeUrl = "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$encodedUrl"
            
            $json = @{
                url = $APP_URL
                qrCode = $qrCodeUrl
                port = $PORT
                ip = $localIP
            } | ConvertTo-Json
            
            Send-TcpResponse $stream 200 $json "application/json; charset=utf-8"
        }
        # API: Submit Complete
        elseif ($path -eq "/api/complete" -and $method -eq "POST") {
            try {
                # Parse JSON body
                $data = $body | ConvertFrom-Json
                $name = $data.name.ToString().Replace('"', '').Replace(',', '').Trim()
                $dob = $data.dob.ToString().Replace('"', '').Replace(',', '').Trim()
                
                if ([string]::IsNullOrEmpty($name) -or [string]::IsNullOrEmpty($dob)) {
                    $errJson = @{ error = "Please enter both name and date of birth." } | ConvertTo-Json
                    Send-TcpResponse $stream 400 $errJson "application/json; charset=utf-8"
                } else {
                    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    $csvRecord = "`"$name`",`"$dob`",`"$timestamp`""
                    
                    Add-Content -Path $CSV_PATH -Value $csvRecord -Encoding utf8

                    $resJson = @{ success = $true; timestamp = $timestamp } | ConvertTo-Json
                    Send-TcpResponse $stream 200 $resJson "application/json; charset=utf-8"
                }
            } catch {
                $errJson = @{ error = "Failed to parse JSON request data: $_" } | ConvertTo-Json
                Send-TcpResponse $stream 500 $errJson "application/json; charset=utf-8"
            }
        }
        # API: List Completions
        elseif ($path -eq "/api/completions" -and $method -eq "GET") {
            if (Test-Path $CSV_PATH) {
                $linesList = Get-Content -Path $CSV_PATH
                $list = @()
                
                for ($i = 1; $i -lt $linesList.Count; $i++) {
                    $line = $linesList[$i].Trim()
                    if ([string]::IsNullOrEmpty($line)) { continue }
                    
                    $parts = $line -split '","'
                    if ($parts.Count -ge 3) {
                        $pName = $parts[0].Replace('"', '')
                        $pDob = $parts[1].Replace('"', '')
                        $pTime = $parts[2].Replace('"', '')
                        
                        $list += @{
                            name = $pName
                            dob = $pDob
                            time = $pTime
                        }
                    }
                }
                
                $resJson = @{ completions = $list } | ConvertTo-Json
                Send-TcpResponse $stream 200 $resJson "application/json; charset=utf-8"
            } else {
                Send-TcpResponse $stream 200 '{"completions":[]}' "application/json; charset=utf-8"
            }
        }
        # API: CSV Download
        elseif ($path -eq "/api/download" -and $method -eq "GET") {
            if (Test-Path $CSV_PATH) {
                $fileContent = Get-Content -Path $CSV_PATH -Raw
                $extra = @("Content-Disposition: attachment; filename=education_completions.csv")
                Send-TcpResponse $stream 200 $fileContent "text/csv; charset=utf-8" $extra
            } else {
                Send-TcpResponse $stream 404 "CSV file not found" "text/plain"
            }
        }
        # Static files
        else {
            $targetFile = $path
            if ($targetFile -eq "/" -or $targetFile -eq "/index") {
                $targetFile = "/index.html"
            } elseif ($targetFile -eq "/admin") {
                $targetFile = "/admin.html"
            }

            $filePath = Join-Path $PUBLIC_DIR $targetFile

            if (Test-Path $filePath -PathType Leaf) {
                Send-TcpFileResponse $stream $filePath
            } else {
                Send-TcpResponse $stream 404 "404 Not Found" "text/html"
            }
        }
        
        $stream.Close()
        $client.Close()
    } catch {
        Write-Host "Error handling TCP client: $_"
        if ($null -ne $client) { $client.Close() }
    }
}
