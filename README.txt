SIERRA HISTORY BRIDGE v0.0.31

PURPOSE
  Maintains Rithmic-named Sierra Chart SCID and Historical Daily files from
  matching SC Data history.

RUN
  run.cmd

START MENU / EXPLORER
  Update History
  Archive SC Data
  Restore SC Data
  Rollback Rithmic
  Storage Report

DEFAULT STORAGE
  Archive:
    SierraChart\Data\SCID_Bridge_Archive

  Recovery staging:
    SierraChart\Data\SCID_Bridge_Backups

  Logs:
    SierraChart\Data\SCID_Bridge_Logs

ARCHIVE CATEGORIES
  SC_Data
  Rithmic_Baselines
  Rollbacks
  Restore_Conflicts

COMMANDS
  archive.cmd
  restore.cmd
  rollback.cmd
  storage.cmd
  repair.cmd
  uninstall.cmd

SAFETY
  Output is validated before replacement.
  Normal Update never archives SC Data source files automatically.
  Archive, restore, and rollback require Sierra Chart to be closed.
  Live-sensitive SCID updates use explicit safety choices.

LICENSE
  Mozilla Public License 2.0.
  See LICENSE for the complete terms.

Full documentation is installed in the docs folder.
