import { LightningElement, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import getRecordings from "@salesforce/apex/CallAnchorRecordingController.getRecordings";

export default class CallAnchorTaskPlayer extends NavigationMixin(
  LightningElement
) {
  recordId;
  urlObjectApiName;
  objectApiName;
  objectLabel;
  recordings = [];
  error;
  loading = false;
  wiredResult;

  @wire(CurrentPageReference)
  readPage(page) {
    const nextId = page?.state?.c__recordId;
    this.urlObjectApiName = page?.state?.c__objectApiName;
    if (nextId !== this.recordId) {
      this.pausePlayers();
      this.recordings = [];
      this.error = undefined;
      this.objectApiName = undefined;
      this.objectLabel = undefined;
      this.recordId = nextId;
      this.loading = Boolean(nextId);
    }
  }

  @wire(getRecordings, { recordId: "$recordId" })
  loadRecordings(result) {
    this.wiredResult = result;
    const { data, error } = result;
    if (data) {
      this.objectApiName = data.objectApiName;
      this.objectLabel = data.objectLabel;
      this.recordings = (data.recordings || []).map((recording) => ({
        ...recording,
        audioUrl: `/sfc/servlet.shepherd/version/download/${recording.versionId}`,
        playbackError: false
      }));
      this.error = undefined;
      this.loading = false;
    } else if (error) {
      this.recordings = [];
      this.error =
        error.body?.message || error.message || "Unable to load recordings.";
      this.loading = false;
    }
  }

  get missingRecord() {
    return !this.recordId;
  }
  get empty() {
    return (
      this.recordId && !this.loading && !this.error && !this.recordings.length
    );
  }
  get refreshDisabled() {
    return !this.recordId || this.loading;
  }
  get recordLabel() {
    return this.objectLabel || "Record";
  }
  get emptyMessage() {
    return `No accessible audio recordings are attached to this ${this.recordLabel}.`;
  }
  get backLabel() {
    return `Back to ${this.recordLabel}`;
  }

  pausePlayers(except) {
    this.template.querySelectorAll("audio").forEach((player) => {
      if (player !== except) player.pause();
    });
  }
  handlePlay(event) {
    this.pausePlayers(event.target);
  }
  handleAudioError(event) {
    const versionId = event.target.dataset.id;
    this.recordings = this.recordings.map((recording) => ({
      ...recording,
      playbackError:
        recording.versionId === versionId || recording.playbackError
    }));
  }
  openFile(event) {
    this[NavigationMixin.Navigate]({
      type: "standard__namedPage",
      attributes: { pageName: "filePreview" },
      state: { selectedRecordId: event.currentTarget.dataset.id }
    });
  }
  backToRecord() {
    const attributes = { recordId: this.recordId, actionName: "view" };
    const objectApiName = this.objectApiName || this.urlObjectApiName;
    if (objectApiName) attributes.objectApiName = objectApiName;
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes
    });
  }
  async refresh() {
    this.loading = true;
    this.pausePlayers();
    try {
      await refreshApex(this.wiredResult);
    } catch (error) {
      this.error = error.body?.message || error.message || "Refresh failed.";
    } finally {
      this.loading = false;
    }
  }
  disconnectedCallback() {
    this.pausePlayers();
  }
}
