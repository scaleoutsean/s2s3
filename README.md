# S2S3 - Share-to-S3 tool for NAS migration to S3

S2S3 can help you quickly migrate small-to-medium NFSv3 shares to NetApp StorageGRID 
and Versity S3 Gateway with E-Series. It is also very affordable - download it for free 
from Releases.

Initial implementation supports NFSv3.

## Build inventory

### NFS v3

```sh
$ s2s3 inventory -h
Enumerate an NFSv3 export without following symlinks

Usage:
  s2s3 inventory nfs://host/export --db DIRECTORY [flags]

Flags:
      --db string               New local dataset directory (must not already exist)
      --db-temp-dir string      Temporary directory for the disk-spooled work queue
      --gid uint32              AUTH_SYS primary group ID (default 1000)
      --groups string           AUTH_SYS supplementary group IDs, comma-separated
  -h, --help                    help for inventory
      --missing-threshold int   Distinct missing siblings before checking their parent (default 5)
      --mount-port uint16       MOUNT TCP port; zero discovers through portmapper
      --nfs-port uint16         NFS TCP port; zero discovers through portmapper
      --reserved-port           Bind a reserved source port if required by export policy
      --row-group-rows int      Maximum rows per Parquet row group (default 8192)
      --rows-per-part int       Maximum rows per Parquet part (default 250000)
      --rpcbind-port uint16     RPC portmapper TCP port (default 111)
      --threads int             Concurrent directory listings (default 2)
      --timeout duration        TCP dial and individual RPC I/O timeout (not a directory time limit) (default 5s)
      --uid uint32              AUTH_SYS user ID (default 1000)
```

## Replicate to S3

TODO

## Verify

S2S3 doesn't enumerate S3 for migration, but if we want to compare the source (NAS share) and target (S3 bucket), it has to enumerate the bucket as well.

Example for prefix-based enumeration on StorageGRID 12.1 or Versity S3 Gateway 1.9.0:

```sh
$ s2s3 inventory s3://<bucket>/<prefix>/ \
  --s3-endpoint https://host:port \
  --s3-path-style --timeout 30s \
  --db <inventory-dir>
```

Omit prefix for full bucket enumeration.

## Privacy and T&C

S2S3 is free to use. It has no telemetry, dial home, or other data collection.
