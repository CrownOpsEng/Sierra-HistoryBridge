SIERRA HISTORY BRIDGE
Version 0.0.25

Updates Rithmic-named Sierra Chart history files from matching SC Data files.

Supported data files:
  .scid  Intraday/tick history
  .dly   Historical Daily history

SC Data source files are not modified.

INSTALL
  Extract the release and run setup.cmd.

RUN
  Right-click the configured Sierra Chart Data folder itself and choose
  "Update Sierra history from SC Data", or run run.cmd.

REPAIR
  Run repair.cmd, or run setup.cmd and choose Repair / update.

UNINSTALL
  Run uninstall.cmd, or use Windows Settings > Apps > Installed apps.

BACKUPS
  SierraChart\Data\SCID_Bridge_Backups

LOGS
  SierraChart\Data\SCID_Bridge_Logs

The backup directory can contain both .scid.bak and .dly.bak files.

DATA VALIDATION
---------------
When both SC Data and Rithmic SCID files exist, Sierra History Bridge compares
the overlapping data before replacement. Incomplete coverage, timestamp-order
problems, or material feed differences are reported before history files are
changed. Ambiguous cases default to keeping the existing Rithmic file and
waiting for review.


STORAGE
-------
Sierra History Bridge keeps permanent duplicate data to a minimum.

SCID_Bridge_Archive contains verified compressed .gz archives for the original
Rithmic validation baseline and, when needed, one live/temporary rollback.
The archive filename is the original Sierra filename plus .gz.

SCID_Bridge_Backups is temporary recovery/staging space. Historical SCID and
Daily .bak files are removed after the replacement has been verified. Safe
leftovers and stale bridge temporary files are cleaned on startup.

SCID conversions are sequential and require one full-size temporary output for
safe atomic replacement. Free space is checked before each conversion with a
256 MB reserve; the update is deferred before the target is touched if it will
not fit.

SC Data source files are not automatically deleted or compressed because they
are the authoritative originals and may still be used directly by Sierra Chart.


ARCHIVE / RESTORE
  SC Data source files are never archived automatically.

  Archive Historical Data:
    archive.cmd
    Default: contracts older than the rolling Rithmic bridge window.
    Filters: contract date range, contract age in days, or all.
    Sierra Chart must be closed.

  Restore Historical Data:
    restore.cmd
    Default: most recent archived contract.
    Filters: contract date range, recent contract days, or all.
    Sierra Chart must be closed.

  Storage Report:
    storage.cmd

  Archives preserve the exact original filename plus .gz and are verified
  before the source is deleted. Successful restore returns the exact filename
  and removes the archive copy to avoid duplicate storage.

EARLY NQ DAILY HISTORY
  Zero-volume/missing-date records in the oldest SC Data are preserved as
  supplied. Sierra History Bridge never invents volume to silence continuous-
  contract warnings.


ROLLBACK RITHMIC DATA
  rollback.cmd

  Or right-click a verified .gz backup under Rithmic_Baselines, Rollbacks, or
  Legacy_Backups and choose "Rollback Rithmic data".

  The current target is preserved first when it differs from the selected
  backup. The selected backup itself is retained after rollback.
