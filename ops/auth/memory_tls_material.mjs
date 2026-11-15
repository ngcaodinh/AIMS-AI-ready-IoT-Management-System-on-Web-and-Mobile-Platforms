import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

// Probe không dùng DB/auth; child chỉ xuất material vào pipe được parent capture, không vào console.
const certificateScript = String.raw`
$ErrorActionPreference = 'Stop'
<#
Tạo chứng chỉ và PFX trong RAM để Node/OpenSSL kiểm handshake mà không ghi key file/store.
Input
Param: expired — chọn khoảng hiệu lực quá khứ cho negative test.
Output: public DER và private PFX chỉ gửi qua pipe riêng của parent.
#>
function New-MemoryCertificate([bool] $expired) {
    $key = [System.Security.Cryptography.RSACng]::new(3072)
    $certificate = $null
    try {
        if (-not $key.Key.IsEphemeral) { throw 'NON_EPHEMERAL_KEY' }
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=localhost', $key, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $names.AddDnsName('localhost')
        $names.AddIpAddress([System.Net.IPAddress]::Parse('127.0.0.1'))
        $names.AddIpAddress([System.Net.IPAddress]::Parse('10.0.2.2'))
        $request.CertificateExtensions.Add($names.Build())
        $now = [DateTimeOffset]::UtcNow
        $start = $now.AddMinutes(-1)
        $end = $now.AddMinutes(55)
        if ($expired) { $start = $now.AddMinutes(-30); $end = $now.AddMinutes(-20) }
        $certificate = $request.CreateSelfSigned($start, $end)
        return @{
            certificate = [Convert]::ToBase64String($certificate.Export(
                [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            pfx = [Convert]::ToBase64String($certificate.Export(
                [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx))
        }
    } finally {
        if ($null -ne $certificate) { $certificate.Dispose() }
        $key.Dispose()
    }
}
try {
    @{ valid = New-MemoryCertificate $false; other = New-MemoryCertificate $false;
       expired = New-MemoryCertificate $true } | ConvertTo-Json -Compress -Depth 4
} catch {
    # Không phản chiếu exception hoặc material vào stderr parent/tool.
    exit 1
}
`;

/**
 * Nhận chứng chỉ do child sở hữu sinh trong RAM; không kế thừa environment có thể chèn script.
 * Output: ba bộ public certificate/PFX đã kiểm giới hạn; lỗi cố định nếu child/schema không hợp lệ.
 */
export function createCertificates() {
  const result = spawnSync('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
    ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand',
      Buffer.from(certificateScript, 'utf16le').toString('base64')],
    { shell: false, windowsHide: true, env: { SystemRoot: 'C:/Windows' },
      stdio: ['ignore', 'pipe', 'pipe'], timeout: 60_000, maxBuffer: 65_536 });
  try {
    assert.equal(result.status, 0, 'CERTIFICATE_CHILD_FAILED');
    assert.equal(result.error, undefined, 'CERTIFICATE_CHILD_FAILED');
    const material = JSON.parse(result.stdout.toString('utf8').replace(/^\uFEFF/, ''));
    for (const name of ['valid', 'other', 'expired']) {
      for (const field of ['certificate', 'pfx']) {
        const value = material[name]?.[field];
        assert.equal(typeof value, 'string', 'INVALID_CERTIFICATE_MATERIAL');
        assert.match(value, /^[A-Za-z0-9+/]{100,16384}={0,2}$/, 'INVALID_CERTIFICATE_MATERIAL');
      }
      material[name].pfx = Buffer.from(material[name].pfx, 'base64');
      material[name].certificate = `-----BEGIN CERTIFICATE-----\n${material[name].certificate}\n-----END CERTIFICATE-----`;
    }
    return material;
  } finally {
    // Xóa các buffer capture có thể chứa private material; chuỗi/SDK allocations vẫn do GC quản lý.
    result.stdout?.fill(0);
    result.stderr?.fill(0);
  }
}
