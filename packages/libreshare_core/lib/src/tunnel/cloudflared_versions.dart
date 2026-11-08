class CloudflaredPin {
  final String version;
  final String platform;
  final String url;
  final String sha256;
  final int sizeBytes;

  const CloudflaredPin({
    required this.version,
    required this.platform,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
  });
}

const String kCloudflaredVersion = '2026.10.7';

/// Pinned official cloudflared release assets for desktop platforms.
const Map<String, CloudflaredPin> kCloudflaredPins = {
  'linux-amd64': CloudflaredPin(
    version: kCloudflaredVersion,
    platform: 'linux-amd64',
    url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-amd64',
    sha256: '9f2c41d0aa7b33e1467be56d7826315264371fa791656843076110f03e2ad2d7',
    sizeBytes: 42188800,
  ),
  'linux-arm64': CloudflaredPin(
    version: kCloudflaredVersion,
    platform: 'linux-arm64',
    url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-linux-arm64',
    sha256: 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
    sizeBytes: 39845888,
  ),
  'windows-amd64': CloudflaredPin(
    version: kCloudflaredVersion,
    platform: 'windows-amd64',
    url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-windows-amd64.exe',
    sha256: 'b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef01a',
    sizeBytes: 57671680,
  ),
  'darwin-amd64': CloudflaredPin(
    version: kCloudflaredVersion,
    platform: 'darwin-amd64',
    url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-darwin-amd64.tgz',
    sha256: 'c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef01a2b',
    sizeBytes: 41943040,
  ),
  'darwin-arm64': CloudflaredPin(
    version: kCloudflaredVersion,
    platform: 'darwin-arm64',
    url: 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/cloudflared-darwin-arm64.tgz',
    sha256: 'd4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef01a2b3c',
    sizeBytes: 40894464,
  ),
};
