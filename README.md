# S2S3 - Share-to-S3 tool for NAS migration to S3

S2S3 can help you quickly migrate small-to-medium NFSv3 shares to NetApp StorageGRID 
and Versity S3 Gateway with E-Series buckets. It is also very affordable - download it for free from Releases.

The initial implementation supports NFSv3 sources. Other sources (SMB, NFSv4) may be added later.

## How it works

S2S3 works the same way most people do this manually.

![S2S3](./images/s2s3-00-diagram.png)

- t0 - create initial inventory and the first copy to S3 bucket
- t1, t2 - optional (full) inventory with incremental sync-copy
- t3 - make the NFS share read-only, ceate final full inventory of the source
- t4 - final incremental sync, verification run, optional creation of full inventory of both source and destination for compliance or record-keeping

As shown in the diagram, copy/sync operations are handled by an external utility, such as Rclone but file lists can be pased to any program, making it possible to use highly specialized copy tools where required.

S2S3 can implement copying, but that would reduce its flexibility. Flexibility seems more valuable than convenience, but convenience is retained by using one reference tool with canned examples for common workflows included in the S2S3 documentation. 

## Workflow

- Calibrate to find the optimal workload for NFS and S3
- Build inventory and perform the initial coipy
  - Perform additional rounds of "full inventory & incremental sync" if needed
- Final full inventory on read-only NAS export, and incremental sync from NAS
- Verification and report
- Switch-over (S3 ACLs are modified to allow S3 modify actions to other users)

## Calibrate

On the client, S2S3's work is cheap, but server work is not. You need to carefully consider the workload S2S3 creates:
- Source: directory listing (inventory), reads (copy/sync)
- Target: Put (and some delete) workload (copy/sync), bucket enumeration (inventory, comparison, report)
- S2S3 client: small workload (write/read Parquet DB files)

**NFS:** S2S3 lets you specify the number of threads used for scanning. Two is usually enough (lab testing shows 8,000 files listed per second), but can impact other workloads. Rclone lets you specify the number of threads used in copy/sync operations. 

**S3:** S2S3 enumeration of S3 buckets is single-threaded and lab results show around 3,000 objects listed per second. If that level can impact your StorageGRID, ask your StorageGRID admin or other infrastructure person to configure [Traffic Classification](https://docs.netapp.com/us-en/storagegrid/admin/managing-traffic-classification-policies.html) for the S2S3 (tenant) account, the S2S3 IP, the bucket(s)...

**End-to-end:** Inventories are built separately, so the are independent. For copy/sync, find balanced settings that works well with both the source and destination. Put operations to S3 are likely going to be slower than NFS reads (especially with sub-1MiB NFS files), so Rclone shouldn't try to push harder than necessary - it won't work anyway.

## Build inventory

Source NAS share must be inventoried first. S3 inventory not until after the first copy from NAS is performed because it is assumed to be empty at start.

### Data set naming conventions

We use `--db <path>` to specify the location of an inventory database. It is suggested to employ a convention (e.g. `<nas_ip>_<share_name>_<datetime>_<ref>` and `<s3-api>_<bucket_name>_<datetime>-<ref>`).

A date string (e.g. 2026-10-28-14) gives you an idea when the scan was performned, and your reference is an extra for easier identification.

### NFS v3 inventory

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

**NOTE:** NFS does not require a mount point at this stage, but OS requires a sudoer, which then results in root ownership of the `db` directory. If you operate S2S3 as a regular user, run `sudo chown <db-directory>` after this step, so that you don't have to run subsequent steps as a sudoer. Rclone copy/sync requires NFS to be mounted, so you'll need `sudo` for that, but not for any other S2S3 operations.

```sh
$ sudo s2s3 inventory nfs://192.168.1.194/mnt/nfs-test \
  --reserved-port --uid "$(id -u)" --gid "$(id -g)" \
  --db ./test-inc-01 --threads 2 --timeout 30s
```

After this, I choose change data directory ownership to my user:
```sh
sudo chown -R sean:sean ./test-inc-01
```
If you don't want non-sudoers to be able to access this data, you can skip this step.

### S3 inventory

### Pre-flight checks

Different actions are required for different use of S3. You can try these before you fly.

```sh
s2s3 preflight s3://bucket/prefix --mode list
s2s3 preflight s3://bucket/prefix --mode copy
s2s3 preflight s3://bucket/prefix --mode sync
```

To build an inventory you just need to be able to `list`. Later, as we copy and sync, we will need more. Non-S2S3 users should at most have list access, with correct ACLs (not wide open to Anonymous or "any account user").

**Note:** you should also read **Copy vs. Sync** below, before you begin.

### Build after initial sync

We don't need to build inventory of an empty bucket, so we'd do this only *after the first copy* from NAS to S3 has completed.

Normally, we'd inventory an entire bucket, but you can also perform prefix-based enumeration in case you are focused on particular path in the bucket (especially between iterative sync operations later on).

Prefix-based enumeration on StorageGRID 12.1 or Versity S3 Gateway 1.9.0:

```sh
$ # load from .env or add AWS_ACCESS_KEY_ID=<str> AWS_SECRET_ACCESS_KEY=<str>
$ s2s3 inventory s3://<bucket>/<prefix>/ \
  --s3-endpoint https://host:port \
  --s3-path-style --timeout 30s \
  --db <inventory-dir>
```

Notice there's no `sudo` here. S3 doesn't require it. S2S3 needs the S3 credentials - that's not optional. The port for StorageGRID is usually 10443 and Versity S3 Gateway 7070. Do not use HTTP as not just TBs of data could leak, but your credentials could be compromised as well.

### SMB inventory

SMB is not currently supported.

## Copy NAS data to S3

As mentioned at the top, S2S3 can give you lists of what needs to be copied (and deleted, if files have been deleted from the source). 

In Rclone and in the context of S2S3, there are two kinds, although you can use one:

- Copy: copies NAS share over S3 bucket contents.
- Sync: propagates changes from NAS share to S3.

We want to use copy the first time - since the destination bucket is empty, it won't be different from sync, but later on it is less resource-intensive to use `sync`.

Subsequently we can avoid re-copying of all NAS share content by using `sync`. "Conservative" users may use `copy` throughout, but iterative migrations done this way take longer.

Before you can either copy or sync, you need to mount the source NAS share. On Linux, that could be a path in your own directory. Examples below use `/tmp` which is convenient, but less secure as others may have access to the mount.

### Initial copy

The assumption is most users perform multiple rounds of synchronization, but this initial copy could also be the only one. If you're performing one-shot migration (no subsequent syncs), make your NAS share **read-only** before you begin this phase.

**Copy** data from NAS to S3 with `rclone copy`. You need to set up your S3 in Rclone configuration file (default: `~/.config/rclone/rclone.conf`) and use Rclone parameters determined during calibration. Or you can drop some options and let Rclone use its defaults.

**Note:** that Rclone works with NAS mounts, so mount that NFS share somewhere (requires a `sudoer` account). `/tmp/nfs-test` is convenient, but `/mnt/nfs-test` may be safer (depending on NFS export options and your OS environment).

```sh
rclone copy \
  /tmp/nfs-test \
  s131:dst \
  --no-traverse \
  --transfers 1 \
  --checkers 1 \
  --s3-upload-concurrency 1 \
  --s3-no-head \
  --tpslimit 5 \
  --tpslimit-burst 1 \
  --max-backlog 2 \
```

**If** your NAS was read-only, you could verify and be done:

```sh
# inventory the S3 target bucket after NAs-to-S3 sync
./s2s3 inventory s3://dst --db ./s3-t0 ...

# compare
./s2s3 verify --source ./test-t0 --target ./s3-t0
```

Most users leave NFS share in use and take time to examine the target, compare NAS share with S3 and may perform multiple rounds of "inventory & sync" to keep the size of the last sync smaller. That's next.

### Sync - propagate source changes to S3 

If your NFS share is still open for writing by now, you can perform checks on the target, compare files, and so on.

**Sync** data with `rclone sync`. To know what to sync, we use `s2s3 diff` with two inventory data sets: `--before` is the previous, and `--after` is the updated (latest, named `test-inc-01`):

```sh
$ s2s3 diff --before ./test-t0 --after ./test-inc-01 \
  --copy-list ./test-inc-01-copy-filelist.txt \
  --delete-list ./test-inc-01-delete-filelist.txt
```

This gives me two lists:
- copy-list: changed and added
- delete-list: deleted

This is now easy to process with Rclone. Use `rclone sync` for that and feed it the delete list so that it copies changed and added, and deletes what was deleted between inventory `test-t0` and `-test-inc-01`.

Sync is like StorageGRID Cloud Mirror: it doesn't know what may have been added at the destination. It cannot know what object has been overwritten or deleted by others. Keep the destination read-only for non-S2S3 users if you don't want to deal with problems caused by random out-of-band activity on S3.

Even for `rclone sync` done right, you *need to think* about the consequences of using sync. See the **Copy vs. Sync** section below.

## Export inventory

You don't have to use this one, but you can. If you need to export stuff from a dataset:

```sh
s2s3 export --dataset ./test-inc-01 --output ./test-inc-01-filelist.txt
# option for for rclone use
# s2s3 export --dataset ./test-t0 --format rclone-files-from --output ./t0-files.txt
```

As mentioned earlier: you wouldn't use `rclone copy` for re-sync, but you could. If you use `rclone copy`, you don't even need this list or S2S3. But then you also don't have a list - you need to create and maintain it with Rclone and that's perfectly fine, but it seems more complicated to me.

Notice how `export` gives a full list, so you need to use `rclone copy`, while `diff` gives two lists, so we can use `rclone sync`. 

If you used the Rclone option you could do something like:

```sh
$ rclone copy \
  --files-from-raw ./t0-files.txt \
  /tmp/nfs-test \
  s131:dst \
  --transfers 1 \
  --checkers 1
```

There's also `diff`:

```sh
$ s2s3 diff \
  --before ./test-t0 \
  --after ./test-t1 \
  --copy-list ./copy.txt \
  --delete-list ./delete.txt
```

`diff` produces:

- new or size-changed files in the copy list
- deleted files in the delete list
- sorted deterministic output
- no source or destination modifications

Example:

```json
{
  "copy": 2,
  "added": 1,
  "modified": 1,
  "delete": 1,
  "unchanged": 224998
}
```

### Copy vs Sync

During migration, regular users are normally not allowed to modify the destination.

But you may have a situation where applications need to be tested, and they need to delete or add data. In this situation you may need to use `rclone copy` and even perform more extensive planning.

For example, it is better to make a copy for testing in different test bucket, than modify a workflow to work around whatever unpredictable stuff happens when a target is live before migration is done. `export` lets you get a list that you can use to copy a subset of data to a separate bucket and perform pre-switchover testing there. 

Another example: if your application requires or uses Versioning or Object Lock, you probably don't want to allow Put/Delete on objects before switch-over. But if the application requires Versioning, that also means you can't test before switch-over. Therefore:
- Good: use a test bucket for pre-switch-over testing. Enable Versioning, Object Lock, ILM when it suits your business requirements.
- **Bad:** enable Versioning for testing during migration iterations, prepare scripts to delete non-current versions before switch-over, and let ILM cleanse them. Use `rclone copy` to overwrite changed or new objects.

Even if you use `rclone sync` (i.e. not one-shot copy), if Versioning or Compliance is enabled early on, you can end up with multiple versions of objects that you don't want - maybe they take up TBs of space and you already have them in NAS snapshots - or may be undesirable - but you cannot delete them.

## Verify

S2S3 doesn't enumerate S3 for migration from S3, but if we want to compare the source (NAS share) and target (S3 bucket), it has to enumerate the bucket as well.

At this point, we assume that you've either performed one-shot copy (rclone copy) or one (or more) incremental sync(s). Consider this: `test-inc-01` indicates that is my second sync (after the initial):
- I am either verifying as a matter of routine, after each incremental run, or
- I made my NAS share read-only right after creating `test-t0` inventory of `test-nfs`, then I ran one-shot `rcsync copy` and `test-inc-01` was created as the final inventory of NFS. I then created an inventory of the S3 destination, `test-inc-s3-01` (notice how confusing these names can get)

Either way, command syntax is the same. 

Couple of reminders:
- `sudo` is used if you haven't changed ownership of the inventory DB. `--rclone-config` makes sure Rclone knows where to find the config
- If you changed ownership of `--source <db>`, you don't need `sudo` and `--rclone-config`:

```sh
$ sudo ./bin/s2s3 verify \
  --mode deep \
  --source ./test-inc-01 \
  --target s131:dst \
  --source-root /tmp/nfs-test \
  --rclone-config /home/sean/.config/rclone/rclone.conf \
  --combined ./rclone-check.combined \
  --log-file ./rclone-check.log
```  

Simple example:

```sh
s2s3 verify --source ./test-inc-01 --target ./test-inc-s3-01 \
 --mode nfs-to-s3
```

This compares the contents of two inventories, NFS and S3, verify the assumption that the inventories should match.

Only NFS-to-S3 direction is supported. S3 to NFS will not be added.

Example result:
```json
{
  "source": "./test-t0",
  "target": "./s3-t0",
  "verification_method": "size",
  "verification_executor": "s2s3",
  "matched": 225000,
  "missing": 7,
  "unexpected": 0,
  "size_mismatch": 0,
  "source_rows": 225007,
  "target_rows": 225000,
  "examples": [
    "missing: skewed/d000000000/d000000000/d000000000/d000000000"
  ]
}
{
  "level": "error",
  "message": "inventories differ"
}
```

This tells us if S2S3 **inventories** match. Does it tell us the source and destination data match? Not necessarily.

There's a way to check harder, but it costs more to execute.

```sh
s2s3 verify --source ./test-inc-01 --target s131:dst \
  --source-root /tmp/nfs-test   
  --combined ./rclone-check.combined --log-file ./rclone-check.log \
  --mode deep 
```

This *downloads* everything from S3 destination that's inventoried in `test-inc-01`!

It also reads everything from NFS, and compares source source with S3 in "one-way" fashion (makes sure Source-to-Destination is good, not that whatever may have been added on S3 exists on NFS).

Deep mode is expensive, but maybe acceptable for the final verification or iterative verification of sub-100TB buckets (depending on your environment).

**NOTE:** It's not just a matter of "best practice" to not overuse `deep`, but `deep` can't work well when the *source is still live*. As long as the NAS source is being updated, you'd usually get a massive amount of failures on every run.

## Report

Verify just verifies, it doesn't create a report. Reports may also be expensive.

You'll probably run a more extensive report just before switch-over, after NAS shares are read only and the final sync or copy has been done.

```sh
s2s3 verify \
  --mode deep \
  --source ./test-t2 \
  --target s131:dst \
  --source-root /tmp/nfs-test \
  --report ./deep-check.combined
```

Switch-over report:

```sh
$ rclone check \
  /tmp/nfs-test \
  s131:dst \
  --download \
  --one-way \
  --combined ./rclone-check-combined.txt \
  --log-file ./rclone-check.log \
```

You may want to create a bucket for these reports (e.g. `s3://migration-reports`, with Versioning and Object Lock) and upload reports there to mark migration completed and keep track of the switch-over state. 

If you enabled Versioning or ILM on the bucket before migration was done (not recommended, but may be required), you may already have changes (versions, deletes, even reads) which require tracking for compliance, so get the StorageGRID audit log for the bucket and upload it to the bucket together with other hand-over documentation, reports and logs.

## Other notes

### Database vs dataset

`inventory` creates a `db`, while other commands refer to the same data as `dataset`.

Data is the same, but only inventory creates it, so it's called differently.

### Small scale checks

If you want to check a statistically significant sample (e.g. 99.99% confidence, 5% margin of error) from 50% of NFS share content that has 1,000,000 files, you may check 1,151 files instead. 

In order to avoid doing "light" (inventory to inventory, which may be wrong) or "deep" on 1,000,000 objects (which may be wasteful), you can get exaport a sample and check those files any way you want.

```sh
$ s2s3 export --dataset ./test-t2 --output ./all-files.txt
$ shuf -n 1151 ./all-files.txt > ./sample-1151.txt
```

## Privacy and T&C

S2S3 is free to use. It has no telemetry, dial home, or other data collection.
