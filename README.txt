SIERRA HISTORY BRIDGE
Version 0.0.3 - experimental / pre-stable

WHAT IT DOES
============
Sierra History Bridge updates Sierra Chart Rithmic-named intraday files with
SC Data historical records while preserving Rithmic records that are genuinely
newer than the SC Data source.

Example:

    NQU26-CME.scid  ->  NQU6.CME.scid

INSTALL
=======
1. Run setup.cmd.
2. Choose Current user or All users.
3. Choose whether to create Start Menu / All apps shortcuts.
4. Open Sierra Chart's Data folder.
5. Right-click the folder or blank space inside it.
6. Choose:

       Update Sierra history from SC Data

Current-user installation is recommended for most users.

REPAIR
======
Use any of:

    repair.cmd

or run:

    setup.cmd

and choose Repair / update.

If Start Menu shortcuts were enabled, Repair Sierra History Bridge is also
available there.

UNINSTALL
=========
Use any of:

    uninstall.cmd

the Start Menu uninstall shortcut, or:

    Windows Settings -> Apps -> Installed apps
    -> Sierra History Bridge -> Uninstall

Uninstall asks whether to remove the remembered Data-folder selection,
verified conversion scales, and processed-file state.

PROGRAM FILES
=============
Current-user install:

    %LOCALAPPDATA%\Programs\Sierra History Bridge

All-users install:

    %ProgramFiles%\Sierra History Bridge

PER-USER SETTINGS
=================
    %LOCALAPPDATA%\SierraHistoryBridge

SIERRA CHART BACKUPS AND LOGS
=============================
Backups:

    SierraChart\Data\SCID_Bridge_Backups

Run logs:

    SierraChart\Data\SCID_Bridge_Logs

These Sierra Chart Data-folder recovery files are left in place when the
application is uninstalled.

DOCUMENTATION
=============
The installed program folder contains README.md and the full docs directory.
The public repository contains the technical design, troubleshooting,
development, contribution, and publishing documentation.

IMPORTANT
=========
This is pre-stable software that modifies local market-data files. Existing
Rithmic targets receive a rolling backup and converted output is validated
before replacement.

This project is not affiliated with or endorsed by Sierra Chart, Rithmic,
CME Group, or their affiliates.
