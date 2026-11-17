/**
Runwal Realty - when the Call Anchor app attaches a recording File to one Task
of a call, CallAnchorRecordingLinker links the same File to the call's other
Tasks (Applicant and Booking). See that class for details.
 */
trigger CallAnchorFileLinkTrigger on ContentDocumentLink(after insert) {
  CallAnchorRecordingLinker.onLinksInserted(Trigger.new);
}
