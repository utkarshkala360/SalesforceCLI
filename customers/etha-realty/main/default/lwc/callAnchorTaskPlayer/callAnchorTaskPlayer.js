import { LightningElement, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import getRecordings from "@salesforce/apex/CallAnchorRecordingController.getRecordings";
import getAudio from "@salesforce/apex/CallAnchorRecordingController.getAudio";
import { loadScript } from "lightning/platformResourceLoader";
import AMR_DECODER from "@salesforce/resourceUrl/callAnchorAmrDecoder";

const downloadUrl = (versionId) =>
  `/sfc/servlet.shepherd/version/download/${versionId}`;

// Some phones upload AMR-NB (GSM) audio, sometimes named .mp3; browsers cannot
// play it, so it is converted to WAV in the browser.
const AMR_HEADER = "#!AMR\n";

function base64ToBytes(base64Data) {
  const binary = atob(base64Data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function isAmr(bytes) {
  return (
    String.fromCharCode(...bytes.subarray(0, AMR_HEADER.length)) === AMR_HEADER
  );
}

let amrDecoderPromise;
function loadAmrDecoder(component) {
  if (!amrDecoderPromise) {
    amrDecoderPromise = loadScript(component, AMR_DECODER).catch((error) => {
      amrDecoderPromise = undefined;
      throw error;
    });
  }
  return amrDecoderPromise.then(() => window.CallAnchorAmr);
}

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
  objectUrls = [];

  @wire(CurrentPageReference)
  readPage(page) {
    const nextId = page?.state?.c__recordId;
    this.urlObjectApiName = page?.state?.c__objectApiName;
    if (nextId !== this.recordId) {
      this.pausePlayers();
      this.revokeObjectUrls();
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
      this.revokeObjectUrls();
      // The shepherd URL redirects to the file content domain, which Lightning's
      // CSP blocks for <audio>; stream bytes through Apex into a same-origin blob: URL.
      this.recordings = (data.recordings || []).map((recording) => ({
        ...recording,
        audioUrl: recording.inlinePlayback
          ? undefined
          : downloadUrl(recording.versionId),
        audioLoading: Boolean(recording.inlinePlayback),
        playbackError: false
      }));
      this.error = undefined;
      this.loading = false;
      this.recordings
        .filter((recording) => recording.inlinePlayback)
        .forEach((recording) => this.loadAudio(recording.versionId));
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

  async loadAudio(versionId) {
    let audioUrl;
    try {
      const audio = await getAudio({ versionId });
      let bytes = base64ToBytes(audio.base64Data);
      let mimeType = audio.mimeType || "audio/mp4";
      if (isAmr(bytes)) {
        const decoder = await loadAmrDecoder(this);
        const wav = decoder?.toWAV(bytes);
        if (!wav) throw new Error("Unable to decode AMR recording.");
        bytes = wav;
        mimeType = "audio/wav";
      }
      audioUrl = URL.createObjectURL(new Blob([bytes], { type: mimeType }));
      this.objectUrls.push(audioUrl);
    } catch (error) {
      audioUrl = downloadUrl(versionId);
    }
    if (!this.recordings.some((recording) => recording.versionId === versionId)) {
      if (audioUrl.startsWith("blob:")) URL.revokeObjectURL(audioUrl);
      return;
    }
    this.updateRecording(versionId, { audioUrl, audioLoading: false });
  }
  updateRecording(versionId, changes) {
    this.recordings = this.recordings.map((recording) =>
      recording.versionId === versionId ? { ...recording, ...changes } : recording
    );
  }
  revokeObjectUrls() {
    this.objectUrls.forEach((url) => URL.revokeObjectURL(url));
    this.objectUrls = [];
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
    if (!event.target.getAttribute("src")) return;
    this.updateRecording(event.target.dataset.id, { playbackError: true });
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
    this.revokeObjectUrls();
  }
}
