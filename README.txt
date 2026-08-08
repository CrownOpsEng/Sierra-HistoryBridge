SIERRA HISTORY BRIDGE
Version 0.0.14

Updates Rithmic-named Sierra Chart history files from matching SC Data files.

Supported data files:
  .scid  Intraday/tick history
  .dly   Historical Daily history

SC Data source files are not modified.

INSTALL
  Extract the release and run setup.cmd.

RUN
  Open the Sierra Chart Data folder, right-click the folder or blank space,
  and choose "Update Sierra history from SC Data".

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
