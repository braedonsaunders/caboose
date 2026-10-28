#!/bin/sh
# Human-driven real-device check; use the integrated signed app and deployed matching host.
set -eu
cat <<'CHECK'
On an iPhone paired to a running computer with a signed-in ACP agent:

1. Open Agents > New Chat. Confirm the selected agent is visible. Tap a suggestion,
   edit it, switch to an older chat, type a different draft, and switch back. Each chat
   keeps its own draft. Search the Chats sheet by title and agent; select a result.
2. Attach a camera photo, a Photos image and a file. Check preview, filename, removal,
   four-file and 10 MB limits. Send a new request, then attach files to a reply. Ask the
   agent to identify each file by its contents. Files must reach the same ACP conversation.
3. Ask for a substantial answer with headings, lists, links and fenced code. Confirm text
   arrives before the turn ends; code remains literal, scrolls horizontally and copies.
   Scroll up during streaming and verify reading position and keyboard dismissal.
4. While a turn runs, queue two replies with identically named files of different contents.
   Confirm waiting messages show both filenames. Test automatic delivery, then repeat with
   Send Now. Both files must remain distinct, and late output must not appear in the new turn.
5. With Ask Before Acting enabled, request real computer work requiring tools. Check tool
   titles/status and the plan update in place. Exercise Allow, Deny and an offered standing
   permission. Failure and permission details must remain readable, never show false success.
6. Open an app on the agent seat. Verify a live preview appears only for a real window,
   Watch opens it, Take Over pauses tasks and Hand Back resumes. The owner's seat is separate.
   The agent seat is shared between tasks; the preview does not claim exclusive task ownership.
7. Start dictation. Check permission prompts and the explicit Listening state. Stop, edit
   and send. Switching chat, leaving Agents, and backgrounding must stop the microphone.
   Deny permission and check the error. Typing a normal message must not interrupt playback.
8. Disconnect the network during send. Text and attachments remain editable for retry.
   Reconnect during a running turn and confirm transcript, live draft and approval state
   recover without duplicate messages. Switch chats while a send is pending: it must not
   redirect the active chat or copy its draft into another conversation.
9. Check VoiceOver labels, large text, landscape, dark/light backgrounds and Reduce Motion.
   Capture the empty state, an actual streamed response, queued file reply, approval and
   live seat. Record the app commit, host commit and any unexercised item with the screenshots.
CHECK
