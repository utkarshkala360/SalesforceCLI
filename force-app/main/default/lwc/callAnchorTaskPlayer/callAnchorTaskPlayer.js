import { LightningElement, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getRecordings from '@salesforce/apex/CallAnchorRecordingController.getRecordings';

export default class CallAnchorTaskPlayer extends NavigationMixin(LightningElement) {
    taskId;
    recordings = [];
    error;
    loading = false;
    wiredResult;

    @wire(CurrentPageReference)
    readPage(page) {
        const nextId = page?.state?.c__recordId;
        if (nextId !== this.taskId) {
            this.pausePlayers();
            this.recordings = [];
            this.error = undefined;
            this.taskId = nextId;
            this.loading = Boolean(nextId);
        }
    }

    @wire(getRecordings, { taskId: '$taskId' })
    loadRecordings(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.recordings = data.map((recording) => ({
                ...recording,
                audioUrl: `/sfc/servlet.shepherd/version/download/${recording.versionId}`,
                playbackError: false
            }));
            this.error = undefined;
            this.loading = false;
        } else if (error) {
            this.recordings = [];
            this.error = error.body?.message || error.message || 'Unable to load recordings.';
            this.loading = false;
        }
    }

    get missingTask() { return !this.taskId; }
    get empty() { return this.taskId && !this.loading && !this.error && !this.recordings.length; }
    get refreshDisabled() { return !this.taskId || this.loading; }

    pausePlayers(except) {
        this.template.querySelectorAll('audio').forEach((player) => {
            if (player !== except) player.pause();
        });
    }
    handlePlay(event) { this.pausePlayers(event.target); }
    handleAudioError(event) {
        const versionId = event.target.dataset.id;
        this.recordings = this.recordings.map((recording) => ({
            ...recording,
            playbackError: recording.versionId === versionId || recording.playbackError
        }));
    }
    openFile(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: event.currentTarget.dataset.id }
        });
    }
    backToTask() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.taskId, objectApiName: 'Task', actionName: 'view' }
        });
    }
    async refresh() {
        this.loading = true;
        this.pausePlayers();
        try { await refreshApex(this.wiredResult); }
        catch (error) { this.error = error.body?.message || error.message || 'Refresh failed.'; }
        finally { this.loading = false; }
    }
    disconnectedCallback() { this.pausePlayers(); }
}
