Sierra History Bridge v0.0.34

PURPOSE
  Maintains Rithmic-named Sierra Chart history from Sierra Chart SC Data
  sources while preserving newer Rithmic records only when a verified
  whole-second handoff is available.

DEFAULT PATHS
  Program:
    C:\Program Files\Sierra History Bridge

  Settings/state:
    %LOCALAPPDATA%\SierraHistoryBridge

  Persistent history:
    <DataPath>\HistoryBridge

  Temporary transaction files:
    <DataPath>\HistoryBridgeTemp

  Logs:
    <SierraPath>\Logs\HistoryBridge

PERSISTENT CATEGORIES
  Archive          SC Data archives only
  Baselines        authenticated Rithmic baseline states only
  Rollbacks        undo/recovery states
  RestoreConflicts preserved conflicting restore destinations

ROLLBACK IDENTITY CODES
  RT  authenticated Rithmic
  SC  pure SC Data-derived
  MX  mixed/hybrid
  FR  non-SC/foreign form, not provider-authenticated
  UN  unknown

  Example:
    manual-20260808-220000-123--MX--NQH6.CME.scid.gz

MERGE SAFETY
  Cross-feed records are not deduplicated by raw timestamp.
  SC Data and Rithmic can timestamp the same trades differently.

  A live SCID merge requires at least three matching active seconds using:
    total volume
    bid volume
    ask volume
    scaled last price

  The chosen whole second is a half-open boundary:
    SC Data records < boundary
    Rithmic records >= boundary

  If the boundary cannot be proved, the target is not changed.

PROVENANCE
  Saved state is not blindly trusted after a file changes.

  Identity priority:
    exact authenticated backup hash
    exact state hash
    full SC Data source relationship
    conservative record morphology
    Unknown

MULTI-SELECT
  Archive SC Data, Restore SC Data and Rollback Rithmic support Explorer
  multi-selection and execute as one visible batch.

LICENSE
  Mozilla Public License 2.0.
  See LICENSE for the complete terms.
