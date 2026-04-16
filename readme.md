# Zig Community Mirror Server

`zigmirror` is a simple [Zig Community Mirror](https://codeberg.org/ziglang/www.ziglang.org/src/branch/main/MIRRORS.md) cache server.  It utilizes two caches:
* A small memory cache for "strange" requests
* A larger filesystem cache for "typical" requests

Both caches are configured to hold a maximum number of files and maximum total memory/disk usage.
This makes it a good option to run on systems with constrained memory or disk space

## Usage
`zigmirror` expects a single command line argument: the path to the `zigmirror.sx` configuration file.  If not specified as an absolute path, it will recursively search for the file, starting in the executable directory and moving through the parent chain until it is found, or the root directory is reached.

`zig build` will output a default `zigmirror.sx` configuration file to `zig-out/etc/zigmirror.sx`.

An HTML `/stats` endpoint is served which provides information about what is currently available in the cache, how frequently it is accessed, etc.

## HTTPS Termination
Zig community mirrors are expected to serve over HTTPS, but good TLS support complicates server projects significantly, and often it's better/easier to just handle HTTPS termination through a load balancer or reverse proxy.  Therefore this project assumes that you'll use an external solution such as [TLSproxy](https://github.com/c2FmZQ/tlsproxy).

## Request Rate Limiting
Basic IP-based request rate limiting is included.  When used, the HTTPS terminating proxy must set/update the `X-Forwarded-For` HTTP header.  Limiting will be applied to all IPs listed in the header, but once a request has been blocked, any remaining IPs in the list will not take a hit for that request.  Rate limiting can be disabled entirely by removing the `(request_rate_limit ...)` expression from the config file.

## Memory/Disk Usage Tuning
The `(cache (mem))` and `(cache (fs))` expressions in the config file include two inline parameters:
* `max_entries`, the maximum number of artifacts that can exist in the cache at any particular time
* `max_bytes`, the maximum total memory/disk that can be consumed by the cache at any particular time

Average artifact size is somewhere around 25MB (most build artifacts are around 50MB and `.minisig` artifacts are tiny), so it's best to set `max_entries` to at least `max_bytes / (25 * 1024 * 1024)`.

When an artifact is evicted from the memory cache, it is moved to the filesystem cache, unless the filesystem cache is full and everything it contains is more important than the item from the memory cache.
Additionally, popular artifacts may be moved from the memory cache to the FS cache before the memory cache is full.  The conditions for this are controlled with the `(cache ... (mem ... (periodic_eviction ...)))` config expression.
Optionally, moving to the filesystem cache can be skipped if the artifact wasn't referenced enough while in memory, using the `(cache ... (fs ... (min_requests n)))` expression in the config file.  If you set this higher than 1, you may want to set the memory cache size a little higher (I'd recommend at least 2GB / 100 entries).

When serving artifacts from the filesystem, `sendfile` is utilized, so the OS's internal filesystem cache is leveraged as much as possible.  Therefore, you shouldn't allocate a majority of your system memory towards the memory cache.  I recommend at least 1 GB, but not more than 25% of your physical memory.

`(max_concurrent_upstream_downloads n)` controls how many threads may try to download new artifacts from `ziglang.org` at the same time.  Each thread doing this temporarily stores the full artifact in memory before adding it to the memory cache, so setting this to a large number will increase process memory usage.  Note: If a client requests an artifact that's already being downloaded for another client, the subsequent client(s) will be blocked until the original download completes and the artifact enters the cache.

## Typical Installation
```sh
# Build zigmirror:
cd ~
git clone https://codeberg.org/bcrist/zigmirror
cd zigmirror
zig build -Doptimize=ReleaseSafe

# Install zigmirror:
sudo useradd --system --shell /usr/sbin/nologin zigmirror

sudo cp zig-out/bin/zigmirror /usr/local/bin/
sudo chown zigmirror:zigmirror /usr/local/bin/zigmirror

sudo cp zig-out/etc/zigmirror.sx /usr/local/etc/
sudo vi /usr/local/etc/zigmirror.sx # modify as desired
sudo chown zigmirror:zigmirror /usr/local/etc/zigmirror.sx

sudo cp src/zigmirror.service /etc/systemd/system/
sudo vi /etc/systemd/system/zigmirror.service # modify as desired
sudo systemctl daemon-reload
sudo systemctl enable zigmirror
sudo systemctl start zigmirror

# Build TLSproxy:
cd ~
git clone https://github.com/c2FmZQ/tlsproxy
cd tlsproxy
go generate ./...
go build -o tlsproxy

# Install TLSproxy:
sudo useradd --system --shell /usr/sbin/nologin tlsproxy

sudo cp tlsproxy /usr/local/bin/
sudo chown tlsproxy:tlsproxy /usr/local/bin/tlsproxy

sudo mkdir -p /usr/local/etc/tlsproxy
sudo cp ../zigmirror/tlsproxy/config.yaml /usr/local/etc/tlsproxy/
sudo vi /usr/local/etc/tlsproxy/config.yaml # modify as desired
sudo chown tlsproxy:tlsproxy /usr/local/etc/tlsproxy/config.yaml

sudo mkdir -p /usr/local/var/cache/tlsproxy

sudo cp ../zigmirror/tlsproxy/tlsproxy.service /etc/systemd/system/
sudo vi /etc/systemd/system/tlsproxy.service # modify as desired
sudo systemctl daemon-reload
sudo systemctl enable tlsproxy
sudo systemctl start tlsproxy
```
