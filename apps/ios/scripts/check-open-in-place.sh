#!/bin/sh
# A human-driven device check: this cannot be simulated by a simulator build.
set -eu
cat <<'CHECK'
On a signed iPhone/iPad paired with a real Caboose computer:

1. In Files open a document from a writable non-Caboose provider with Caboose.
   Choose an installed compatible app; edit and save in Linux. Return to the source
   provider and verify the original contains the edit.
2. Repeat with Caboose backgrounded while Linux saves, then bring it back. Verify the
   original catches up. Disconnect the host and confirm an error is shown and the
   original remains intact; reconnect and use Retry.
3. Change the original and the Linux copy independently while Caboose is backgrounded.
   On return, verify a conflict appears. Test Keep Original, then repeat with Keep
   Computer Copy. Verify the chosen version on both sides and no silent overwrite.
4. Open a compatible file from Caboose's Files location. Verify the selected app opens
   the existing home path and no new folder is made in Caboose Documents.
5. Use Open In from another app, and use Share > Caboose > Open on Computer. Verify
   installation progress for an uninstalled compatible app, then return to Caboose and
   verify its window. Test a share source that supplies only a temporary copy: the copy
   warning must appear and edits must not be claimed to sync to that source.
6. Rename or remove an original or computer copy and verify a sync error is visible;
   check a second provider, a large document, and a filename with spaces and Unicode.
7. Repeat with both supported display protocols. Check that app-group and keychain
   entitlements are present in all three signed targets.
CHECK
