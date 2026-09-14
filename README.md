# GCP Snapshot Automation Scripts

Pre- and post-snapshot hooks for Google Cloud Platform (GCP) Compute Engine persistent disk snapshots, ensuring application- and filesystem-consistent backups.

## Overview

Taking live disk snapshots without quiescing active databases and filesystems can cause data corruption upon restore. These scripts coordinate a synchronized freeze and thaw across the storage and service stack.

## Architecture & Flow

1. **`gcloud-snapshots/pre.sh`** (Quiesce):
   - Locks MySQL / MariaDB tables (`FLUSH TABLES WITH READ LOCK`)
   - Gracefully stops LiteSpeed web server (`lswsctrl graceful`)
   - Closes active Elasticsearch index
   - Flushes write buffers (`sync`) and freezes the XFS filesystem (`xfs_freeze -f /`)
2. **GCP Disk Snapshot**: Snapshot captured in a clean, crash-consistent state.
3. **`gcloud-snapshots/post.sh`** (Thaw & Resume):
   - Unfreezes XFS filesystem (`xfs_freeze -u /`)
   - Starts LiteSpeed web server (`lswsctrl start`)
   - Releases database lock (`UNLOCK TABLES`)
   - Reopens Elasticsearch index

## Setup
Configure these scripts as pre/post snapshot guest environment scripts in Google Cloud Compute Engine snapshot schedules.