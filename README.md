# GCP Snapshot Automation Scripts

Pre- and post-snapshot hooks for Google Cloud Platform (GCP) Compute Engine persistent disk snapshots, ensuring application- and filesystem-consistent backups.

## Overview

Taking live disk snapshots without quiescing active databases and filesystems can cause data corruption upon restore. These scripts coordinate a synchronized freeze and thaw across the storage and service stack.

## Architecture & Flow

1. **`gcloud-snapshots/pre.sh`** (Quiesce):
   - Locks MySQL / MariaDB tables (`FLUSH TABLES WITH READ LOCK`) in a background session that keeps the lock until `post.sh` runs, or for at most `LOCK_MAX` seconds
   - Closes the Elasticsearch index
   - Flushes write buffers (`sync`) and freezes the XFS filesystem (`xfs_freeze -f /`)
   - If any step fails, undoes the steps already taken (by running `post.sh`) and exits non-zero
2. **GCP Disk Snapshot**: Snapshot captured in a clean, crash-consistent state.
3. **`gcloud-snapshots/post.sh`** (Thaw & Resume):
   - Unfreezes XFS filesystem (`xfs_freeze -u /`)
   - Releases the database lock by ending the session that holds it
   - Reopens the Elasticsearch index
   - Attempts every step even if one fails, and exits non-zero if any failed

## Setup
Configure these scripts as pre/post snapshot guest environment scripts in Google Cloud Compute Engine snapshot schedules. Install both in the same directory, since `pre.sh` runs `post.sh` to roll back.

Database credentials are read from `/root/.my.cnf` (a `[client]` section, mode `600`), never from the command line. Without that file the client falls back to its defaults, such as unix-socket authentication for `root`.

The settings at the top of `pre.sh` (database client, lock timeouts, Elasticsearch URL and index, mount to freeze, state directory) can be edited there or overridden from the environment. Set `MYSQL`, `ES_INDEX` or `FREEZE_MOUNT` to an empty string to skip that step. `STATE_DIR` (default `/run/gcloud-snapshot`) must match in both scripts and must not be on the frozen filesystem.

Guest-flush (application-consistent) snapshots are not supported on Hyperdisk volumes, so these hooks do not run for Hyperdisk; snapshots of those disks are crash-consistent.
