import { LightningElement, api, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { refreshApex } from "@salesforce/apex";
import getRecordings from "@salesforce/apex/CallAnchorRecordingController.getRecordings";
import getRecordingData from "@salesforce/apex/CallAnchorRecordingController.getRecordingData";

// Sources are tried in this order; an audio error moves the recording to the next one.
// 'download' goes through Salesforce's file-domain redirects, which an <audio> element
// cannot always follow, so it is the last resort.
const EXTERNAL = "external";
const STREAM = "stream";
const DOWNLOAD = "download";

export default class CallAnchorTaskPlayer extends NavigationMixin(
  LightningElement
) {
  taskId;
  recordings = [];
  error;
  loading = false;
  wiredResult;
  blobUrls = [];
  playRequested;
  // Set when placed on a Task record page; the URL-addressable page reads c__recordId instead.
  embedded = false;

  @api
  get recordId() {
    return this.taskId;
  }
  set recordId(value) {
    this.embedded = true;
    this.useTask(value);
  }

  @wire(CurrentPageReference)
  readPage(page) {
    if (!this.embedded) this.useTask(page?.state?.c__recordId);
  }

  useTask(nextId) {
    if (nextId !== this.taskId) {
      this.pausePlayers();
      this.releaseBlobs();
      this.recordings = [];
      this.error = undefined;
      this.taskId = nextId;
      this.loading = Boolean(nextId);
    }
  }

  @wire(getRecordings, { taskId: "$taskId" })
  loadRecordings(result) {
    this.wiredResult = result;
    const { data, error } = result;
    if (data) {
      this.releaseBlobs();
      this.recordings = data.map((recording) => {
        const sources = [];
        if (recording.externalUrl) sources.push(EXTERNAL);
        if (recording.versionId && recording.streamable) sources.push(STREAM);
        if (recording.versionId) sources.push(DOWNLOAD);
        return {
          ...recording,
          key: recording.versionId || "external",
          sources,
          sourceIndex: -1,
          audioUrl: undefined,
          preparing: false,
          playbackError: false
        };
      });
      this.error = undefined;
      this.loading = false;
      this.recordings.forEach((recording) =>
        this.useNextSource(recording.key, false)
      );
    } else if (error) {
      this.recordings = [];
      this.error =
        error.body?.message || error.message || "Unable to load recordings.";
      this.loading = false;
    }
  }

  get missingTask() {
    return !this.taskId;
  }
  get empty() {
    return (
      this.taskId && !this.loading && !this.error && !this.recordings.length
    );
  }
  get refreshDisabled() {
    return !this.taskId || this.loading;
  }
  get showBack() {
    return this.taskId && !this.embedded;
  }

  updateRecording(key, changes) {
    this.recordings = this.recordings.map((recording) =>
      recording.key === key ? { ...recording, ...changes } : recording
    );
    return this.recordings.find((recording) => recording.key === key);
  }

  async useNextSource(key, resume) {
    const current = this.recordings.find((recording) => recording.key === key);
    if (!current) return;
    const sourceIndex = current.sourceIndex + 1;
    const source = current.sources[sourceIndex];
    if (!source) {
      this.updateRecording(key, {
        sourceIndex,
        audioUrl: undefined,
        preparing: false,
        playbackError: true
      });
      return;
    }
    if (source === EXTERNAL) {
      this.updateRecording(key, {
        sourceIndex,
        audioUrl: current.externalUrl,
        preparing: false
      });
    } else if (source === DOWNLOAD) {
      this.updateRecording(key, {
        sourceIndex,
        audioUrl: `/sfc/servlet.shepherd/version/download/${current.versionId}`,
        preparing: false
      });
    } else {
      this.updateRecording(key, {
        sourceIndex,
        audioUrl: undefined,
        preparing: true
      });
      try {
        const base64 = await getRecordingData({ versionId: current.versionId });
        const bytes = Uint8Array.from(atob(base64), (char) =>
          char.charCodeAt(0)
        );
        const url = URL.createObjectURL(
          new Blob([bytes], { type: "audio/mp4" })
        );
        this.blobUrls.push(url);
        // The Task may have changed while the file was loading.
        if (!this.recordings.some((recording) => recording.key === key)) return;
        this.updateRecording(key, { audioUrl: url, preparing: false });
      } catch {
        this.updateRecording(key, { preparing: false });
        this.useNextSource(key, resume);
        return;
      }
    }
    if (resume) this.playWhenReady(key);
  }

  // After a fallback triggered by pressing play, start the new source without a second click.
  playWhenReady(key) {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const player = this.template.querySelector(`audio[data-id="${key}"]`);
      if (player) {
        player.load();
        player.play().catch(() => {});
      }
    }, 0);
  }

  pausePlayers(except) {
    this.template.querySelectorAll("audio").forEach((player) => {
      if (player !== except) player.pause();
    });
  }
  handlePlay(event) {
    this.playRequested = event.target.dataset.id;
    this.pausePlayers(event.target);
  }
  handleAudioError(event) {
    const key = event.target.dataset.id;
    const recording = this.recordings.find((item) => item.key === key);
    // Ignore errors from an element whose src was already replaced.
    if (!recording || !recording.audioUrl || recording.preparing) return;
    // Metadata preloading can fail before anyone presses play; only autoplay if they did.
    this.useNextSource(key, this.playRequested === key);
  }
  openFile(event) {
    this[NavigationMixin.Navigate]({
      type: "standard__namedPage",
      attributes: { pageName: "filePreview" },
      state: { selectedRecordId: event.currentTarget.dataset.id }
    });
  }
  backToTask() {
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: this.taskId,
        objectApiName: "Task",
        actionName: "view"
      }
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
  releaseBlobs() {
    this.blobUrls.forEach((url) => URL.revokeObjectURL(url));
    this.blobUrls = [];
  }
  disconnectedCallback() {
    this.pausePlayers();
    this.releaseBlobs();
  }
}
